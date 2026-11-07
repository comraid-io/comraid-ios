import Foundation

enum AckKind: String, Sendable, Equatable {
  case delivered
  case opened

  static func fromWire(_ value: String) -> AckKind? {
    AckKind(rawValue: value)
  }
}

struct QueuedAck: Equatable, Sendable {
  var deliveryId: String
  var attributionToken: String
  var kind: AckKind
  var actionId: String?
  var enqueuedAt: Int64
  var attempts: Int
  var nextAttemptAt: Int64
}

/// Durable delivery ACK queue. Persists so notification handlers can enqueue/flush
/// without a foreground `ComRaid` init in this process lifetime.
///
/// Enqueue and flush are serialized by the actor. At most one flush performs network
/// I/O at a time; items claimed for a flush are removed from the store before `await send`
/// so reentrant enqueues across suspension points survive the final save.
actor AckQueue {
  private let store: any AckQueueStore
  private let transport: any HttpTransport
  private let clock: @Sendable () -> Int64
  private let maxSize: Int
  private let maxAgeMs: Int64
  private let maxFlush: Int
  nonisolated private let key: String
  nonisolated private let sentKey: String
  private var flushInFlight = false

  private static let defaultMaxSize = 100
  private static let defaultMaxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000
  private static let defaultMaxFlush = 20

  init(
    apiBaseURL: URL,
    store: any AckQueueStore,
    transport: any HttpTransport,
    clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
    maxSize: Int = AckQueue.defaultMaxSize,
    maxAgeMs: Int64 = AckQueue.defaultMaxAgeMs,
    maxFlush: Int = AckQueue.defaultMaxFlush
  ) {
    let base = apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    self.key = "comraid:\(base):ack-queue"
    self.sentKey = "comraid:\(base):ack-sent"
    self.store = store
    self.transport = transport
    self.clock = clock
    self.maxSize = maxSize
    self.maxAgeMs = maxAgeMs
    self.maxFlush = maxFlush
  }

  nonisolated func storageKey() -> String { key }

  nonisolated func sentStorageKey() -> String { sentKey }

  @discardableResult
  func enqueueFromPayload(
    kind: AckKind,
    data: [String: String]?,
    actionId: String? = nil
  ) -> Bool {
    guard let attribution = PushPayload.attribution(data) else { return false }
    let now = clock()
    enqueue(
      QueuedAck(
        deliveryId: attribution.deliveryId,
        attributionToken: attribution.attributionToken,
        kind: kind,
        actionId: {
          guard let actionId else { return nil }
          let trimmed = actionId.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }(),
        enqueuedAt: now,
        attempts: 0,
        nextAttemptAt: now
      )
    )
    return true
  }

  func enqueue(_ event: QueuedAck) {
    let now = clock()
    pruneSent(now)
    if wasSentRecently(event, now: now) { return }

    var items = load().filter { now - $0.enqueuedAt <= maxAgeMs }
    let key = eventKey(event)
    items = items.filter { eventKey($0) != key }
    items.append(event)
    while items.count > maxSize {
      items.removeFirst()
    }
    save(items)
  }

  func flush() async {
    if flushInFlight { return }
    flushInFlight = true
    defer { flushInFlight = false }

    let now = clock()
    pruneSent(now)
    let items = load().filter { now - $0.enqueuedAt <= maxAgeMs }
    let ready = Array(items.filter { $0.nextAttemptAt <= now }.prefix(maxFlush))
    if ready.isEmpty {
      save(items)
      return
    }

    let readyKeys = Set(ready.map(eventKey))
    // Claim ready items before any await so reentrant enqueues keep their rows.
    save(items.filter { !readyKeys.contains(eventKey($0)) })

    var retries: [QueuedAck] = []
    var finished: [QueuedAck] = []
    for event in ready {
      switch await send(event) {
      case .success, .drop:
        finished.append(event)
      case .retry(let nextAttemptAt):
        let attempts = event.attempts + 1
        let nextAt = nextAttemptAt ?? (clock() + min(60_000, Int64(1000.0 * pow(2.0, Double(min(attempts, 5))))))
        retries.append(
          QueuedAck(
            deliveryId: event.deliveryId,
            attributionToken: event.attributionToken,
            kind: event.kind,
            actionId: event.actionId,
            enqueuedAt: event.enqueuedAt,
            attempts: attempts,
            nextAttemptAt: nextAt
          )
        )
      }
    }

    let mergeNow = clock()
    for event in finished {
      markSent(event, now: mergeNow)
    }

    var remaining = load().filter { mergeNow - $0.enqueuedAt <= maxAgeMs }
    for retry in retries {
      if wasSentRecently(retry, now: mergeNow) { continue }
      let key = eventKey(retry)
      remaining = remaining.filter { eventKey($0) != key }
      remaining.append(retry)
    }
    while remaining.count > maxSize {
      remaining.removeFirst()
    }
    save(remaining)
  }

  private enum SendResult {
    case success
    case drop
    case retry(nextAttemptAt: Int64?)
  }

  private func send(_ event: QueuedAck) async -> SendResult {
    let path = "/deliveries/\(event.deliveryId)/\(event.kind.rawValue)"
    var payload: [String: Any] = ["attribution_token": event.attributionToken]
    if event.kind == .opened, let actionId = event.actionId, !actionId.isEmpty {
      payload["action_id"] = actionId
    }
    do {
      let body = try JSONSerialization.data(withJSONObject: payload)
      let response = try await transport.execute(
        HttpRequest(method: "POST", path: path, headers: [:], body: body)
      )
      switch response.statusCode {
      case 200...299:
        return .success
      case 429, 500...:
        let retryAfter = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if let retryAfter, retryAfter.allSatisfy(\.isNumber), let seconds = Int64(retryAfter) {
          return .retry(nextAttemptAt: clock() + seconds * 1000)
        }
        return .retry(nextAttemptAt: nil)
      case 400...499:
        return .drop
      default:
        return .retry(nextAttemptAt: nil)
      }
    } catch {
      return .retry(nextAttemptAt: nil)
    }
  }

  private func load() -> [QueuedAck] {
    guard let raw = store.get(key),
          let data = raw.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    return array.compactMap { obj in
      guard let kindWire = obj["kind"] as? String,
            let kind = AckKind.fromWire(kindWire),
            let deliveryId = obj["deliveryId"] as? String, !deliveryId.isEmpty,
            let token = obj["attributionToken"] as? String, !token.isEmpty else {
        return nil
      }
      let actionId = (obj["actionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return QueuedAck(
        deliveryId: deliveryId,
        attributionToken: token,
        kind: kind,
        actionId: (actionId?.isEmpty == false) ? actionId : nil,
        enqueuedAt: int64(obj["enqueuedAt"]),
        attempts: int(obj["attempts"]),
        nextAttemptAt: int64(obj["nextAttemptAt"])
      )
    }
  }

  private func save(_ items: [QueuedAck]) {
    let array: [[String: Any]] = items.map { event in
      var obj: [String: Any] = [
        "deliveryId": event.deliveryId,
        "attributionToken": event.attributionToken,
        "kind": event.kind.rawValue,
        "enqueuedAt": event.enqueuedAt,
        "attempts": event.attempts,
        "nextAttemptAt": event.nextAttemptAt,
      ]
      if let actionId = event.actionId {
        obj["actionId"] = actionId
      }
      return obj
    }
    guard let data = try? JSONSerialization.data(withJSONObject: array),
          let raw = String(data: data, encoding: .utf8) else { return }
    store.set(key, value: raw)
  }

  private func loadSent() -> [String: Int64] {
    guard let raw = store.get(sentKey),
          let data = raw.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return [:]
    }
    var out: [String: Int64] = [:]
    for obj in array {
      guard let key = obj["key"] as? String, !key.isEmpty else { continue }
      out[key] = int64(obj["sentAt"])
    }
    return out
  }

  private func saveSent(_ sent: [String: Int64]) {
    let array: [[String: Any]] = sent.map { key, sentAt in
      ["key": key, "sentAt": sentAt]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: array),
          let raw = String(data: data, encoding: .utf8) else { return }
    store.set(sentKey, value: raw)
  }

  private func pruneSent(_ now: Int64) {
    saveSent(loadSent().filter { now - $0.value <= maxAgeMs })
  }

  private func wasSentRecently(_ event: QueuedAck, now: Int64) -> Bool {
    guard let sentAt = loadSent()[eventKey(event)] else { return false }
    return now - sentAt <= maxAgeMs
  }

  private func markSent(_ event: QueuedAck, now: Int64) {
    var sent = loadSent()
    sent[eventKey(event)] = now
    saveSent(sent.filter { now - $0.value <= maxAgeMs })
  }

  /// Dedupe key: Delivery id + kind (opened is one per Delivery; action id ignored).
  private func eventKey(_ event: QueuedAck) -> String {
    "\(event.kind.rawValue):\(event.deliveryId)"
  }

  private func int64(_ value: Any?) -> Int64 {
    if let n = value as? Int64 { return n }
    if let n = value as? Int { return Int64(n) }
    if let n = value as? NSNumber { return n.int64Value }
    return 0
  }

  private func int(_ value: Any?) -> Int {
    if let n = value as? Int { return n }
    if let n = value as? Int64 { return Int(n) }
    if let n = value as? NSNumber { return n.intValue }
    return 0
  }
}
