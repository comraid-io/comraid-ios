import Foundation
import Testing
@testable import Comraid

@Test func registerIncludesDevicePropertiesAndAppVersion() async throws {
  let harness = try await RemoteHarness.make(token: "apns-token-1")
  await harness.comraid.setDeviceProperties(
    DeviceProperties(
      appVersion: "2.1.0",
      model: "iPhone16,1",
      osVersion: "18.0",
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
  let device = body["device"] as! [String: Any]
  #expect(device["model"] as? String == "iPhone16,1")
  #expect(device["os_version"] as? String == "18.0")
  #expect(device["manufacturer"] as? String == "Apple")
}

@Test func setAttributesPutsContactAttributesAfterLogin() async throws {
  let harness = try await RemoteHarness.make()
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")
  harness.transport.enqueue(
    HttpResponse(
      statusCode: 200,
      body: Data(#"{"subscription_id":"sub-1","contact_id":"c-1","external_user_id":"user_123","anonymous":false,"verified":false}"#.utf8)
    ),
    HttpResponse(
      statusCode: 200,
      body: Data(#"{"contact_id":"c-1","external_user_id":"user_123","updated_attributes":["plan"]}"#.utf8)
    )
  )

  try await harness.comraid.login(externalUserId: "user_123")
  try await harness.comraid.setAttributes(["plan": "premium", "tier": 2])

  let request = harness.transport.requests[1]
  #expect(request.method == "PUT")
  #expect(request.path == "/contacts/user_123/attributes")
  #expect(request.headers["X-ComRaid-App-Id"] == "cr_app_test")
  let attrs = (try JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any])["attributes"] as! [String: Any]
  #expect(attrs["plan"] as? String == "premium")
  #expect((attrs["tier"] as? NSNumber)?.intValue == 2)
}

@Test func acknowledgeDeliveredPostsViaAckQueueTransport() async throws {
  let harness = try await RemoteHarness.make()
  harness.transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"delivery_id":"d1","status":"delivered"}"#.utf8)
  )

  let ok = await harness.comraid.acknowledgeDelivered(deliveryId: "d1", attributionToken: "tok")

  #expect(ok)
  let request = try #require(harness.transport.requests.first)
  #expect(request.path == "/deliveries/d1/delivered")
  let body = try JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
  #expect(body["attribution_token"] as? String == "tok")
}

@Test func acknowledgeOpenedIncludesActionId() async throws {
  let harness = try await RemoteHarness.make()
  harness.transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"delivery_id":"d1","status":"opened"}"#.utf8)
  )

  let ok = await harness.comraid.acknowledgeOpened(
    deliveryId: "d1",
    attributionToken: "tok",
    actionId: "accept"
  )

  #expect(ok)
  let body = try JSONSerialization.jsonObject(with: #require(harness.transport.requests.first?.body)) as! [String: Any]
  #expect(body["action_id"] as? String == "accept")
  #expect(harness.transport.requests.first?.path == "/deliveries/d1/opened")
}

@Test func tokenRefreshPreservesSubscriptionIdAndSendsDeviceProperties() async throws {
  let harness = try await RemoteHarness.make(token: "apns-token-2")
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")
  await harness.comraid.setDeviceProperties(DeviceProperties(appVersion: "3.0.0", model: "iPhone"))
  harness.transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"subscription_id":"sub-1","anonymous":true,"platform":"ios","provider":"apns","verified":false,"token_version":2}"#.utf8)
  )

  try await harness.comraid.onPushTokenRefresh()

  #expect(harness.store.subscriptionId == "sub-1")
  #expect(harness.store.credential == "cred-1")
  let body = try JSONSerialization.jsonObject(with: #require(harness.transport.requests.first?.body)) as! [String: Any]
  #expect(body["app_version"] as? String == "3.0.0")
  #expect((body["device"] as? [String: Any])?["model"] as? String == "iPhone")
  #expect(body["subscription_id"] == nil)
}

@Test func remoteContentBuildsTitleBodyCategoryAndActions() {
  let data: [String: String] = [
    "cr_delivery_id": "d1",
    "cr_attribution_token": "tok",
    "cr_title": "Hello",
    "cr_body": "World",
    "cr_actions": #"[{"id":"accept","text":"Accept"}]"#,
  ]
  let content = RemoteNotificationDisplay.content(from: data)
  #expect(content.title == "Hello")
  #expect(content.body == "World")
  #expect(content.categoryIdentifier == "comraid.d1")
  #expect(content.userInfo["cr_delivery_id"] as? String == "d1")

  let categories = RemoteNotificationDisplay.categories(from: data)
  #expect(categories.count == 1)
  #expect(categories[0].identifier == "comraid.d1")
  #expect(categories[0].actions.count == 1)
  #expect(categories[0].actions[0].identifier == "accept")
  #expect(categories[0].actions[0].title == "Accept")
}

private struct RemoteHarness {
  let comraid: Comraid
  let transport: RecordingTransport
  let store: InMemorySubscriptionStore

  static func make(token: String = "token") async throws -> RemoteHarness {
    let comraid = Comraid()
    let transport = RecordingTransport()
    let store = InMemorySubscriptionStore()
    let tokens = FakeTokenProvider(token: token)
    await comraid.configureForTests(
      .init(appId: "cr_app_test", apnsEnvironment: .sandbox),
      transport: transport,
      tokenProvider: tokens,
      subscriptionStore: store
    )
    return RemoteHarness(comraid: comraid, transport: transport, store: store)
  }
}

private final class RecordingTransport: HttpTransport, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requests: [HttpRequest] = []
  var nextResponse: HttpResponse?
  private var queue: [HttpResponse] = []

  func enqueue(_ responses: HttpResponse...) {
    lock.withLock { queue = responses }
  }

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock {
      requests.append(request)
      if !queue.isEmpty {
        return queue.removeFirst()
      }
      guard let nextResponse else { fatalError("No response configured") }
      return nextResponse
    }
  }
}

private struct FakeTokenProvider: TokenProvider {
  let token: String
  func currentToken() async throws -> String { token }
}

private extension Array {
  func single() -> Element {
    precondition(count == 1)
    return self[0]
  }
}
