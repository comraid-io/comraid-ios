import Foundation
import Testing
@testable import Comraid

@Test func loginSendsExternalUserIdOnWire() async throws {
  let harness = try await IdentityHarness.make()
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")
  harness.transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"subscription_id":"sub-1","contact_id":"c-1","external_user_id":"user_123","anonymous":false,"verified":false}"#.utf8)
  )

  try await harness.comraid.login(externalUserId: "user_123")

  let request = try #require(harness.transport.requests.first)
  #expect(request.method == "POST")
  #expect(request.path == "/mobile/subscriptions/sub-1/login")
  #expect(request.headers["X-ComRaid-App-Id"] == "cr_app_test")
  let body = try JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
  #expect(body["external_user_id"] as? String == "user_123")
  #expect(body["subscription_credential"] as? String == "cred-1")
  #expect(body["external_id"] == nil)
}

@Test func loginIncludesOptionalJWT() async throws {
  let harness = try await IdentityHarness.make()
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")
  harness.transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"subscription_id":"sub-1","contact_id":"c-1","external_user_id":"user_123","anonymous":false,"verified":true}"#.utf8)
  )

  try await harness.comraid.login(externalUserId: "user_123", jwt: "jwt-from-backend")

  let body = try JSONSerialization.jsonObject(with: #require(harness.transport.requests.first?.body)) as! [String: Any]
  #expect(body["jwt"] as? String == "jwt-from-backend")
}

@Test func logoutPostsAndKeepsCredential() async throws {
  let harness = try await IdentityHarness.make()
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")
  harness.transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"subscription_id":"sub-1","active":false,"verified":false}"#.utf8)
  )

  try await harness.comraid.logout()

  #expect(harness.transport.requests.first?.path == "/mobile/subscriptions/sub-1/logout")
  #expect(harness.store.subscriptionId == "sub-1")
  #expect(harness.store.credential == "cred-1")
}

@Test func optOutPostsPushChannel() async throws {
  let harness = try await IdentityHarness.make()
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")
  harness.transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"subscription_id":"sub-1","contact_id":"c-1","channel":"push","opted_out":true}"#.utf8)
  )

  try await harness.comraid.optOut()

  let body = try JSONSerialization.jsonObject(with: #require(harness.transport.requests.first?.body)) as! [String: Any]
  #expect(harness.transport.requests.first?.path == "/mobile/subscriptions/sub-1/opt-out")
  #expect(body["channel"] as? String == "push")
}

@Test func optInPostsPushChannel() async throws {
  let harness = try await IdentityHarness.make()
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")
  harness.transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"subscription_id":"sub-1","contact_id":"c-1","channel":"push","opted_out":false}"#.utf8)
  )

  try await harness.comraid.optIn()

  #expect(harness.transport.requests.first?.path == "/mobile/subscriptions/sub-1/opt-in")
}

@Test func optOutAfterLogoutUsesStoredCredential() async throws {
  let harness = try await IdentityHarness.make()
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")
  harness.transport.enqueue(
    HttpResponse(statusCode: 200, body: Data(#"{"subscription_id":"sub-1","active":false,"verified":false}"#.utf8)),
    HttpResponse(statusCode: 200, body: Data(#"{"subscription_id":"sub-1","contact_id":"c-1","channel":"push","opted_out":true}"#.utf8))
  )

  try await harness.comraid.logout()
  try await harness.comraid.optOut()

  #expect(harness.transport.requests.count == 2)
  #expect(harness.transport.requests[1].path == "/mobile/subscriptions/sub-1/opt-out")
  let body = try JSONSerialization.jsonObject(with: #require(harness.transport.requests[1].body)) as! [String: Any]
  #expect(body["subscription_credential"] as? String == "cred-1")
}

@Test func loginBeforeConfigureThrowsNotConfigured() async throws {
  let comraid = Comraid()
  await #expect(throws: ComraidError.notConfigured) {
    try await comraid.login(externalUserId: "user_123")
  }
}

@Test func loginBeforeSubscriptionReadyThrowsNotReady() async throws {
  let harness = try await IdentityHarness.make()
  await #expect(throws: ComraidError.notReady) {
    try await harness.comraid.login(externalUserId: "user_123")
  }
}

@Test func registerPostsIosPlatformAndStoresCredential() async throws {
  let harness = try await IdentityHarness.make(token: "apns-token-1")
  harness.transport.nextResponse = HttpResponse(
    statusCode: 201,
    body: Data(#"{"subscription_id":"sub-new","subscription_credential":"cred-new","channel":"push","anonymous":true,"platform":"ios","provider":"apns"}"#.utf8)
  )

  try await harness.comraid.register()

  let request = try #require(harness.transport.requests.first)
  #expect(request.path == "/mobile/subscriptions")
  let body = try JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
  #expect(body["platform"] as? String == "ios")
  #expect(body["token"] as? String == "apns-token-1")
  #expect(body["provider"] as? String == "apns")
  #expect(body["apns_environment"] as? String == "sandbox")
  #expect(harness.store.subscriptionId == "sub-new")
  #expect(harness.store.credential == "cred-new")
}

@Test func tokenRefreshWithCredentialCallsReplaceToken() async throws {
  let harness = try await IdentityHarness.make(token: "apns-token-2")
  harness.store.save(subscriptionId: "sub-1", credential: "cred-1")
  harness.transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"subscription_id":"sub-1","anonymous":true,"platform":"ios","provider":"apns","verified":false,"token_version":2}"#.utf8)
  )

  try await harness.comraid.onPushTokenRefresh()

  let request = try #require(harness.transport.requests.first)
  #expect(request.path == "/mobile/subscriptions/sub-1/token")
  let body = try JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
  #expect(body["token"] as? String == "apns-token-2")
  #expect(body["subscription_credential"] as? String == "cred-1")
}

@Test func tokenRefreshWithoutCredentialRegisters() async throws {
  let harness = try await IdentityHarness.make(token: "apns-token-3")
  harness.transport.nextResponse = HttpResponse(
    statusCode: 201,
    body: Data(#"{"subscription_id":"sub-3","subscription_credential":"cred-3","channel":"push","anonymous":true,"platform":"ios","provider":"apns"}"#.utf8)
  )

  try await harness.comraid.onPushTokenRefresh()

  #expect(harness.transport.requests.first?.path == "/mobile/subscriptions")
  #expect(harness.store.subscriptionId == "sub-3")
}

private struct IdentityHarness {
  let comraid: Comraid
  let transport: RecordingTransport
  let store: InMemorySubscriptionStore

  static func make(token: String = "token") async throws -> IdentityHarness {
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
    return IdentityHarness(comraid: comraid, transport: transport, store: store)
  }
}

private final class RecordingTransport: HttpTransport, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requests: [HttpRequest] = []
  var nextResponse: HttpResponse?
  private var queue: [HttpResponse] = []

  func enqueue(_ responses: HttpResponse...) {
    lock.withLock {
      queue = responses
    }
  }

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock {
      requests.append(request)
      if !queue.isEmpty {
        return queue.removeFirst()
      }
      guard let nextResponse else {
        fatalError("No response configured")
      }
      return nextResponse
    }
  }
}

private struct FakeTokenProvider: TokenProvider {
  let token: String
  func currentToken() async throws -> String { token }
}
