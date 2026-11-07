import Foundation
import Testing
@testable import ComRaid

@Suite(.serialized)
struct ComRaidListenerDispatchTests {
  @Test func foregroundReceiveFiresOnlyForegroundListenerOnce() async throws {
    let harness = try await ListenerHarness.make()
    let foreground = EventBox()
    let background = EventBox()
    let opened = EventBox()
    _ = await harness.comraid.addForegroundMessageListener { foreground.append($0) }
    _ = await harness.comraid.addBackgroundMessageListener { background.append($0) }
    _ = await harness.comraid.addNotificationOpenedListener { opened.append($0) }

    await harness.comraid.handleRemoteNotification(data: sampleData("d-fg"), appInForeground: true)

    #expect(foreground.events.count == 1)
    #expect(foreground.events[0].deliveryId == "d-fg")
    #expect(foreground.events[0].title == "Hello")
    #expect(background.events.isEmpty)
    #expect(opened.events.isEmpty)
  }

  @Test func backgroundReceiveFiresOnlyBackgroundListenerOnce() async throws {
    let harness = try await ListenerHarness.make()
    let foreground = EventBox()
    let background = EventBox()
    _ = await harness.comraid.addForegroundMessageListener { foreground.append($0) }
    _ = await harness.comraid.addBackgroundMessageListener { background.append($0) }

    await harness.comraid.handleRemoteNotification(data: sampleData("d-bg"), appInForeground: false)

    #expect(background.events.count == 1)
    #expect(background.events[0].deliveryId == "d-bg")
    #expect(foreground.events.isEmpty)
  }

  @Test func removeForegroundListenerStopsFurtherDelivery() async throws {
    let harness = try await ListenerHarness.make()
    let box = EventBox()
    let token = await harness.comraid.addForegroundMessageListener { box.append($0) }

    await harness.comraid.handleRemoteNotification(data: sampleData("d-1"), appInForeground: true)
    await harness.comraid.removeForegroundMessageListener(token)
    await harness.comraid.handleRemoteNotification(data: sampleData("d-2"), appInForeground: true)

    #expect(box.events.map(\.deliveryId) == ["d-1"])
  }

  @Test func removeBackgroundListenerStopsFurtherDelivery() async throws {
    let harness = try await ListenerHarness.make()
    let box = EventBox()
    let token = await harness.comraid.addBackgroundMessageListener { box.append($0) }

    await harness.comraid.handleRemoteNotification(data: sampleData("d-1"), appInForeground: false)
    await harness.comraid.removeBackgroundMessageListener(token)
    await harness.comraid.handleRemoteNotification(data: sampleData("d-2"), appInForeground: false)

    #expect(box.events.map(\.deliveryId) == ["d-1"])
  }

  @Test func openedListenerFiresOnceWithMappedEvent() async throws {
    let harness = try await ListenerHarness.make()
    let opened = EventBox()
    _ = await harness.comraid.addNotificationOpenedListener { opened.append($0) }

    await harness.comraid.handleNotificationOpen(data: sampleData("d-open"), actionId: "accept")

    #expect(opened.events.count == 1)
    #expect(opened.events[0].deliveryId == "d-open")
    #expect(opened.events[0].actionId == "accept")
    #expect(opened.events[0].title == "Hello")
  }

  @Test func removeOpenedListenerStopsFurtherDelivery() async throws {
    let harness = try await ListenerHarness.make()
    let opened = EventBox()
    let token = await harness.comraid.addNotificationOpenedListener { opened.append($0) }

    await harness.comraid.handleNotificationOpen(data: sampleData("d-1"), actionId: nil)
    await harness.comraid.removeNotificationOpenedListener(token)
    await harness.comraid.handleNotificationOpen(data: sampleData("d-2"), actionId: nil)

    #expect(opened.events.map(\.deliveryId) == ["d-1"])
  }
}

private func sampleData(_ deliveryId: String) -> [String: String] {
  [
    "cr_delivery_id": deliveryId,
    "cr_attribution_token": "tok-\(deliveryId)",
    "cr_title": "Hello",
    "cr_body": "World",
  ]
}

private struct ListenerHarness {
  let comraid: ComRaid
  let transport: RecordingTransport

  static func make() async throws -> ListenerHarness {
    let comraid = ComRaid()
    await comraid.resetForTests()
    let transport = RecordingTransport()
    transport.nextResponse = HttpResponse(statusCode: 200, body: Data(#"{"ok":true}"#.utf8))
    try await comraid.configureForTests(
      .init(appId: "cr_app_test", apnsEnvironment: .sandbox, storageSuiteName: "comraid.listener.\(UUID().uuidString)"),
      transport: transport,
      tokenProvider: FakeTokenProvider(token: "token"),
      subscriptionStore: InMemorySubscriptionStore()
    )
    return ListenerHarness(comraid: comraid, transport: transport)
  }
}

private final class EventBox: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var events: [RemoteMessageEvent] = []

  func append(_ event: RemoteMessageEvent) {
    lock.withLock { events.append(event) }
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
