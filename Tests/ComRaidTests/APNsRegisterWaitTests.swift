import Foundation
import Testing
@testable import ComRaid

@Test func registerWaitsForTokenThatArrivesAfterCallAndRegistersOnce() async throws {
  let store = InMemorySubscriptionStore()
  let transport = WaitRecordingTransport()
  transport.nextResponse = HttpResponse(
    statusCode: 201,
    body: Data(#"{"subscription_id":"sub-wait","subscription_credential":"cred-wait","channel":"push","anonymous":true,"platform":"ios","provider":"apns"}"#.utf8)
  )
  let apns = StoredAPNsTokenProvider()
  let comraid = ComRaid()
  await comraid.configureForTests(
    .init(appId: "cr_app_test", apnsEnvironment: .sandbox),
    transport: transport,
    tokenProvider: apns,
    subscriptionStore: store
  )

  let registerTask = Task {
    try await comraid.register(tokenWaitTimeout: 2)
  }

  try await Task.sleep(nanoseconds: 50_000_000)
  #expect(transport.requests.isEmpty)

  await comraid.setAPNsDeviceToken(Data([0xAA, 0xBB]))
  try await registerTask.value

  #expect(transport.requests.count == 1)
  #expect(transport.requests.first?.path == "/mobile/subscriptions")
  let body = try JSONSerialization.jsonObject(with: #require(transport.requests.first?.body)) as! [String: Any]
  #expect(body["token"] as? String == "aabb")
  #expect(store.subscriptionId == "sub-wait")
  #expect(store.credential == "cred-wait")
}

@Test func registerThrowsTokenTimeoutWhenTokenNeverArrives() async throws {
  let store = InMemorySubscriptionStore()
  let transport = WaitRecordingTransport()
  let apns = StoredAPNsTokenProvider()
  let comraid = ComRaid()
  await comraid.configureForTests(
    .init(appId: "cr_app_test", apnsEnvironment: .sandbox),
    transport: transport,
    tokenProvider: apns,
    subscriptionStore: store
  )

  await #expect(throws: ComRaidError.tokenTimeout) {
    try await comraid.register(tokenWaitTimeout: 0.05)
  }
  #expect(transport.requests.isEmpty)
  #expect(store.subscriptionId == nil)
}

@Test func tokenAfterTimeoutStillRegistersAutomatically() async throws {
  let store = InMemorySubscriptionStore()
  let transport = WaitRecordingTransport()
  transport.nextResponse = HttpResponse(
    statusCode: 201,
    body: Data(#"{"subscription_id":"sub-late","subscription_credential":"cred-late","channel":"push","anonymous":true,"platform":"ios","provider":"apns"}"#.utf8)
  )
  let apns = StoredAPNsTokenProvider()
  let comraid = ComRaid()
  await comraid.configureForTests(
    .init(appId: "cr_app_test", apnsEnvironment: .sandbox),
    transport: transport,
    tokenProvider: apns,
    subscriptionStore: store
  )

  await #expect(throws: ComRaidError.tokenTimeout) {
    try await comraid.register(tokenWaitTimeout: 0.05)
  }
  #expect(transport.requests.isEmpty)

  await comraid.setAPNsDeviceToken(Data([0x11, 0x22]))

  // Auto-register is async after token arrival.
  for _ in 0..<40 {
    if transport.requests.count == 1 { break }
    try await Task.sleep(nanoseconds: 25_000_000)
  }

  #expect(transport.requests.count == 1)
  #expect(transport.requests.first?.path == "/mobile/subscriptions")
  let body = try JSONSerialization.jsonObject(with: #require(transport.requests.first?.body)) as! [String: Any]
  #expect(body["token"] as? String == "1122")
  #expect(store.subscriptionId == "sub-late")
  #expect(store.credential == "cred-late")
}

@Test func tokenTimeoutBridgesAsStableNSErrorDomain() {
  let error = ComRaidError.tokenTimeout.asNSError()
  #expect(error.domain == "tokenTimeout")
}

private final class WaitRecordingTransport: HttpTransport, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requests: [HttpRequest] = []
  var nextResponse: HttpResponse?

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock {
      requests.append(request)
      guard let nextResponse else {
        fatalError("No response configured")
      }
      return nextResponse
    }
  }
}
