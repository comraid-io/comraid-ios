import Foundation
import Testing
import UserNotifications
@testable import ComRaid

@Suite(.serialized)
struct NseDeliveredAckTests {
  @Test func backgroundHelpersWithCustomSuiteFindConfigAndFlushDelivered() async throws {
    let suiteName = "comraid.test.nse-ack.\(UUID().uuidString)"
    defer { clearSuite(suiteName) }

    let configStore = SdkConfigStore(suiteName: suiteName)
    configStore.save(
      ComRaidConfiguration(
        appId: "cr_app_nse",
        apiBaseURL: URL(string: "https://api.test.comraid.io")!,
        apnsEnvironment: .sandbox,
        storageSuiteName: suiteName
      )
    )

    let ackStore = InMemoryAckQueueStore()
    let transport = RecordingTransport()
    transport.nextResponse = HttpResponse(
      statusCode: 200,
      body: Data(#"{"delivery_id":"d-nse","status":"delivered"}"#.utf8)
    )

    let data: [String: String] = [
      "cr_delivery_id": "d-nse",
      "cr_attribution_token": "tok-nse",
      "cr_title": "Hello",
    ]

    await BackgroundAckHelpers.acknowledgeDelivered(
      data: data,
      storageSuiteName: suiteName,
      configStore: configStore,
      ackStore: ackStore,
      transport: transport
    )

    let request = try #require(transport.requests.first)
    #expect(request.path == "/deliveries/d-nse/delivered")
    let body = try JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
    #expect(body["attribution_token"] as? String == "tok-nse")
    #expect(ackStore.get("comraid:https://api.test.comraid.io:ack-queue") == "[]")
  }

  @Test func backgroundHelpersWithoutMatchingSuiteFindNoConfig() async {
    let suiteName = "comraid.test.nse-missing.\(UUID().uuidString)"
    defer { clearSuite(suiteName) }

    SdkConfigStore(suiteName: suiteName).save(
      ComRaidConfiguration(
        appId: "cr_app_hidden",
        apnsEnvironment: .sandbox,
        storageSuiteName: suiteName
      )
    )

    let queue = BackgroundAckHelpers.makeQueue()
    #expect(queue == nil)
  }

  @Test func enrichEnqueuesDeliveredAckThroughSharedSuite() async throws {
    let suiteName = "comraid.test.nse-enrich.\(UUID().uuidString)"
    defer { clearSuite(suiteName) }

    let configStore = SdkConfigStore(suiteName: suiteName)
    configStore.save(
      ComRaidConfiguration(
        appId: "cr_app_enrich",
        apiBaseURL: URL(string: "https://api.test.comraid.io")!,
        apnsEnvironment: .sandbox,
        storageSuiteName: suiteName
      )
    )

    let ackStore = InMemoryAckQueueStore()
    let transport = RecordingTransport()
    transport.nextResponse = HttpResponse(
      statusCode: 503,
      body: Data()
    )

    let content = UNMutableNotificationContent()
    content.title = "Title"
    content.body = "Body"
    content.userInfo = [
      "cr_delivery_id": "d-enrich",
      "cr_attribution_token": "tok-enrich",
      "cr_title": "Title",
      "cr_body": "Body",
    ]
    let request = UNNotificationRequest(identifier: "nse-enrich", content: content, trigger: nil)

    _ = await RemoteNotificationDisplay.enrich(
      request,
      storageSuiteName: suiteName,
      configStore: configStore,
      ackStore: ackStore,
      transport: transport
    )

    // Flush failed (503) → ACK stays queued for retry.
    let raw = try #require(ackStore.get("comraid:https://api.test.comraid.io:ack-queue"))
    let items = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [[String: Any]]
    #expect(items.count == 1)
    #expect(items[0]["deliveryId"] as? String == "d-enrich")
    #expect(items[0]["kind"] as? String == "delivered")
    #expect(transport.requests.count == 1)
    #expect(transport.requests[0].path == "/deliveries/d-enrich/delivered")
  }
}

private func clearSuite(_ suiteName: String) {
  guard let defaults = UserDefaults(suiteName: suiteName) else { return }
  defaults.dictionaryRepresentation().keys.forEach(defaults.removeObject(forKey:))
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

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock {
      requests.append(request)
      guard let nextResponse else { fatalError("No response configured") }
      return nextResponse
    }
  }
}
