import Foundation

struct MobileApiClient: Sendable {
  let appId: String
  let apnsEnvironment: APNsEnvironment
  let transport: any HttpTransport

  func register(
    token: String,
    properties: DeviceProperties?,
    subscriptionCredential: String? = nil
  ) async throws -> (subscriptionId: String, credential: String?) {
    var payload: [String: Any] = [
      "platform": "ios",
      "token": token,
      "provider": "apns",
      "apns_environment": apnsEnvironment.rawValue,
    ]
    if let subscriptionCredential, !subscriptionCredential.isEmpty {
      payload["subscription_credential"] = subscriptionCredential
    }
    putDeviceFields(&payload, properties)
    let response = try await post(path: "/mobile/subscriptions", payload: payload)
    try requireSuccess(response, expected: [200, 201])
    let json = try jsonObject(response.body)
    let subscriptionId = try string(json, "subscription_id")
    let credential = json["subscription_credential"] as? String
    return (subscriptionId, credential)
  }

  func replaceToken(
    subscriptionId: String,
    credential: String,
    token: String,
    properties: DeviceProperties?
  ) async throws {
    var payload: [String: Any] = [
      "token": token,
      "platform": "ios",
      "provider": "apns",
      "apns_environment": apnsEnvironment.rawValue,
      "subscription_credential": credential,
    ]
    putDeviceFields(&payload, properties)
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

  func upsertAttributes(subscriptionId: String, credential: String, attributes: [String: Any]) async throws {
    let response = try await put(
      path: "/mobile/subscriptions/\(subscriptionId)/attributes",
      payload: [
        "subscription_credential": credential,
        "attributes": attributes,
      ]
    )
    try requireSuccess(response, expected: [200])
  }

  /// Register or rotate Apple's update token for a Live activity
  /// (`PUT /mobile/subscriptions/{id}/activities/{activity_id}/token`).
  func registerActivityToken(
    subscriptionId: String,
    credential: String,
    activityId: String,
    activityType: String,
    updateToken: String
  ) async throws {
    let response = try await put(
      path: activityPath(subscriptionId: subscriptionId, activityId: activityId, suffix: "token"),
      payload: [
        "subscription_credential": credential,
        "activity_type": activityType,
        "update_token": updateToken,
      ]
    )
    try requireActivitySuccess(response, expected: [200], notFoundIsFinal: false)
  }

  /// Report a Live activity is over on this device
  /// (`POST /mobile/subscriptions/{id}/activities/{activity_id}/ended`).
  func reportActivityEnded(
    subscriptionId: String,
    credential: String,
    activityId: String,
    reason: String
  ) async throws {
    let response = try await post(
      path: activityPath(subscriptionId: subscriptionId, activityId: activityId, suffix: "ended"),
      payload: ["subscription_credential": credential, "reason": reason]
    )
    try requireActivitySuccess(response, expected: [204], notFoundIsFinal: true)
  }

  private func activityPath(subscriptionId: String, activityId: String, suffix: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    let id = activityId.addingPercentEncoding(withAllowedCharacters: allowed) ?? activityId
    return "/mobile/subscriptions/\(subscriptionId)/activities/\(id)/\(suffix)"
  }

  /// Like `requireSuccess`, but sorts a failure by what to do about it: never retry (`rejected`),
  /// keep it for later without retrying now (`refused`, a credential or Subscription problem that
  /// login or register may fix), or retry (`failed`).
  private func requireActivitySuccess(_ response: HttpResponse, expected: Set<Int>, notFoundIsFinal: Bool) throws {
    if expected.contains(response.statusCode) { return }
    let status = response.statusCode
    switch status {
    case 400, 409, 410, 422:
      throw ActivityRequestError.rejected(status)
    case 404:
      // On a token request, 404 means the Subscription is unknown, which a fresh register can fix.
      throw notFoundIsFinal ? ActivityRequestError.rejected(status) : ActivityRequestError.refused(status)
    case 401, 403:
      throw ActivityRequestError.refused(status)
    default:
      throw ActivityRequestError.failed(status)
    }
  }

  func session(
    subscriptionId: String,
    credential: String,
    properties: DeviceProperties?
  ) async throws {
    var payload: [String: Any] = ["subscription_credential": credential]
    putDeviceFields(&payload, properties)
    let response = try await post(path: "/mobile/subscriptions/\(subscriptionId)/session", payload: payload)
    try requireSuccess(response, expected: [200])
  }

  private func putDeviceFields(_ payload: inout [String: Any], _ properties: DeviceProperties?) {
    guard let properties else { return }
    if let appVersion = properties.appVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
       !appVersion.isEmpty {
      payload["app_version"] = appVersion
    }
    if let sdkVersion = properties.sdkVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
       !sdkVersion.isEmpty {
      payload["sdk_version"] = sdkVersion
    }
    if let locale = properties.locale?.trimmingCharacters(in: .whitespacesAndNewlines), !locale.isEmpty {
      payload["locale"] = locale
    }
    if let timezone = properties.timezone?.trimmingCharacters(in: .whitespacesAndNewlines), !timezone.isEmpty {
      payload["timezone"] = timezone
    }
    if let language = properties.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
      payload["language"] = language
    }
    if let country = properties.country?.trimmingCharacters(in: .whitespacesAndNewlines), !country.isEmpty {
      payload["country"] = country
    }
    var device: [String: Any] = [:]
    if let os = properties.os?.trimmingCharacters(in: .whitespacesAndNewlines), !os.isEmpty {
      device["os"] = os
    }
    if let model = properties.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
      device["model"] = model
    }
    if let osVersion = properties.osVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !osVersion.isEmpty {
      device["os_version"] = osVersion
    }
    for (key, value) in properties.extras {
      device[key] = value
    }
    if !device.isEmpty {
      payload["device"] = device
    }
  }

  /// In-app messages this install may show now (GET /mobile/subscriptions/{id}/in-app-messages).
  /// The server decides eligibility (Segment, window, opt-out, already seen). The Subscription
  /// credential travels in a header because this is a GET.
  func listInAppMessages(subscriptionId: String, credential: String) async throws -> [FetchedInAppMessage] {
    let response = try await transport.execute(
      HttpRequest(
        method: "GET",
        path: "/mobile/subscriptions/\(subscriptionId)/in-app-messages",
        headers: [
          "X-ComRaid-App-Id": appId,
          "X-ComRaid-Subscription-Credential": credential,
        ],
        body: nil
      )
    )
    try requireSuccess(response, expected: [200])
    return parseInAppMessages(try jsonObject(response.body)["messages"])
  }

  private func post(path: String, payload: [String: Any]) async throws -> HttpResponse {
    try await execute(method: "POST", path: path, payload: payload)
  }

  private func put(path: String, payload: [String: Any]) async throws -> HttpResponse {
    try await execute(method: "PUT", path: path, payload: payload)
  }

  private func execute(method: String, path: String, payload: [String: Any]) async throws -> HttpResponse {
    let body = try JSONSerialization.data(withJSONObject: payload)
    return try await transport.execute(
      HttpRequest(
        method: method,
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

/// Outcome of a Live activity request that did not succeed.
enum ActivityRequestError: Error, Equatable {
  /// The server refused it for good (for example 409 once the activity is over): retrying will not help.
  case rejected(Int)
  /// A credential, Contact or Subscription problem that login or register may fix: keep it pending
  /// and send it again on the next flush, but do not retry now.
  case refused(Int)
  /// A server or rate-limit error that may pass.
  case failed(Int)
}
