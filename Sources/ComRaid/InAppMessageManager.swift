import Foundation

/// Draws a message with the SDK's default layouts. Returns false when there is no window to draw on.
@MainActor
protocol InAppDisplay: Sendable {
  /// True when there is a window the message could be drawn on right now.
  func isAvailable() -> Bool
  func show(_ message: InAppMessage, handle: any InAppMessageHandle) -> Bool
}

/// Where impression, click and dismissal ACKs go (the durable `AckQueue` in production).
protocol InAppAckSink: Sendable {
  func delivered(deliveryId: String, token: String) async
  func opened(deliveryId: String, token: String, actionId: String?) async
  func dismissed(deliveryId: String, token: String) async
}

/// Implemented by the SDK's message handle. A layout calls `interrupted()` when the message was torn
/// down with no action by the user, so it can show again.
protocol InAppInterruptible: AnyObject {
  func interrupted()
}

/// Storage key for the In-app cache: scoped to the backend and App ID so environments never share it.
func inAppStateKey(apiBaseURL: URL, appId: String) -> String {
  var base = apiBaseURL.absoluteString
  while base.hasSuffix("/") { base.removeLast() }
  return "comraid:in-app:\(base):\(appId.trimmingCharacters(in: .whitespacesAndNewlines))"
}

/// Sends In-app outcomes through the durable `AckQueue`; `flush` decides when the network is touched.
struct AckQueueInAppSink: InAppAckSink {
  let queue: AckQueue
  let clock: @Sendable () -> Int64
  let flush: @Sendable () async -> Void

  func delivered(deliveryId: String, token: String) async { await enqueue(deliveryId, token, .delivered, nil) }
  func opened(deliveryId: String, token: String, actionId: String?) async {
    await enqueue(deliveryId, token, .opened, actionId)
  }
  func dismissed(deliveryId: String, token: String) async { await enqueue(deliveryId, token, .dismissed, nil) }

  private func enqueue(_ deliveryId: String, _ token: String, _ kind: AckKind, _ actionId: String?) async {
    let now = clock()
    await queue.enqueue(
      QueuedAck(
        deliveryId: deliveryId,
        attributionToken: token,
        kind: kind,
        actionId: (actionId?.isEmpty == false) ? actionId : nil,
        enqueuedAt: now,
        attempts: 0,
        nextAttemptAt: now
      )
    )
    await flush()
  }
}

/// Fetches, caches and shows In-app messages: at most one per app foreground, never one outside its
/// display window, none while paused, and only after a window can draw it (or a presenter takes it).
/// The server decides who may see what; this actor decides when, and keeps a local record of what it
/// already showed so a message cannot reappear before the server has processed its impression.
actor InAppMessageManager {
  private let fetcher: @Sendable () async throws -> [FetchedInAppMessage]
  private let acks: any InAppAckSink
  private let store: any AckQueueStore
  private let stateKey: String
  private let clock: @Sendable () -> Date
  private let display: any InAppDisplay

  private var cache: [FetchedInAppMessage] = []
  private var shownIds: [String] = []
  private var shownThisForeground = false
  /// True from the start of a foreground until its fetch has finished (success or failure): the cache
  /// from an earlier run may be stale, so nothing is shown from it in the meantime.
  private var fetchPending = false
  /// Bumped whenever local state is cleared, so a fetch that started before an opt-out or logout
  /// cannot write its (now unwanted) answer back.
  private var generation = 0
  /// Identifies the latest foreground. A fetch that finishes after a newer foreground began is
  /// superseded: the newer one owns the fetch flag, the cache and the one message to show.
  private var foregroundSeq = 0
  private var paused = false
  private var presenter: InAppMessagePresenter?
  private var listeners: [ComRaidListenerToken: any InAppMessageListener] = [:]
  private var triggerValues: [String: String] = [:]

  private static let maxShownIds = 200

  init(
    fetcher: @escaping @Sendable () async throws -> [FetchedInAppMessage],
    acks: any InAppAckSink,
    store: any AckQueueStore,
    stateKey: String,
    clock: @escaping @Sendable () -> Date,
    display: any InAppDisplay,
    presenter: InAppMessagePresenter? = nil,
    paused: Bool = false,
    listeners: [ComRaidListenerToken: any InAppMessageListener] = [:],
    triggers: [String: String] = [:]
  ) {
    self.presenter = presenter
    self.paused = paused
    self.listeners = listeners
    self.triggerValues = triggers
    self.fetcher = fetcher
    self.acks = acks
    self.store = store
    self.stateKey = stateKey
    self.clock = clock
    self.display = display
    if let raw = store.get(stateKey),
       let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
      cache = parseCachedInAppMessages(object["messages"])
      shownIds = (object["shown"] as? [String]) ?? []
    }
  }

  // MARK: Registrations

  func setPaused(_ value: Bool) { paused = value }
  func isPaused() -> Bool { paused }
  func setPresenter(_ value: InAppMessagePresenter?) { presenter = value }

  @discardableResult
  func addListener(_ listener: any InAppMessageListener, token: ComRaidListenerToken = ComRaidListenerToken()) -> ComRaidListenerToken {
    listeners[token] = listener
    return token
  }

  func removeListener(_ token: ComRaidListenerToken) { listeners[token] = nil }

  func addTrigger(key: String, value: String) { triggerValues[key] = value }
  func addTriggers(_ values: [String: String]) { triggerValues.merge(values) { _, new in new } }
  func removeTrigger(key: String) { triggerValues[key] = nil }
  func clearTriggers() { triggerValues.removeAll() }
  func triggers() -> [String: String] { triggerValues }

  // MARK: Lifecycle

  /// The app came to the foreground: fetch, then show at most one message.
  func onForeground() async {
    foregroundSeq += 1
    let seq = foregroundSeq
    shownThisForeground = false
    fetchPending = true
    let startedAt = generation
    let result = try? await fetcher()
    guard seq == foregroundSeq else { return }
    fetchPending = false
    if generation == startedAt, let fetched = result {
      cache = fetched
      persist()
    }
    await maybeShow()
  }

  /// A window is available: a message that was waiting for one can now be drawn.
  func onHostReady() async {
    await maybeShow()
  }

  /// Forget cached messages, e.g. after the Contact opted out of in-app messages.
  func clearLocalState() {
    generation += 1
    cache = []
    persist()
  }

  /// Forget everything, including what was shown: a different user may now be on this install.
  func reset() {
    generation += 1
    cache = []
    shownIds = []
    shownThisForeground = false
    persist()
  }

  // MARK: Showing

  private func maybeShow() async {
    let currentPresenter = presenter
    // Nothing to draw on yet (no window): keep the message, announce nothing.
    if currentPresenter == nil, !(await display.isAvailable()) { return }
    guard let candidate = claimNext() else { return }
    let handle = InAppOutcomeHandle(fetched: candidate, manager: self)
    notify { $0.willDisplay(candidate.message) }
    if let currentPresenter {
      await currentPresenter(candidate.message, handle, triggerValues)
      return
    }
    if await !display.show(candidate.message, handle: handle) {
      unclaim(candidate)
    }
  }

  /// Pick the oldest message that may show now and mark it shown.
  private func claimNext() -> FetchedInAppMessage? {
    if paused || shownThisForeground || fetchPending { return nil }
    let now = clock()
    guard let next = cache.first(where: { !shownIds.contains($0.message.id) && inWindow($0.message, now) }) else {
      return nil
    }
    shownThisForeground = true
    shownIds.append(next.message.id)
    while shownIds.count > Self.maxShownIds { shownIds.removeFirst() }
    persist()
    return next
  }

  private func unclaim(_ fetched: FetchedInAppMessage) {
    shownThisForeground = false
    shownIds.removeAll { $0 == fetched.message.id }
    persist()
  }

  private func inWindow(_ message: InAppMessage, _ now: Date) -> Bool {
    (message.startAt.map { now >= $0 } ?? true) && (message.endAt.map { now < $0 } ?? true)
  }

  private func notify(_ body: (any InAppMessageListener) -> Void) {
    for listener in listeners.values { body(listener) }
  }

  // MARK: Outcomes (called by `InAppOutcomeHandle`, in order)

  func reportImpression(_ fetched: FetchedInAppMessage) async {
    await ack(fetched) { id, token in await self.acks.delivered(deliveryId: id, token: token) }
    notify { $0.didDisplay(fetched.message) }
  }

  func reportClick(_ fetched: FetchedInAppMessage, button: InAppButton) async {
    await ack(fetched) { id, token in await self.acks.opened(deliveryId: id, token: token, actionId: button.id) }
    notify { $0.didClick(fetched.message, button: button) }
  }

  func reportDismissed(_ fetched: FetchedInAppMessage, afterClick: Bool) async {
    notify { $0.willDismiss(fetched.message) }
    // Closing after a button tap finishes the lifecycle but is not a dismissal: the click is the outcome.
    if !afterClick {
      await ack(fetched) { id, token in await self.acks.dismissed(deliveryId: id, token: token) }
    }
    notify { $0.didDismiss(fetched.message) }
  }

  func reportInterrupted(_ fetched: FetchedInAppMessage) {
    unclaim(fetched)
  }

  /// A Test send has no Delivery, so it never reaches the ACK queue.
  private func ack(_ fetched: FetchedInAppMessage, _ send: (String, String) async -> Void) async {
    if fetched.message.isTest { return }
    guard let id = fetched.deliveryId, let token = fetched.attributionToken else { return }
    await send(id, token)
  }

  private func persist() {
    let object: [String: Any] = ["messages": cache.map { $0.toCacheJSON() }, "shown": shownIds]
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    store.set(stateKey, value: String(decoding: data, as: UTF8.self))
  }
}

/// The handle given to a presenter or default layout. Calls are idempotent and applied in order.
final class InAppOutcomeHandle: InAppMessageHandle, InAppInterruptible, @unchecked Sendable {
  private let fetched: FetchedInAppMessage
  private let manager: InAppMessageManager
  private let lock = NSLock()
  private var impressionDone = false
  private var dismissDone = false
  private var clickedDone = false
  private var last: Task<Void, Never>?

  init(fetched: FetchedInAppMessage, manager: InAppMessageManager) {
    self.fetched = fetched
    self.manager = manager
  }

  func impression() {
    let first = lock.withLock { () -> Bool in
      defer { impressionDone = true }
      return !impressionDone
    }
    guard first else { return }
    chain { await self.manager.reportImpression(self.fetched) }
  }

  func clicked(buttonId: String) {
    guard let button = fetched.message.buttons.first(where: { $0.id == buttonId }) else { return }
    lock.withLock { clickedDone = true }
    chain { await self.manager.reportClick(self.fetched, button: button) }
  }

  func dismissed() {
    let state = lock.withLock { () -> (first: Bool, afterClick: Bool) in
      defer { dismissDone = true }
      return (!dismissDone, clickedDone)
    }
    guard state.first else { return }
    chain { await self.manager.reportDismissed(self.fetched, afterClick: state.afterClick) }
  }

  func interrupted() {
    let skip = lock.withLock { dismissDone }
    guard !skip else { return }
    chain { await self.manager.reportInterrupted(self.fetched) }
  }

  /// Wait until every call made so far has been applied (tests, and `flush` points).
  func settle() async {
    let task = lock.withLock { last }
    await task?.value
  }

  private func chain(_ work: @escaping @Sendable () async -> Void) {
    lock.lock()
    let previous = last
    last = Task {
      await previous?.value
      await work()
    }
    lock.unlock()
  }
}
