import Foundation
import Testing
@testable import ComRaid

/// Seam: `MobileApiClient` fetching In-app messages (GET /in-app-messages) and the in_app opt-out.
private final class RecordingTransport: HttpTransport, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requests: [HttpRequest] = []
  let response: HttpResponse

  init(status: Int, body: String) {
    response = HttpResponse(statusCode: status, body: Data(body.utf8))
  }

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock { requests.append(request) }
    return response
  }
}

private let body = """
{"messages":[
  {"id":"m1","delivery_id":"d1","attribution_token":"tok1","layout":"modal","title":"Welcome","body":"Hi there",
   "image_url":"https://cdn.example.com/a.png",
   "buttons":[{"id":"open","label":"Open","deep_link":"myapp://new"},{"id":"later","label":"Later"}],
   "start_at":"2026-12-01T03:30:00.000Z","end_at":"2026-12-31T13:00:00Z"},
  {"id":"m2","test":true,"layout":"banner_top","title":"Test","body":"Only a test","buttons":[]},
  {"id":"m3","delivery_id":"d3","attribution_token":"t3","layout":"carousel","title":"Unknown layout","body":"x","buttons":[]},
  {"layout":"modal","title":"No id","body":"x","buttons":[]}
]}
"""

private func client(_ transport: RecordingTransport) -> MobileApiClient {
  MobileApiClient(appId: "cr_app_test", apnsEnvironment: .sandbox, transport: transport)
}

@Test func listInAppMessagesSendsAppIdAndCredentialAsAGet() async throws {
  let transport = RecordingTransport(status: 200, body: body)

  _ = try await client(transport).listInAppMessages(subscriptionId: "sub-1", credential: "cred-1")

  let request = try #require(transport.requests.first)
  #expect(transport.requests.count == 1)
  #expect(request.method == "GET")
  #expect(request.path == "/mobile/subscriptions/sub-1/in-app-messages")
  #expect(request.headers["X-ComRaid-App-Id"] == "cr_app_test")
  #expect(request.headers["X-ComRaid-Subscription-Credential"] == "cred-1")
  #expect(request.body == nil)
}

@Test func listInAppMessagesParsesARealMessageWithItsAckCredentials() async throws {
  let messages = try await client(RecordingTransport(status: 200, body: body))
    .listInAppMessages(subscriptionId: "sub-1", credential: "cred-1")

  let first = try #require(messages.first { $0.message.id == "m1" })
  #expect(first.deliveryId == "d1")
  #expect(first.attributionToken == "tok1")
  #expect(first.message.layout == .modal)
  #expect(first.message.title == "Welcome")
  #expect(first.message.body == "Hi there")
  #expect(first.message.imageURL == "https://cdn.example.com/a.png")
  #expect(first.message.isTest == false)
  #expect(first.message.buttons.map(\.id) == ["open", "later"])
  #expect(first.message.buttons[0].deepLink == "myapp://new")
  #expect(first.message.buttons[1].deepLink == nil)
  #expect(first.message.startAt == Date(timeIntervalSince1970: 1_796_095_800)) // 2026-12-01T03:30:00Z
  #expect(first.message.endAt == Date(timeIntervalSince1970: 1_798_722_000)) // 2026-12-31T13:00:00Z
}

@Test func listInAppMessagesMarksATestSendAndLeavesOutItsAckCredentials() async throws {
  let messages = try await client(RecordingTransport(status: 200, body: body))
    .listInAppMessages(subscriptionId: "sub-1", credential: "cred-1")

  let test = try #require(messages.first { $0.message.id == "m2" })
  #expect(test.message.isTest)
  #expect(test.deliveryId == nil)
  #expect(test.attributionToken == nil)
  #expect(test.message.layout == .bannerTop)
  #expect(test.message.startAt == nil)
  #expect(test.message.endAt == nil)
}

@Test func listInAppMessagesSkipsMessagesItCannotDraw() async throws {
  let ids = try await client(RecordingTransport(status: 200, body: body))
    .listInAppMessages(subscriptionId: "sub-1", credential: "cred-1")
    .map(\.message.id)

  #expect(ids == ["m1", "m2"]) // unknown layout and missing id are dropped
}

@Test func listInAppMessagesThrowsTheServerMessageOnFailure() async {
  let transport = RecordingTransport(
    status: 401,
    body: #"{"error":{"code":"unauthorized","message":"Invalid subscription credential"}}"#
  )

  await #expect(throws: ComRaidError.apiError("Invalid subscription credential")) {
    _ = try await client(transport).listInAppMessages(subscriptionId: "sub-1", credential: "bad")
  }
}

@Test func optOutForTheInAppChannelPostsThatChannel() async throws {
  let transport = RecordingTransport(status: 200, body: "{}")

  try await client(transport).optOut(subscriptionId: "sub-1", credential: "cred-1", channel: "in_app")

  let request = try #require(transport.requests.first)
  #expect(request.path == "/mobile/subscriptions/sub-1/opt-out")
  let json = try JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
  #expect(json["channel"] as? String == "in_app")
}

@Test func dismissedIsAnAckKindWithItsOwnWireName() {
  #expect(AckKind.dismissed.rawValue == "dismissed")
  #expect(AckKind.fromWire("dismissed") == .dismissed)
}
