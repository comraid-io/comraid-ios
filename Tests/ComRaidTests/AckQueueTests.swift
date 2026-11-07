import Foundation
import Testing
@testable import ComRaid

@Test func enqueueFromPayloadPersistsDeliveredAck() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )

  let enqueued = await queue.enqueueFromPayload(
    kind: .delivered,
    data: [
      "cr_delivery_id": "d1",
      "cr_attribution_token": "t1",
    ]
  )

  #expect(enqueued)
  let raw = storage.get(queue.storageKey())!
  let items = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [[String: Any]]
  #expect(items.count == 1)
  #expect(items[0]["kind"] as? String == "delivered")
  #expect(items[0]["deliveryId"] as? String == "d1")
}

@Test func flushPostsDeliveredAndClearsQueueOnSuccess() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"delivery_id":"d1","status":"delivered"}"#.utf8)
  )
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )
  _ = await queue.enqueueFromPayload(
    kind: .delivered,
    data: ["cr_delivery_id": "d1", "cr_attribution_token": "t1"]
  )

  await queue.flush()

  let request = try! #require(transport.requests.first)
  #expect(request.method == "POST")
  #expect(request.path == "/deliveries/d1/delivered")
  let body = try! JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
  #expect(body["attribution_token"] as? String == "t1")
  #expect(storage.get(queue.storageKey()) == "[]")
}

@Test func flushPostsOpenedWithOptionalActionId() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  transport.nextResponse = HttpResponse(statusCode: 200, body: Data("{}".utf8))
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )
  _ = await queue.enqueueFromPayload(
    kind: .opened,
    data: ["cr_delivery_id": "d2", "cr_attribution_token": "t2"],
    actionId: "accept"
  )

  await queue.flush()

  let request = try! #require(transport.requests.first)
  #expect(request.path == "/deliveries/d2/opened")
  let body = try! JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
  #expect(body["action_id"] as? String == "accept")
  #expect(body["attribution_token"] as? String == "t2")
}

@Test func flushRetriesOn503AndKeepsEvent() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  transport.nextResponse = HttpResponse(statusCode: 503, body: Data("nope".utf8))
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )
  _ = await queue.enqueueFromPayload(
    kind: .opened,
    data: ["cr_delivery_id": "d3", "cr_attribution_token": "t3"]
  )

  await queue.flush()

  #expect(transport.requests.count == 1)
  let remaining = try! JSONSerialization.jsonObject(with: Data(storage.get(queue.storageKey())!.utf8)) as! [[String: Any]]
  #expect(remaining.count == 1)
  #expect(remaining[0]["deliveryId"] as? String == "d3")
  #expect((remaining[0]["attempts"] as? NSNumber)?.intValue == 1)
}

@Test func flushHonorsRetryAfterSecondsOn429() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  let clock = MutableClock(1_000_000)
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { clock.now }
  )
  transport.nextResponse = HttpResponse(
    statusCode: 429,
    body: Data("rate".utf8),
    headers: ["Retry-After": "30"]
  )
  _ = await queue.enqueueFromPayload(
    kind: .delivered,
    data: ["cr_delivery_id": "d4", "cr_attribution_token": "t4"]
  )

  await queue.flush()

  let remaining = try! JSONSerialization.jsonObject(with: Data(storage.get(queue.storageKey())!.utf8)) as! [[String: Any]]
  #expect((remaining[0]["nextAttemptAt"] as? NSNumber)?.int64Value == 1_030_000)

  transport.clearRequests()
  transport.nextResponse = HttpResponse(statusCode: 200, body: Data("{}".utf8))
  clock.now = 1_020_000
  await queue.flush()
  #expect(transport.requests.isEmpty)

  clock.now = 1_030_000
  await queue.flush()
  #expect(transport.requests.count == 1)
  #expect(storage.get(queue.storageKey()) == "[]")
}

@Test func flushDropsTerminal404() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  transport.nextResponse = HttpResponse(statusCode: 404, body: Data("missing".utf8))
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )
  _ = await queue.enqueueFromPayload(
    kind: .delivered,
    data: ["cr_delivery_id": "d5", "cr_attribution_token": "t5"]
  )

  await queue.flush()

  #expect(storage.get(queue.storageKey()) == "[]")
}

@Test func enqueueFromPayloadReturnsFalseWithoutAttribution() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )

  let ok = await queue.enqueueFromPayload(kind: .delivered, data: ["foo": "bar"])
  #expect(ok == false)
  #expect(storage.get(queue.storageKey()) == nil)
}

@Test func testSendPayloadWithoutDeliveryIdsMakesNoAckRequest() async {
  // Test sends omit cr_delivery_id / cr_attribution_token; receive still runs but must not ACK.
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )

  let delivered = await queue.enqueueFromPayload(
    kind: .delivered,
    data: ["cr_title": "Test", "cr_body": "Hello"]
  )
  #expect(delivered == false)
  #expect(storage.get(queue.storageKey()) == nil)
  await queue.flush()
  #expect(transport.requests.isEmpty)

  let opened = await queue.enqueueFromPayload(
    kind: .opened,
    data: ["cr_delivery_id": "d-only"] // token missing
  )
  #expect(opened == false)
  await queue.flush()
  #expect(transport.requests.isEmpty)
}

@Test func enqueueDuringFlushSurvivesFinalSave() async {
  let storage = InMemoryAckQueueStore()
  let gate = AsyncGate()
  let transport = GatedTransport(gate: gate)
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )
  _ = await queue.enqueueFromPayload(
    kind: .delivered,
    data: ["cr_delivery_id": "d-flush", "cr_attribution_token": "t1"]
  )

  async let flushDone: Void = queue.flush()
  await gate.waitUntilEntered()
  _ = await queue.enqueueFromPayload(
    kind: .opened,
    data: ["cr_delivery_id": "d-during", "cr_attribution_token": "t2"]
  )
  await gate.open()
  await flushDone

  let remaining = try! JSONSerialization.jsonObject(with: Data(storage.get(queue.storageKey())!.utf8)) as! [[String: Any]]
  #expect(remaining.count == 1)
  #expect(remaining[0]["deliveryId"] as? String == "d-during")
  #expect(remaining[0]["kind"] as? String == "opened")
}

@Test func twoConcurrentFlushesSendEachAckOnce() async {
  let storage = InMemoryAckQueueStore()
  let gate = AsyncGate()
  let transport = GatedTransport(gate: gate)
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )
  _ = await queue.enqueueFromPayload(
    kind: .delivered,
    data: ["cr_delivery_id": "d-once", "cr_attribution_token": "t"]
  )

  async let first: Void = queue.flush()
  await gate.waitUntilEntered()
  async let second: Void = queue.flush()
  // Give the second flush a chance to observe flushInFlight before network resumes.
  try? await Task.sleep(nanoseconds: 50_000_000)
  await gate.open()
  await first
  await second

  #expect(transport.requestCount() == 1)
  #expect(storage.get(queue.storageKey()) == "[]")
}

@Test func duplicateOpenedIsDedupedByDeliveryId() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )
  let data = ["cr_delivery_id": "d-open", "cr_attribution_token": "t"]
  _ = await queue.enqueueFromPayload(kind: .opened, data: data, actionId: nil)
  _ = await queue.enqueueFromPayload(kind: .opened, data: data, actionId: "accept")

  let remaining = try! JSONSerialization.jsonObject(with: Data(storage.get(queue.storageKey())!.utf8)) as! [[String: Any]]
  #expect(remaining.count == 1)
  #expect(remaining[0]["kind"] as? String == "opened")
  #expect(remaining[0]["deliveryId"] as? String == "d-open")
}

@Test func alreadySentAckIsNotReenqueuedWithinTTL() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  transport.nextResponse = HttpResponse(statusCode: 200, body: Data("{}".utf8))
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )
  let data = ["cr_delivery_id": "d-sent", "cr_attribution_token": "t"]
  _ = await queue.enqueueFromPayload(kind: .opened, data: data)
  await queue.flush()
  #expect(storage.get(queue.storageKey()) == "[]")

  _ = await queue.enqueueFromPayload(kind: .opened, data: data, actionId: "accept")
  #expect(storage.get(queue.storageKey()) == "[]")
  #expect(transport.requests.count == 1)
}

@Test func claimedAckStaysDurableUntilSendSucceedsAndSurvivesCrashWindow() async {
  let storage = InMemoryAckQueueStore()
  let gate = AsyncGate()
  let gated = GatedTransport(gate: gate)
  let midFlight = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: gated,
    clock: { 1_000_000 }
  )
  _ = await midFlight.enqueueFromPayload(
    kind: .delivered,
    data: ["cr_delivery_id": "d-crash", "cr_attribution_token": "t"]
  )

  async let flushDone: Void = midFlight.flush()
  await gate.waitUntilEntered()

  // Process-death window: claimed for send but not yet accepted — still durable.
  let midFlightRaw = storage.get(midFlight.storageKey())!
  let midFlightItems = try! JSONSerialization.jsonObject(with: Data(midFlightRaw.utf8)) as! [[String: Any]]
  #expect(midFlightItems.count == 1)
  #expect(midFlightItems[0]["deliveryId"] as? String == "d-crash")

  // Snapshot mid-flight, then finish the in-process flush so a new AckQueue can
  // flush (a real crash starts a new process with a clear in-flight flag).
  let snapshot = InMemoryAckQueueStore()
  snapshot.set(midFlight.storageKey(), value: midFlightRaw)
  await gate.open()
  await flushDone

  let restartTransport = RecordingTransport()
  restartTransport.nextResponse = HttpResponse(statusCode: 200, body: Data("{}".utf8))
  let restarted = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: snapshot,
    transport: restartTransport,
    clock: { 1_000_000 }
  )
  await restarted.flush()
  #expect(restartTransport.requests.count == 1)
  #expect(restartTransport.requests.first?.path == "/deliveries/d-crash/delivered")
  #expect(snapshot.get(restarted.storageKey()) == "[]")
}

private final class MutableClock: @unchecked Sendable {
  var now: Int64
  init(_ now: Int64) { self.now = now }
}

private final class InMemoryAckQueueStore: AckQueueStore, @unchecked Sendable {
  private let lock = NSLock()
  private var map: [String: String] = [:]

  func get(_ key: String) -> String? {
    lock.withLock { map[key] }
  }

  func set(_ key: String, value: String) {
    lock.withLock { map[key] = value }
  }
}

private final class RecordingTransport: HttpTransport, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requests: [HttpRequest] = []
  var nextResponse: HttpResponse?

  func clearRequests() {
    lock.withLock { requests.removeAll() }
  }

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock {
      requests.append(request)
      guard let nextResponse else { fatalError("No response configured") }
      return nextResponse
    }
  }
}

/// Suspends the first `execute` until `open()` so tests can interleave actor work across `await send`.
private actor AsyncGate {
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var entered = false
  private var openContinuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { continuation in
      enteredContinuation = continuation
    }
  }

  func enterAndWait() async {
    entered = true
    enteredContinuation?.resume()
    enteredContinuation = nil
    if isOpen { return }
    await withCheckedContinuation { continuation in
      openContinuation = continuation
    }
  }

  func open() {
    isOpen = true
    openContinuation?.resume()
    openContinuation = nil
  }
}

private final class GatedTransport: HttpTransport, @unchecked Sendable {
  private let gate: AsyncGate
  private let lock = NSLock()
  private var count = 0

  init(gate: AsyncGate) {
    self.gate = gate
  }

  func requestCount() -> Int {
    lock.withLock { count }
  }

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock { count += 1 }
    await gate.enterAndWait()
    return HttpResponse(statusCode: 200, body: Data("{}".utf8))
  }
}
