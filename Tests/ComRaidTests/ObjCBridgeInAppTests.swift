import Foundation
import Testing
@testable import ComRaid

/// Seam: the Objective-C bridge (`ComraidBridge`) that React Native's iOS module calls for In-app
/// messages. It is driven through the real SDK, with fakes for the network and the window.

private final class FakeServer: HttpTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [HttpRequest] = []
  private var _body = #"{"messages":[]}"#
  var inAppBody: String {
    get { lock.withLock { _body } }
    set { lock.withLock { _body = newValue } }
  }
  var requests: [HttpRequest] { lock.withLock { recorded } }

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock { recorded.append(request) }
    if request.method == "GET", request.path.hasSuffix("/in-app-messages") {
      return HttpResponse(statusCode: 200, body: Data(inAppBody.utf8))
    }
    return HttpResponse(statusCode: 200, body: Data("{}".utf8))
  }
  func posts(_ suffix: String) -> [HttpRequest] { requests.filter { $0.method == "POST" && $0.path.hasSuffix(suffix) } }
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
  var shown: [InAppMessage] = []
  var lastHandle: (any InAppMessageHandle)?
  func isAvailable() -> Bool { true }
  func show(_ message: InAppMessage, handle: any InAppMessageHandle) -> Bool {
    shown.append(message)
    lastHandle = handle
    return true
  }
}

private final class Emitted: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [(name: String, payload: NSDictionary)] = []
  func add(_ name: String, _ payload: NSDictionary) { lock.withLock { items.append((name, payload)) } }
  var all: [(name: String, payload: NSDictionary)] { lock.withLock { items } }
  func lifecycleTypes() -> [String] {
    all.filter { $0.name == "comraid_in_app_lifecycle" }.compactMap { $0.payload["type"] as? String }
  }
  func presents() -> [NSDictionary] { all.filter { $0.name == "comraid_in_app_present" }.map(\.payload) }
}

private let messageJSON = #"""
{"id":"m1","delivery_id":"d-m1","attribution_token":"t-m1","layout":"banner_top","title":"Welcome","body":"Hi",
 "image_url":"https://cdn.example.com/a.png",
 "buttons":[{"id":"open","label":"Open","deep_link":"myapp://x"},{"id":"later","label":"Later"}],
 "start_at":"2026-01-01T00:00:00Z","end_at":"2099-01-01T00:00:00Z"}
"""#

private struct Harness {
  let comraid: ComRaid
  let bridge: ComRaidObjCBridge
  let server: FakeServer
  let emitted: Emitted
  @MainActor let display: FakeDisplay

  /// A fresh SDK behind the shared bridge, with a Subscription and a message waiting on the server.
  @MainActor
  static func make() async throws -> Harness {
    let h = Harness(
      comraid: ComRaid.shared, bridge: ComRaidObjCBridge.shared,
      server: FakeServer(), emitted: Emitted(), display: FakeDisplay()
    )
    await h.comraid.resetForTests()
    h.bridge.resetForTests()
    let store = InMemorySubscriptionStore()
    store.save(subscriptionId: "sub-1", credential: "cred-1")
    h.server.inAppBody = #"{"messages":[\#(messageJSON)]}"#
    try await h.comraid.configureForTests(
      .init(appId: "cr_app_test", apnsEnvironment: .sandbox),
      transport: h.server,
      tokenProvider: FakeTokenProvider(),
      subscriptionStore: store,
      ackQueueStore: MemoryStore(),
      inAppDisplay: h.display
    )
    h.bridge.setEventEmitter { [emitted = h.emitted] name, payload in emitted.add(name, payload) }
    await h.bridge.settleForTests() // the In-app listener is registered asynchronously
    return h
  }

  func foreground() async {
    await comraid.handleAppBackgroundForTests()
    await comraid.handleAppForegroundForTests()
  }
}

private func call(_ body: @Sendable (@escaping @Sendable (NSError?) -> Void) -> Void) async -> NSError? {
  await withCheckedContinuation { continuation in
    body { error in continuation.resume(returning: error) }
  }
}

@Test @MainActor func triggersRoundTripThroughTheBridge() async throws {
  let h = try await Harness.make()

  #expect(await call { h.bridge.addTrigger(key: "screen", value: "checkout", completion: $0) } == nil)
  #expect(await call { h.bridge.addTriggers(json: #"{"plan":"pro","tmp":"x"}"#, completion: $0) } == nil)
  #expect(await call { h.bridge.removeTrigger(key: "tmp", completion: $0) } == nil)

  let triggers = await withCheckedContinuation { (c: CheckedContinuation<[String: String]?, Never>) in
    h.bridge.getTriggers { value, _ in c.resume(returning: value as? [String: String]) }
  }
  #expect(triggers == ["screen": "checkout", "plan": "pro"])

  #expect(await call { h.bridge.clearTriggers(completion: $0) } == nil)
  let cleared = await withCheckedContinuation { (c: CheckedContinuation<[String: String]?, Never>) in
    h.bridge.getTriggers { value, _ in c.resume(returning: value as? [String: String]) }
  }
  #expect(cleared?.isEmpty == true)
}

@Test @MainActor func addTriggersRejectsJSONThatIsNotAStringMap() async throws {
  let h = try await Harness.make()

  #expect(await call { h.bridge.addTriggers(json: "[1,2]", completion: $0) } != nil)
  #expect(await call { h.bridge.addTriggers(json: #"{"a":1}"#, completion: $0) } != nil)
  #expect(await call { h.bridge.addTriggers(json: "not json", completion: $0) } != nil)
}

@Test @MainActor func pauseRoundTripsThroughTheBridge() async throws {
  let h = try await Harness.make()

  #expect(await call { h.bridge.setInAppMessagesPaused(true, completion: $0) } == nil)
  let paused = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
    h.bridge.isInAppMessagesPaused { value, _ in c.resume(returning: value) }
  }
  #expect(paused)
}

@Test @MainActor func theInAppOptOutAndOptInPostTheirChannel() async throws {
  let h = try await Harness.make()

  #expect(await call { h.bridge.optOutInApp(completion: $0) } == nil)
  #expect(await call { h.bridge.optInInApp(completion: $0) } == nil)
  await h.comraid.settleInAppForTests() // opting back in fetches again; do not leave that running into the next test

  let out = try #require(h.server.posts("/opt-out").first)
  #expect((try JSONSerialization.jsonObject(with: #require(out.body)) as! [String: Any])["channel"] as? String == "in_app")
  let back = try #require(h.server.posts("/opt-in").first)
  #expect((try JSONSerialization.jsonObject(with: #require(back.body)) as! [String: Any])["channel"] as? String == "in_app")
}

@Test @MainActor func lifecycleEventsAreEmittedToTheHost() async throws {
  let h = try await Harness.make()
  await h.foreground()
  let handle = try #require(h.display.lastHandle)

  handle.impression()
  handle.clicked(buttonId: "open")
  handle.dismissed()
  await (handle as? InAppOutcomeHandle)?.settle()

  #expect(h.emitted.lifecycleTypes() == ["willDisplay", "didDisplay", "didClick", "willDismiss", "didDismiss"])
  let click = try #require(h.emitted.all.first { ($0.payload["type"] as? String) == "didClick" }?.payload)
  #expect((click["button"] as? [String: Any])?["id"] as? String == "open")
  #expect((click["button"] as? [String: Any])?["deepLink"] as? String == "myapp://x")
}

@Test @MainActor func theMessageIsDescribedInTheWireShapeTheJSLayerParses() async throws {
  let h = try await Harness.make()
  await h.foreground()

  let willDisplay = try #require(h.emitted.all.first { ($0.payload["type"] as? String) == "willDisplay" }?.payload)
  let message = try #require(willDisplay["message"] as? [String: Any])
  #expect(message["id"] as? String == "m1")
  #expect(message["layout"] as? String == "banner_top")
  #expect(message["title"] as? String == "Welcome")
  #expect(message["body"] as? String == "Hi")
  #expect(message["imageUrl"] as? String == "https://cdn.example.com/a.png")
  #expect(message["isTest"] as? Bool == false)
  #expect(message["startAt"] as? Double == 1_767_225_600_000) // epoch milliseconds
  #expect(message["endAt"] as? Double == 4_070_908_800_000)
  let buttons = try #require(message["buttons"] as? [[String: Any]])
  #expect(buttons.map { $0["id"] as? String } == ["open", "later"])
  #expect(buttons[0]["deepLink"] as? String == "myapp://x")
  #expect(buttons[1]["deepLink"] == nil)
}

@Test @MainActor func aJSPresenterReceivesTheMessageAndReportsOutcomesByMessageId() async throws {
  let h = try await Harness.make()
  #expect(await call { h.bridge.addTrigger(key: "screen", value: "checkout", completion: $0) } == nil)
  #expect(await call { h.bridge.setInAppMessagePresenterEnabled(true, completion: $0) } == nil)

  await h.foreground()

  #expect(h.display.shown.isEmpty) // the native layout must not draw while JS presents
  let present = try #require(h.emitted.presents().first)
  #expect((present["message"] as? [String: Any])?["id"] as? String == "m1")
  #expect(present["triggers"] as? [String: String] == ["screen": "checkout"])

  #expect(await call { h.bridge.inAppImpression(messageId: "m1", completion: $0) } == nil)
  #expect(await call { h.bridge.inAppClicked(messageId: "m1", buttonId: "open", completion: $0) } == nil)
  await h.comraid.flushAcks()

  #expect(h.server.posts("/deliveries/d-m1/delivered").count == 1)
  let opened = try #require(h.server.posts("/deliveries/d-m1/opened").first)
  #expect((try JSONSerialization.jsonObject(with: #require(opened.body)) as! [String: Any])["action_id"] as? String == "open")
}

@Test @MainActor func aDismissalByMessageIdIsAcknowledgedAndTheHandleIsForgotten() async throws {
  let h = try await Harness.make()
  #expect(await call { h.bridge.setInAppMessagePresenterEnabled(true, completion: $0) } == nil)
  await h.foreground()

  #expect(await call { h.bridge.inAppImpression(messageId: "m1", completion: $0) } == nil)
  #expect(await call { h.bridge.inAppDismissed(messageId: "m1", completion: $0) } == nil)
  await h.comraid.flushAcks()
  #expect(h.server.posts("/deliveries/d-m1/dismissed").count == 1)

  // The handle is gone: a late call for the same id is a harmless no-op, not an error.
  #expect(await call { h.bridge.inAppClicked(messageId: "m1", buttonId: "open", completion: $0) } == nil)
  await h.comraid.flushAcks()
  #expect(h.server.posts("/deliveries/d-m1/opened").isEmpty)
}

@Test @MainActor func outcomesForAnUnknownMessageIdAreIgnored() async throws {
  let h = try await Harness.make()

  #expect(await call { h.bridge.inAppImpression(messageId: "nope", completion: $0) } == nil)
  #expect(await call { h.bridge.inAppClicked(messageId: "nope", buttonId: "x", completion: $0) } == nil)
  #expect(await call { h.bridge.inAppDismissed(messageId: "nope", completion: $0) } == nil)
}

@Test @MainActor func disablingTheJSPresenterReturnsToTheNativeLayouts() async throws {
  let h = try await Harness.make()
  #expect(await call { h.bridge.setInAppMessagePresenterEnabled(true, completion: $0) } == nil)
  #expect(await call { h.bridge.setInAppMessagePresenterEnabled(false, completion: $0) } == nil)

  await h.foreground()

  #expect(h.emitted.presents().isEmpty)
  #expect(h.display.shown.map(\.id) == ["m1"])
}
