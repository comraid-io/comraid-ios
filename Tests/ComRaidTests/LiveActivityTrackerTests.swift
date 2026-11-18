import Foundation
import Testing
@testable import ComRaid

/// Seam: the Live activity tracker behind `ComRaid.trackActivity`. ActivityKit's `Activity` cannot be
/// built in a test, so these tests drive the tracker through a fake `LiveActivityHandle` and a
/// recording transport and assert the requests that reach the server.

private final class FakeHandle: LiveActivityHandle, @unchecked Sendable {
  let tokens: AsyncStream<Data>
  private let tokenContinuation: AsyncStream<Data>.Continuation
  let states: AsyncStream<LiveActivityState>
  private let stateContinuation: AsyncStream<LiveActivityState>.Continuation
  private let lock = NSLock()
  private var _endCalls = 0
  var endCalls: Int { lock.withLock { _endCalls } }

  init() {
    (tokens, tokenContinuation) = AsyncStream<Data>.makeStream()
    (states, stateContinuation) = AsyncStream<LiveActivityState>.makeStream()
  }

  func tokenUpdates() -> AsyncStream<Data> { tokens }
  func stateUpdates() -> AsyncStream<LiveActivityState> { states }
  func end() async { lock.withLock { _endCalls += 1 } }

  func emitToken(_ bytes: [UInt8]) { tokenContinuation.yield(Data(bytes)) }
  func emitState(_ state: LiveActivityState) { stateContinuation.yield(state) }
  func finish() {
    tokenContinuation.finish()
    stateContinuation.finish()
  }
}

private final class RecordingTransport: HttpTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [HttpRequest] = []
  private var scripted: [HttpResponse] = []
  var requests: [HttpRequest] { lock.withLock { recorded } }
  /// Responses used in order; once empty, every request gets 200.
  func script(_ responses: HttpResponse...) { lock.withLock { scripted = responses } }

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock {
      recorded.append(request)
      if !scripted.isEmpty { return scripted.removeFirst() }
      let status = request.path.hasSuffix("/ended") ? 204 : 200
      return HttpResponse(statusCode: status, body: Data("{}".utf8))
    }
  }

  func activityRequests() -> [HttpRequest] { requests.filter { $0.path.contains("/activities/") } }
}

private struct FakeTokenProvider: TokenProvider {
  func currentToken() async throws -> String { "apns-token" }
}

private struct Harness {
  let comraid: ComRaid
  let transport: RecordingTransport
  let store: InMemorySubscriptionStore

  /// A configured SDK with a registered Subscription. `loggedIn` sets the Contact's external user id.
  static func make(loggedIn: Bool = true, retryDelays: [TimeInterval] = []) async throws -> Harness {
    let comraid = ComRaid()
    let transport = RecordingTransport()
    let store = InMemorySubscriptionStore()
    store.save(subscriptionId: "sub-1", credential: "cred-1")
    if loggedIn { store.setExternalUserId("user_123") }
    try await comraid.configureForTests(
      .init(appId: "cr_app_test", apnsEnvironment: .sandbox),
      transport: transport,
      tokenProvider: FakeTokenProvider(),
      subscriptionStore: store,
      activityRetryDelays: retryDelays
    )
    return Harness(comraid: comraid, transport: transport, store: store)
  }
}

private func body(_ request: HttpRequest) throws -> [String: Any] {
  try JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
}

@Test func theUpdateTokenIsSentToTheServerAsHex() async throws {
  let h = try await Harness.make()
  let handle = FakeHandle()
  await h.comraid.track(handle: handle, id: "order_8392", type: "delivery")

  handle.emitToken([0xAB, 0xCD, 0x01])
  handle.finish()
  await h.comraid.settleActivitiesForTests()

  let request = try #require(h.transport.activityRequests().first)
  #expect(request.method == "PUT")
  #expect(request.path == "/mobile/subscriptions/sub-1/activities/order_8392/token")
  #expect(request.headers["X-ComRaid-App-Id"] == "cr_app_test")
  let b = try body(request)
  #expect(b["subscription_credential"] as? String == "cred-1")
  #expect(b["activity_type"] as? String == "delivery")
  #expect(b["update_token"] as? String == "abcd01")
}

@Test func aRotatedTokenIsSentAgain() async throws {
  let h = try await Harness.make()
  let handle = FakeHandle()
  await h.comraid.track(handle: handle, id: "order_8392", type: "delivery")

  handle.emitToken([0x01])
  handle.emitToken([0x02])
  handle.finish()
  await h.comraid.settleActivitiesForTests()

  let tokens = try h.transport.activityRequests().map { try body($0)["update_token"] as? String }
  #expect(tokens.last == "02") // the newest token always wins
  #expect(tokens.contains("02"))
}

@Test func anEndedActivityIsReportedAndTrackingStops() async throws {
  let h = try await Harness.make()
  let handle = FakeHandle()
  await h.comraid.track(handle: handle, id: "order_8392", type: "delivery")

  handle.emitState(.active)
  handle.emitState(.ended)
  handle.finish()
  await h.comraid.settleActivitiesForTests()

  let ended = try #require(h.transport.activityRequests().first { $0.path.hasSuffix("/ended") })
  #expect(ended.method == "POST")
  #expect(ended.path == "/mobile/subscriptions/sub-1/activities/order_8392/ended")
  let b = try body(ended)
  #expect(b["reason"] as? String == "ended")
  #expect(b["subscription_credential"] as? String == "cred-1")
  #expect(await h.comraid.trackedActivities().isEmpty)
}

@Test func aDismissedActivityIsReportedAsDismissed() async throws {
  let h = try await Harness.make()
  let handle = FakeHandle()
  await h.comraid.track(handle: handle, id: "order_8392", type: "delivery")

  handle.emitState(.dismissed)
  handle.finish()
  await h.comraid.settleActivitiesForTests()

  let ended = try #require(h.transport.activityRequests().first { $0.path.hasSuffix("/ended") })
  #expect(try body(ended)["reason"] as? String == "dismissed")
}

@Test func nothingIsSentUntilTheContactIsLoggedInThenTheLatestTokenIsSentOnce() async throws {
  let h = try await Harness.make(loggedIn: false)
  let handle = FakeHandle()
  await h.comraid.track(handle: handle, id: "order_8392", type: "delivery")

  handle.emitToken([0x01])
  handle.emitToken([0x02])
  handle.finish()
  await h.comraid.settleActivitiesForTests()
  #expect(h.transport.activityRequests().isEmpty) // anonymous: the server would refuse it

  h.transport.script(
    HttpResponse(
      statusCode: 200,
      body: Data(#"{"subscription_id":"sub-1","contact_id":"c-1","external_user_id":"user_123","anonymous":false,"verified":false}"#.utf8)
    )
  )
  try await h.comraid.login(externalUserId: "user_123")
  await h.comraid.settleActivitiesForTests() // the flush runs in the background, not inside login

  let sent = try h.transport.activityRequests().map { try body($0)["update_token"] as? String }
  #expect(sent == ["02"]) // once, with the newest token
}

@Test func aNetworkFailureIsRetriedAndARejectionIsNot() async throws {
  let failing = try await Harness.make(retryDelays: [0, 0])
  failing.transport.script(
    HttpResponse(statusCode: 503, body: Data("{}".utf8)),
    HttpResponse(statusCode: 503, body: Data("{}".utf8))
  ) // then 200
  let a = FakeHandle()
  await failing.comraid.track(handle: a, id: "order_1", type: "delivery")
  a.emitToken([0x01])
  a.finish()
  await failing.comraid.settleActivitiesForTests()
  #expect(failing.transport.activityRequests().count == 3)

  let rejected = try await Harness.make(retryDelays: [0, 0])
  rejected.transport.script(HttpResponse(statusCode: 409, body: Data(#"{"error":{"code":"activity_not_active","message":"x"}}"#.utf8)))
  let b = FakeHandle()
  await rejected.comraid.track(handle: b, id: "order_2", type: "delivery")
  b.emitToken([0x01])
  b.finish()
  await rejected.comraid.settleActivitiesForTests()
  #expect(rejected.transport.activityRequests().count == 1) // a 409 will not get better
}

@Test func theHostCanEndAndListTrackedActivities() async throws {
  let h = try await Harness.make()
  let handle = FakeHandle()
  await h.comraid.track(handle: handle, id: "order_8392", type: "delivery")

  let listed = await h.comraid.trackedActivities()
  #expect(listed == [ComRaidTrackedActivity(id: "order_8392", type: "delivery")])

  #expect(await h.comraid.endActivity(id: "order_8392"))
  #expect(handle.endCalls == 1)
  #expect(await h.comraid.endActivity(id: "nope") == false)
  handle.finish()
  await h.comraid.settleActivitiesForTests()
}

@Test func trackingTheSameActivityAgainReplacesTheEarlierTracking() async throws {
  let h = try await Harness.make()
  let first = FakeHandle()
  let second = FakeHandle()
  await h.comraid.track(handle: first, id: "order_8392", type: "delivery")
  await h.comraid.track(handle: second, id: "order_8392", type: "delivery")

  #expect(await h.comraid.trackedActivities().count == 1)
  second.emitToken([0x09])
  second.finish()
  first.finish()
  await h.comraid.settleActivitiesForTests()
  #expect(try h.transport.activityRequests().map { try body($0)["update_token"] as? String } == ["09"])
}

/// Holds every activity request until released, to show what does and does not wait for the network.
private final class GatedTransport: HttpTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [HttpRequest] = []
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var open = false
  var requests: [HttpRequest] { lock.withLock { recorded } }

  func release() {
    let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
      open = true
      defer { waiting = [] }
      return waiting
    }
    toResume.forEach { $0.resume() }
  }

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock { recorded.append(request) }
    if request.path.contains("/activities/") {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        let resumeNow = lock.withLock { () -> Bool in
          if open { return true }
          waiting.append(c)
          return false
        }
        if resumeNow { c.resume() }
      }
      return HttpResponse(statusCode: request.path.hasSuffix("/ended") ? 204 : 200, body: Data("{}".utf8))
    }
    return HttpResponse(
      statusCode: 200,
      body: Data(#"{"subscription_id":"sub-1","contact_id":"c-1","external_user_id":"user_123","anonymous":false,"verified":false}"#.utf8)
    )
  }
}

@Test func loginDoesNotWaitForTheActivityRequests() async throws {
  let comraid = ComRaid()
  let transport = GatedTransport()
  let store = InMemorySubscriptionStore()
  store.save(subscriptionId: "sub-1", credential: "cred-1")
  try await comraid.configureForTests(
    .init(appId: "cr_app_test", apnsEnvironment: .sandbox),
    transport: transport, tokenProvider: FakeTokenProvider(), subscriptionStore: store)
  let handle = FakeHandle()
  await comraid.track(handle: handle, id: "order_8392", type: "delivery")
  handle.emitToken([0x01])
  handle.finish()

  try await comraid.login(externalUserId: "user_123") // returns although the token request is held
  transport.release()
  await comraid.settleActivitiesForTests()

  #expect(transport.requests.contains { $0.path.hasSuffix("/activities/order_8392/token") })
}

@Test func aTokenThatArrivesWhileAFlushChecksReadinessIsStillSent() async throws {
  let transport = RecordingTransport()
  let gate = ReadinessGate()
  let tracker = ActivityTracker(
    api: MobileApiClient(appId: "cr_app_test", apnsEnvironment: .sandbox, transport: transport),
    retryDelays: []
  ) { await gate.ready() }
  let handle = FakeHandle()
  await tracker.track(handle: handle, id: "order_8392", type: "delivery")

  // A flush starts with nothing to send and is suspended in its readiness check ...
  let flush = Task { await tracker.flush() }
  await gate.waitUntilAsked()
  // ... when the token arrives. Its own drain steps aside because the flush's drain is running.
  handle.emitToken([0x01])
  handle.finish()
  try await Task.sleep(nanoseconds: 50_000_000) // let the token reach the tracker
  await gate.open()
  await flush.value
  await tracker.settleForTests()

  let paths = transport.activityRequests().map(\.path)
  #expect(paths.contains { $0.hasSuffix("/token") }, "the token was dropped: \(paths)")
}

private actor ReadinessGate {
  private var asked = false
  private var isOpen = false
  private var askWaiters: [CheckedContinuation<Void, Never>] = []
  private var openWaiters: [CheckedContinuation<Void, Never>] = []

  func ready() async -> ActivityReadiness? {
    asked = true
    askWaiters.forEach { $0.resume() }
    askWaiters = []
    if !isOpen { await withCheckedContinuation { openWaiters.append($0) } }
    return ActivityReadiness(subscriptionId: "sub-1", credential: "cred-1")
  }

  func waitUntilAsked() async {
    if asked { return }
    await withCheckedContinuation { askWaiters.append($0) }
  }

  func open() {
    isOpen = true
    openWaiters.forEach { $0.resume() }
    openWaiters = []
  }
}

@Test func anAuthErrorKeepsTheTokenPendingSoItIsSentAgainLater() async throws {
  let h = try await Harness.make()
  h.transport.script(HttpResponse(statusCode: 401, body: Data(#"{"error":{"code":"unauthorized","message":"x"}}"#.utf8)))
  let handle = FakeHandle()
  await h.comraid.track(handle: handle, id: "order_8392", type: "delivery")
  handle.emitToken([0x01])
  handle.finish()
  await h.comraid.settleActivitiesForTests()
  #expect(h.transport.activityRequests().count == 1) // no retry storm on a refused credential

  await h.comraid.flushActivitiesForTests() // for example after the next login or foreground
  await h.comraid.settleActivitiesForTests()
  #expect(h.transport.activityRequests().count == 2) // the token was not written off
}

@Test func anActivityThatEndedWhileLoggedOutIsNotListedAsTracked() async throws {
  let h = try await Harness.make(loggedIn: false)
  let handle = FakeHandle()
  await h.comraid.track(handle: handle, id: "order_8392", type: "delivery")
  #expect(await h.comraid.trackedActivities().count == 1)

  handle.emitState(.ended)
  handle.finish()
  await h.comraid.settleActivitiesForTests()

  #expect(h.transport.activityRequests().isEmpty) // cannot be reported until the Contact logs in
  #expect(await h.comraid.trackedActivities().isEmpty) // but it is over, so it is not listed
}
