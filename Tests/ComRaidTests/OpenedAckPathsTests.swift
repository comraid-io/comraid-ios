import Foundation
import Testing
@testable import ComRaid

@Suite(.serialized)
struct OpenedAckPathsTests {
  @Test func coldStartBodyTapPostsOpenedAckAndStashesInitialNotification() async throws {
    let harness = try await OpenedAckHarness.make()
    harness.transport.nextResponse = HttpResponse(
      statusCode: 200,
      body: Data(#"{"delivery_id":"d-cold","status":"opened"}"#.utf8)
    )
    let data: [String: String] = [
      "cr_delivery_id": "d-cold",
      "cr_attribution_token": "tok-cold",
      "cr_title": "Hello",
      "cr_body": "World",
    ]

    await harness.comraid.handleNotificationOpen(data: data, actionId: nil)

    let initial = await harness.comraid.getInitialNotification()
    #expect(initial?.deliveryId == "d-cold")
    #expect(initial?.actionId == nil)
    #expect(await harness.comraid.getInitialNotification() == nil)

    let request = try #require(harness.transport.requests.first)
    #expect(request.path == "/deliveries/d-cold/opened")
    let body = try JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
    #expect(body["attribution_token"] as? String == "tok-cold")
    #expect(body["action_id"] == nil)
  }

  @Test func actionButtonTapPostsOpenedAckWithActionId() async throws {
    let harness = try await OpenedAckHarness.make()
    harness.transport.nextResponse = HttpResponse(
      statusCode: 200,
      body: Data(#"{"delivery_id":"d-act","status":"opened"}"#.utf8)
    )
    let data: [String: String] = [
      "cr_delivery_id": "d-act",
      "cr_attribution_token": "tok-act",
      "cr_title": "Rematch?",
    ]

    await harness.comraid.handleNotificationOpen(data: data, actionId: "accept")

    let request = try #require(harness.transport.requests.first)
    #expect(request.path == "/deliveries/d-act/opened")
    let body = try JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
    #expect(body["action_id"] as? String == "accept")
    #expect(body["attribution_token"] as? String == "tok-act")
  }
}

private struct OpenedAckHarness {
  let comraid: ComRaid
  let transport: RecordingTransport

  static func make() async throws -> OpenedAckHarness {
    let comraid = ComRaid()
    await comraid.resetForTests()
    let transport = RecordingTransport()
    try await comraid.configureForTests(
      .init(appId: "cr_app_test", apnsEnvironment: .sandbox),
      transport: transport,
      tokenProvider: FakeTokenProvider(token: "token"),
      subscriptionStore: InMemorySubscriptionStore()
    )
    return OpenedAckHarness(comraid: comraid, transport: transport)
  }
}

private final class RecordingTransport: HttpTransport, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requests: [HttpRequest] = []
  var nextResponse: HttpResponse?

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock {
      requests.append(request)
      guard let nextResponse else { fatalError("No response configured") }
      return nextResponse
    }
  }
}

private struct FakeTokenProvider: TokenProvider {
  let token: String
  func currentToken() async throws -> String { token }
}
