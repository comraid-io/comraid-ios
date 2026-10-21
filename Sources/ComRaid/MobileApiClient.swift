import Foundation

struct MobileApiClient: Sendable {
  let appId: String
  let apnsEnvironment: APNsEnvironment
  let transport: any HttpTransport

  func register(token: String) async throws -> (subscriptionId: String, credential: String?) {
    let payload: [String: Any] = [
      "platform": "ios",
      "token": token,
      "provider": "apns",
      "apns_environment": apnsEnvironment.rawValue,
    ]
    let response = try await post(path: "/mobile/subscriptions", payload: payload)
    try requireSuccess(response, expected: [200, 201])
    let json = try jsonObject(response.body)
    let subscriptionId = try string(json, "subscription_id")
    let credential = json["subscription_credential"] as? String
    return (subscriptionId, credential)
  }

  func replaceToken(subscriptionId: String, credential: String, token: String) async throws {
    let payload: [String: Any] = [
      "token": token,
      "platform": "ios",
      "provider": "apns",
      "apns_environment": apnsEnvironment.rawValue,
      "subscription_credential": credential,
    ]
    let response = try await post(path: "/mobile/subscriptions/\(subscriptionId)/token", payload: payload)
    try requireSuccess(response, expected: [200])
  }

  func login(
    subscriptionId: String,
    credential: String,
    externalUserId: String,
    jwt: String?
  ) async throws {
    var payload: [String: Any] = [
      "external_user_id": externalUserId,
      "subscription_credential": credential,
    ]
    if let jwt {
      payload["jwt"] = jwt
    }
    let response = try await post(path: "/mobile/subscriptions/\(subscriptionId)/login", payload: payload)
    try requireSuccess(response, expected: [200])
  }

  func logout(subscriptionId: String, credential: String) async throws {
    let payload: [String: Any] = ["subscription_credential": credential]
    let response = try await post(path: "/mobile/subscriptions/\(subscriptionId)/logout", payload: payload)
    try requireSuccess(response, expected: [200])
  }

  func optOut(subscriptionId: String, credential: String, channel: String) async throws {
    let payload: [String: Any] = [
      "subscription_credential": credential,
      "channel": channel,
    ]
    let response = try await post(path: "/mobile/subscriptions/\(subscriptionId)/opt-out", payload: payload)
    try requireSuccess(response, expected: [200])
  }

  func optIn(subscriptionId: String, credential: String, channel: String) async throws {
    let payload: [String: Any] = [
      "subscription_credential": credential,
      "channel": channel,
    ]
    let response = try await post(path: "/mobile/subscriptions/\(subscriptionId)/opt-in", payload: payload)
    try requireSuccess(response, expected: [200])
  }

  private func post(path: String, payload: [String: Any]) async throws -> HttpResponse {
    let body = try JSONSerialization.data(withJSONObject: payload)
    return try await transport.execute(
      HttpRequest(
        method: "POST",
        path: path,
        headers: ["X-ComRaid-App-Id": appId],
        body: body
      )
    )
  }

  private func requireSuccess(_ response: HttpResponse, expected: Set<Int>) throws {
    guard expected.contains(response.statusCode) else {
      let message = (try? jsonObject(response.body))
        .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
        ?? "HTTP \(response.statusCode)"
      throw ComRaidError.apiError(message)
    }
  }

  private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ComRaidError.apiError("Invalid JSON response")
    }
    return object
  }

  private func string(_ json: [String: Any], _ key: String) throws -> String {
    guard let value = json[key] as? String, !value.isEmpty else {
      throw ComRaidError.apiError("Missing \(key) in response")
    }
    return value
  }
}
