import Foundation
import Testing
@testable import ComRaid

/// Seam: the Objective-C bridge (`ComraidBridge`) that React Native's iOS module calls to list and
/// end the Live activities the SDK is tracking. Driven through the real SDK with a fake handle.

private final class IdleHandle: LiveActivityHandle, @unchecked Sendable {
  private let lock = NSLock()
  private var _ended = 0
  var ended: Int { lock.withLock { _ended } }
  func tokenUpdates() -> AsyncStream<Data> { AsyncStream { _ in } }
  func stateUpdates() -> AsyncStream<LiveActivityState> { AsyncStream { _ in } }
  func end() async { lock.withLock { _ended += 1 } }
}

private struct NoopTransport: HttpTransport {
  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    HttpResponse(statusCode: 200, body: Data("{}".utf8))
  }
}

private struct StubTokenProvider: TokenProvider {
  func currentToken() async throws -> String { "apns-token" }
}

private func configured() async throws {
  await ComRaid.shared.resetForTests()
  let store = InMemorySubscriptionStore()
  store.save(subscriptionId: "sub-1", credential: "cred-1")
  try await ComRaid.shared.configureForTests(
    .init(appId: "cr_app_test", apnsEnvironment: .sandbox),
    transport: NoopTransport(),
    tokenProvider: StubTokenProvider(),
    subscriptionStore: store
  )
}

@Test func theBridgeListsTheTrackedActivities() async throws {
  try await configured()
  await ComRaid.shared.track(handle: IdleHandle(), id: "order_2", type: "delivery")
  await ComRaid.shared.track(handle: IdleHandle(), id: "order_1", type: "delivery")

  let listed = await withCheckedContinuation { (c: CheckedContinuation<[[String: String]], Never>) in
    ComRaidObjCBridge.shared.listActivities { value, _ in
      c.resume(returning: (value as? [[String: String]]) ?? [])
    }
  }

  #expect(listed == [["id": "order_1", "type": "delivery"], ["id": "order_2", "type": "delivery"]])
}

@Test func theBridgeEndsATrackedActivityAndSaysSoForAnUnknownOne() async throws {
  try await configured()
  let handle = IdleHandle()
  await ComRaid.shared.track(handle: handle, id: "order_1", type: "delivery")

  func end(_ id: String) async -> Bool {
    await withCheckedContinuation { c in
      ComRaidObjCBridge.shared.endActivity(id: id) { ok, _ in c.resume(returning: ok) }
    }
  }

  #expect(await end("order_1"))
  #expect(handle.ended == 1)
  #expect(await end("nope") == false)
}
