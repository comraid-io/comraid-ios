import Foundation
import Testing
@testable import ComRaid

/// Seam: the public In-app message API on `ComRaid` and how it is wired to foregrounds, ACKs and opt-out.

private final class FakeServer: HttpTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [HttpRequest] = []
  private var _inAppBody = FakeServer.empty
  static let empty = #"{"messages":[]}"#
  /// When set, the in-app GET waits here, to prove other work does not wait for it.
  var inAppGate: ServerGate?

  var inAppBody: String {
    get { lock.withLock { _inAppBody } }
    set { lock.withLock { _inAppBody = newValue } }
  }
  var requests: [HttpRequest] { lock.withLock { recorded } }

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock { recorded.append(request) }
    if request.method == "GET", request.path.hasSuffix("/in-app-messages") {
      if let inAppGate { await inAppGate.wait() }
      return HttpResponse(statusCode: 200, body: Data(inAppBody.utf8))
    }
    if request.method == "POST", request.path == "/mobile/subscriptions" {
      return HttpResponse(
        statusCode: 201,
        body: Data(#"{"subscription_id":"sub-2","subscription_credential":"cred-2","channel":"push","anonymous":true,"platform":"ios","provider":"apns"}"#.utf8)
      )
    }
    return HttpResponse(statusCode: 200, body: Data("{}".utf8))
  }

  func posts(_ suffix: String) -> [HttpRequest] { requests.filter { $0.method == "POST" && $0.path.hasSuffix(suffix) } }
  func fetches() -> Int { requests.filter { $0.method == "GET" && $0.path.hasSuffix("/in-app-messages") }.count }
}

private final class ServerGate: @unchecked Sendable {
  private let lock = NSLock()
  private var waiter: CheckedContinuation<Void, Never>?
  private var opened = false
  private var entered = false
  var hasEntered: Bool { lock.withLock { entered } }
  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      entered = true
      if opened { lock.unlock(); continuation.resume() } else { waiter = continuation; lock.unlock() }
    }
  }
  func open() {
    lock.lock()
    opened = true
    let pending = waiter
    waiter = nil
    lock.unlock()
    pending?.resume()
  }
  func waitUntilEntered() async { for _ in 0..<2_000 where !hasEntered { await Task.yield() } }
}

private struct FakeTokenProvider: TokenProvider {
  func currentToken() async throws -> String { "apns-token" }
}

private final class MemoryStore: AckQueueStore, @unchecked Sendable {
  private let lock = NSLock()
  private var map: [String: String] = [:]
  func get(_ key: String) -> String? { lock.withLock { map[key] } }
  func set(_ key: String, value: String) { lock.withLock { map[key] = value } }
}

@MainActor
private final class FakeDisplay: InAppDisplay {
  var available = true
  var shown: [InAppMessage] = []
  var lastHandle: (any InAppMessageHandle)?
  func isAvailable() -> Bool { available }
  func show(_ message: InAppMessage, handle: any InAppMessageHandle) -> Bool {
    guard available else { return false }
    shown.append(message)
    lastHandle = handle
    return true
  }
}

@MainActor
private final class Capture {
  var messages: [InAppMessage] = []
  var handles: [any InAppMessageHandle] = []
  var triggers: [String: String] = [:]
  func record(_ message: InAppMessage, _ handle: any InAppMessageHandle, _ triggers: [String: String]) {
    messages.append(message)
    handles.append(handle)
    self.triggers = triggers
  }
}

private final class RecordingListener: InAppMessageListener, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  var events: [String] { lock.withLock { recorded } }
  func didDisplay(_ message: InAppMessage) { lock.withLock { recorded.append("didDisplay:\(message.id)") } }
  func didClick(_ message: InAppMessage, button: InAppButton) {
    lock.withLock { recorded.append("didClick:\(message.id):\(button.deepLink ?? "nil")") }
  }
}

private func message(_ id: String, buttons: String = #"[{"id":"open","label":"Open","deep_link":"myapp://x"}]"#) -> String {
  #"{"id":"\#(id)","delivery_id":"d-\#(id)","attribution_token":"t-\#(id)","layout":"modal","title":"Title \#(id)","body":"Body \#(id)","buttons":\#(buttons)}"#
}

private func serve(_ server: FakeServer, _ messages: String...) {
  server.inAppBody = #"{"messages":[\#(messages.joined(separator: ","))]}"#
}

private struct Harness {
  let comraid: ComRaid
  let server: FakeServer
  let store: InMemorySubscriptionStore
  @MainActor let display: FakeDisplay

  @MainActor
  static func make(subscribed: Bool = true, configure: Bool = true) async throws -> Harness {
    let harness = Harness(comraid: ComRaid(), server: FakeServer(), store: InMemorySubscriptionStore(), display: FakeDisplay())
    if subscribed { harness.store.save(subscriptionId: "sub-1", credential: "cred-1") }
    if configure { try await harness.configure() }
    return harness
  }

  @MainActor
  func configure() async throws {
    try await comraid.configureForTests(
      .init(appId: "cr_app_test", apnsEnvironment: .sandbox),
      transport: server,
      tokenProvider: FakeTokenProvider(),
      subscriptionStore: store,
      ackQueueStore: MemoryStore(),
      inAppDisplay: display
    )
  }

  /// A real foreground: the app was in the background first (cold start counts too).
  func foreground() async {
    await comraid.handleAppBackgroundForTests()
    await comraid.handleAppForegroundForTests()
  }
}

@Test @MainActor func everyForegroundFetchesEvenWhenTheSessionIsDebounced() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }

  await h.foreground()
  await h.foreground()

  #expect(h.server.fetches() == 2)
  #expect(h.server.posts("/session").count <= 1) // the session debounce must not apply to in-app fetches
  #expect(capture.messages.map(\.id) == ["m1"])
}

@Test @MainActor func aBriefInactiveBlipDoesNotRefetch() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"))
  await h.comraid.setInAppMessagePresenter { _, _, _ in }

  await h.foreground() // cold start
  await h.comraid.handleAppForegroundForTests() // active again with no background in between (a system alert)

  #expect(h.server.fetches() == 1)
}

@Test @MainActor func nothingIsFetchedWithoutARegisteredSubscription() async throws {
  let h = try await Harness.make(subscribed: false)
  serve(h.server, message("m1"))

  await h.foreground()

  #expect(h.server.fetches() == 0)
}

@Test @MainActor func outcomesReachTheServerThroughTheAckQueue() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }
  await h.foreground()

  let handle = try #require(capture.handles.first)
  handle.impression()
  handle.clicked(buttonId: "open")
  await (handle as? InAppOutcomeHandle)?.settle()
  await h.comraid.flushAcks()

  let delivered = try #require(h.server.posts("/deliveries/d-m1/delivered").first)
  let deliveredBody = try JSONSerialization.jsonObject(with: #require(delivered.body)) as! [String: Any]
  #expect(deliveredBody["attribution_token"] as? String == "t-m1")
  let opened = try #require(h.server.posts("/deliveries/d-m1/opened").first)
  let openedBody = try JSONSerialization.jsonObject(with: #require(opened.body)) as! [String: Any]
  #expect(openedBody["action_id"] as? String == "open")
  #expect(h.server.posts("/deliveries/d-m1/dismissed").isEmpty)
}

@Test @MainActor func aDismissalReachesTheServerThroughTheAckQueue() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }
  await h.foreground()

  let handle = try #require(capture.handles.first)
  handle.impression()
  handle.dismissed()
  await (handle as? InAppOutcomeHandle)?.settle()
  await h.comraid.flushAcks()

  #expect(h.server.posts("/deliveries/d-m1/dismissed").count == 1)
}

@Test @MainActor func aPausedSdkShowsNothingUntilResumed() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }
  await h.comraid.setInAppMessagesPaused(true)
  #expect(await h.comraid.isInAppMessagesPaused())

  await h.foreground()
  #expect(capture.messages.isEmpty)

  await h.comraid.setInAppMessagesPaused(false)
  #expect(await h.comraid.isInAppMessagesPaused() == false)
  await h.comraid.handleAppForegroundForTests() // active again: a waiting message can now show
  #expect(capture.messages.map(\.id) == ["m1"])
}

@Test @MainActor func triggersArePassedToThePresenter() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }
  await h.comraid.addTrigger(key: "screen", value: "checkout")
  await h.comraid.addTriggers(["plan": "pro", "tmp": "x"])
  await h.comraid.removeTrigger(key: "tmp")

  await h.foreground()

  #expect(capture.triggers == ["screen": "checkout", "plan": "pro"])
  #expect(await h.comraid.getTriggers() == ["screen": "checkout", "plan": "pro"])
  await h.comraid.clearTriggers()
  #expect(await h.comraid.getTriggers().isEmpty)
}

@Test @MainActor func registrationsMadeBeforeConfigureStillApply() async throws {
  let h = try await Harness.make(configure: false)
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }
  await h.comraid.addTrigger(key: "early", value: "yes")
  serve(h.server, message("m1"))

  try await h.configure()
  await h.foreground()

  #expect(capture.messages.map(\.id) == ["m1"])
  #expect(capture.triggers == ["early": "yes"])
}

@Test @MainActor func aRegisteredListenerObservesTheLifecycleUntilRemoved() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"), message("m2"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }
  let listener = RecordingListener()
  let token = await h.comraid.addInAppMessageListener(listener)

  await h.foreground()
  capture.handles[0].impression()
  capture.handles[0].clicked(buttonId: "open")
  await (capture.handles[0] as? InAppOutcomeHandle)?.settle()
  #expect(listener.events == ["didDisplay:m1", "didClick:m1:myapp://x"])

  await h.comraid.removeInAppMessageListener(token)
  await h.foreground()
  capture.handles[1].impression()
  await (capture.handles[1] as? InAppOutcomeHandle)?.settle()
  #expect(listener.events.count == 2)
}

@Test @MainActor func theInAppOptOutPostsItsChannelAndStopsCachedMessagesShowing() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"), message("m2"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }
  await h.foreground() // shows m1, caches m2

  try await h.comraid.optOutInApp()
  h.server.inAppBody = FakeServer.empty // the server returns nothing for an opted-out Contact
  await h.foreground()

  let optOut = try #require(h.server.posts("/opt-out").first)
  let body = try JSONSerialization.jsonObject(with: #require(optOut.body)) as! [String: Any]
  #expect(body["channel"] as? String == "in_app")
  #expect(capture.messages.map(\.id) == ["m1"])

  try await h.comraid.optInInApp()
  let optIn = try #require(h.server.posts("/opt-in").first)
  #expect((try JSONSerialization.jsonObject(with: #require(optIn.body)) as! [String: Any])["channel"] as? String == "in_app")
}

@Test @MainActor func theDefaultLayoutIsShownOnTheDisplayAndReportsOutcomes() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"))

  await h.foreground()

  #expect(h.display.shown.map(\.id) == ["m1"])
  let handle = try #require(h.display.lastHandle)
  handle.impression()
  handle.clicked(buttonId: "open")
  await (handle as? InAppOutcomeHandle)?.settle()
  await h.comraid.flushAcks()
  #expect(h.server.posts("/deliveries/d-m1/delivered").count == 1)
  #expect(h.server.posts("/deliveries/d-m1/opened").count == 1)
  #expect(h.server.posts("/deliveries/d-m1/dismissed").isEmpty)
}

@Test @MainActor func aMessageWaitsUntilAWindowIsAvailable() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"))
  h.display.available = false

  await h.foreground()
  #expect(h.display.shown.isEmpty)

  h.display.available = true
  await h.comraid.handleAppForegroundForTests() // active again with a window now available
  #expect(h.display.shown.map(\.id) == ["m1"])
}

@Test @MainActor func logoutDropsThePreviousUsersCachedMessagesAndWhatTheySaw() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"), message("m2"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }
  await h.foreground() // shows m1, caches m2

  try await h.comraid.logout() // the next user gets a fresh Subscription
  serve(h.server, message("m1")) // the server's answer for the new Subscription
  await h.foreground()

  #expect(capture.messages.map(\.id) == ["m1", "m1"]) // m1 shows again for the new user; the old user's m2 never does
}

@Test @MainActor func loginDropsCachedMessagesSoTheServerDecidesAgain() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"), message("m2"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }
  await h.foreground() // shows m1, caches m2

  serve(h.server, message("m3")) // the Contact is now a known user with a different audience
  try await h.comraid.login(externalUserId: "user-42")
  await h.comraid.settleInAppForTests() // login fetches again by itself: no new foreground is needed

  #expect(capture.messages.map(\.id) == ["m1", "m3"])
}

@Test @MainActor func loggingInAgainAsTheSameUserKeepsWhatWasShown() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }
  try await h.comraid.login(externalUserId: "user-42")
  await h.comraid.settleInAppForTests() // shows m1 for the new user
  let fetchesBefore = h.server.fetches()

  try await h.comraid.login(externalUserId: "user-42") // same user again: nothing changed
  await h.comraid.settleInAppForTests()

  #expect(h.server.fetches() == fetchesBefore)
  #expect(capture.messages.map(\.id) == ["m1"])
}

@Test @MainActor func aFreshInstallFetchesAsSoonAsItHasRegistered() async throws {
  let h = try await Harness.make(subscribed: false)
  serve(h.server, message("m1"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }

  await h.foreground() // launch: there is no Subscription yet, so nothing can be fetched
  #expect(h.server.fetches() == 0)

  try await h.comraid.register()
  await h.comraid.settleInAppForTests()

  #expect(h.server.fetches() == 1)
  #expect(capture.messages.map(\.id) == ["m1"])
}

@Test @MainActor func theFirstForegroundAfterRegistrationFailureStillFetchesLater() async throws {
  let h = try await Harness.make(subscribed: false)
  serve(h.server, message("m1"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }

  await h.comraid.handleAppForegroundForTests() // launch, not registered yet
  h.store.save(subscriptionId: "sub-1", credential: "cred-1") // registration finished elsewhere
  await h.comraid.handleAppForegroundForTests() // the app becomes active again

  #expect(capture.messages.map(\.id) == ["m1"])
}

@Test @MainActor func optingBackInFetchesAgain() async throws {
  let h = try await Harness.make()
  serve(h.server, message("m1"))
  let capture = Capture()
  await h.comraid.setInAppMessagePresenter { capture.record($0, $1, $2) }
  await h.foreground() // shows m1
  try await h.comraid.optOutInApp()

  serve(h.server, message("m2"))
  try await h.comraid.optInInApp()
  await h.comraid.settleInAppForTests()

  #expect(capture.messages.map(\.id) == ["m1", "m2"])
}

@Test @MainActor func aSlowInAppFetchDoesNotDelayRecordingTheSession() async throws {
  let h = try await Harness.make()
  let gate = ServerGate()
  h.server.inAppGate = gate
  serve(h.server, message("m1"))
  await h.comraid.setInAppMessagePresenter { _, _, _ in }

  await h.comraid.handleAppForegroundWithoutSettlingForTests() // returns although the fetch is still held open
  await gate.waitUntilEntered()

  #expect(h.server.posts("/session").count == 1) // the session was recorded while the fetch was in flight

  gate.open()
  await h.comraid.settleInAppForTests()
}
