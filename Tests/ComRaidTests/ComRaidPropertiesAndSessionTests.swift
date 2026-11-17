import Foundation
import Testing
@testable import ComRaid

@Test func registerSendsAutoCollectedPropertiesWithoutAppCall() async throws {
  let harness = try await PropertiesHarness.make()
  harness.transport.nextResponse = HttpResponse(
    statusCode: 201,
    body: Data(#"{"subscription_id":"sub-new","subscription_credential":"cred-new","channel":"push","anonymous":true,"platform":"ios","provider":"apns"}"#.utf8)
  )

  try await harness.comraid.register()

  let body = try JSONSerialization.jsonObject(with: #require(harness.transport.requests.single().body)) as! [String: Any]
  #expect(body["app_version"] as? String == "9.9.9")
  #expect(body["sdk_version"] as? String == "0.1.0")
  #expect(body["locale"] as? String == "en-US")
  #expect(body["timezone"] as? String == "America/New_York")
  #expect(body["language"] as? String == "en")
  #expect(body["country"] as? String == "US")
  let device = body["device"] as! [String: Any]
  #expect(device["os"] as? String == "iOS")
  #expect(device["os_version"] as? String == "18.0")
  #expect(device["model"] as? String == "iPhone16,1")
}

@Test func setDevicePropertiesOverridesAutoCollectedFields() async throws {
  let harness = try await PropertiesHarness.make()
  await harness.comraid.setDeviceProperties(
    DeviceProperties(
      appVersion: "2.1.0",
      model: "Custom Model",
      extras: ["manufacturer": "Apple"]
    )
  )
  harness.transport.nextResponse = HttpResponse(
    statusCode: 201,
    body: Data(#"{"subscription_id":"sub-new","subscription_credential":"cred-new","channel":"push","anonymous":true,"platform":"ios","provider":"apns"}"#.utf8)
  )

  try await harness.comraid.register()

  let body = try JSONSerialization.jsonObject(with: #require(harness.transport.requests.single().body)) as! [String: Any]
  #expect(body["app_version"] as? String == "2.1.0")
  #expect(body["sdk_version"] as? String == "0.1.0")
  #expect(body["locale"] as? String == "en-US")
  let device = body["device"] as! [String: Any]
  #expect(device["model"] as? String == "Custom Model")
  #expect(device["os_version"] as? String == "18.0")
  #expect(device["manufacturer"] as? String == "Apple")
}

@Test func foregroundAfterDebouncePostsSessionWithProperties() async throws {
  let harness = try await PropertiesHarness.make()
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")
  harness.transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"subscription_id":"sub-1","session_count":2,"last_seen_at":"2026-01-01T00:00:00Z"}"#.utf8)
  )

  await harness.comraid.handleAppBackgroundForTests()
  harness.clock.now += 30 * 60 + 1
  await harness.comraid.handleAppForegroundForTests()

  let request = harness.transport.requests.single()
  #expect(request.method == "POST")
  #expect(request.path == "/mobile/subscriptions/sub-1/session")
  let body = try JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
  #expect(body["subscription_credential"] as? String == "cred-1")
  #expect(body["app_version"] as? String == "9.9.9")
  #expect(body["sdk_version"] as? String == "0.1.0")
  #expect(body["timezone"] as? String == "America/New_York")
  #expect((body["device"] as! [String: Any])["model"] as? String == "iPhone16,1")
}

@Test func foregroundWithinDebounceSkipsSession() async throws {
  let harness = try await PropertiesHarness.make()
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")

  await harness.comraid.handleAppBackgroundForTests()
  harness.clock.now += 5 * 60
  await harness.comraid.handleAppForegroundForTests()

  #expect(harness.transport.requests.isEmpty)
}

@Test func registerThenImmediateForegroundSkipsSession() async throws {
  let harness = try await PropertiesHarness.make()
  harness.transport.nextResponse = HttpResponse(
    statusCode: 201,
    body: Data(#"{"subscription_id":"sub-new","subscription_credential":"cred-new","channel":"push","anonymous":true,"platform":"ios","provider":"apns"}"#.utf8)
  )
  try await harness.comraid.register()
  harness.transport.clearRequests()

  await harness.comraid.handleAppForegroundForTests()

  #expect(harness.transport.requests.isEmpty)
}

@Test func coldStartWithExistingSubscriptionPostsSession() async throws {
  let harness = try await PropertiesHarness.make()
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")
  harness.transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"subscription_id":"sub-1","session_count":3,"last_seen_at":"2026-01-01T00:00:00Z"}"#.utf8)
  )

  await harness.comraid.handleAppForegroundForTests()

  #expect(harness.transport.requests.single().path == "/mobile/subscriptions/sub-1/session")
}

@Test func repeatedForegroundWithoutBackgroundSkipsUntilSessionDebounce() async throws {
  let harness = try await PropertiesHarness.make()
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")
  harness.transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"subscription_id":"sub-1","session_count":3,"last_seen_at":"2026-01-01T00:00:00Z"}"#.utf8)
  )

  await harness.comraid.handleAppForegroundForTests()
  #expect(harness.transport.requests.count == 1)
  harness.transport.clearRequests()

  harness.clock.now += 5 * 60
  await harness.comraid.handleAppForegroundForTests()
  #expect(harness.transport.requests.isEmpty)

  harness.clock.now += 25 * 60 + 1
  await harness.comraid.handleAppForegroundForTests()
  #expect(harness.transport.requests.single().path == "/mobile/subscriptions/sub-1/session")
}

@Test func sessionTrackerDebouncesFromLastSessionWhenBackgroundMissing() {
  let clock = TestClock()
  var tracker = SessionTracker(debounce: 30 * 60, clock: { clock.now })

  #expect(tracker.shouldRecordSession())
  tracker.markSessionRecorded()

  clock.now += 5 * 60
  #expect(!tracker.shouldRecordSession())

  clock.now += 25 * 60 + 1
  #expect(tracker.shouldRecordSession())
}

@Test func sessionTrackerConsumesBackgroundAfterRecord() {
  let clock = TestClock()
  var tracker = SessionTracker(debounce: 30 * 60, clock: { clock.now })
  tracker.markSessionRecorded()
  tracker.onBackground()
  clock.now += 30 * 60 + 1
  #expect(tracker.shouldRecordSession())
  tracker.markSessionRecorded()

  clock.now += 5 * 60
  #expect(!tracker.shouldRecordSession())
}

private final class TestClock: @unchecked Sendable {
  var now: TimeInterval = 1_000_000
}

private struct PropertiesHarness {
  let comraid: ComRaid
  let transport: PropertiesRecordingTransport
  let store: InMemorySubscriptionStore
  let clock: TestClock

  static func make() async throws -> PropertiesHarness {
    let comraid = ComRaid()
    let transport = PropertiesRecordingTransport()
    let store = InMemorySubscriptionStore()
    let tokens = PropertiesFakeTokenProvider(token: "apns-token-1")
    let clock = TestClock()
    let auto = DeviceProperties(
      appVersion: "9.9.9",
      sdkVersion: "0.1.0",
      model: "iPhone16,1",
      os: "iOS",
      osVersion: "18.0",
      locale: "en-US",
      timezone: "America/New_York",
      language: "en",
      country: "US"
    )
    try await comraid.configureForTests(
      .init(appId: "cr_app_test", apnsEnvironment: .sandbox),
      transport: transport,
      tokenProvider: tokens,
      subscriptionStore: store,
      deviceInfoProvider: { auto },
      clock: { clock.now }
    )
    return PropertiesHarness(comraid: comraid, transport: transport, store: store, clock: clock)
  }
}

private final class PropertiesRecordingTransport: HttpTransport, @unchecked Sendable {
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

private struct PropertiesFakeTokenProvider: TokenProvider {
  let token: String
  func currentToken() async throws -> String { token }
}

private extension Array {
  func single() -> Element {
    precondition(count == 1)
    return self[0]
  }
}
