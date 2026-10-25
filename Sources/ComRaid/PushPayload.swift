import Foundation

struct DeliveryAttribution: Equatable, Sendable {
  var deliveryId: String
  var attributionToken: String
}

struct PushAction: Equatable, Sendable {
  var id: String
  var text: String
  var icon: String?
}

struct PushDisplay: Equatable, Sendable {
  var title: String
  var body: String
  var imageUrl: String?
}

enum PushPayload {
  /// Reserved `cr_*` keys — stripped from the RN/event `data` map so sender keys stay unchanged.
  private static let reservedKeys: Set<String> = [
    "cr_delivery_id",
    "cr_attribution_token",
    "cr_message_id",
    "cr_message_recipient_id",
    "cr_title",
    "cr_body",
    "cr_image_url",
    "cr_android_channel_id",
    "cr_deep_link",
    "cr_actions",
    "cr_data_only",
  ]

  static func attribution(_ data: [String: String]?) -> DeliveryAttribution? {
    guard let data else { return nil }
    guard let deliveryId = data["cr_delivery_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !deliveryId.isEmpty else { return nil }
    guard let token = data["cr_attribution_token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !token.isEmpty else { return nil }
    return DeliveryAttribution(deliveryId: deliveryId, attributionToken: token)
  }

  static func isDataOnly(_ data: [String: String]?) -> Bool {
    guard let raw = data?["cr_data_only"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    else { return false }
    return raw == "true" || raw == "1"
  }

  static func messageId(_ data: [String: String]?) -> String? {
    data?["cr_message_id"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  /// Sender `data` keys only — ComRaid reserved `cr_*` keys removed.
  static func senderData(_ data: [String: String]?) -> [String: String] {
    guard let data else { return [:] }
    return data.filter { key, _ in !reservedKeys.contains(key) && !key.hasPrefix("cr_") }
  }

  /**
   First-class deep link from API `content.push.deep_link`, delivered as `cr_deep_link`.
   Returns nil when missing, blank, or not a scheme-bearing URI.
   */
  static func deepLink(_ data: [String: String]?) -> String? {
    guard let raw = data?["cr_deep_link"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    else { return nil }
    guard let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty else { return nil }
    return raw
  }

  static func display(_ data: [String: String]?) -> PushDisplay {
    guard let data else { return PushDisplay(title: "", body: "") }
    return PushDisplay(
      title: data["cr_title"] ?? "",
      body: data["cr_body"] ?? "",
      imageUrl: data["cr_image_url"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    )
  }

  static func actions(_ data: [String: String]?) -> [PushAction] {
    guard let raw = data?["cr_actions"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty,
          let jsonData = raw.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
      return []
    }
    return array.compactMap { obj in
      let id = (obj["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !id.isEmpty, !text.isEmpty else { return nil }
      let icon = (obj["icon"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      return PushAction(id: id, text: text, icon: icon)
    }
  }

  /// Flatten APNs / UNNotification `userInfo` into string map; fill title/body from `aps.alert` when missing.
  static func fromUserInfo(_ userInfo: [AnyHashable: Any]) -> [String: String] {
    var out = stringMap(userInfo)
    if out["cr_title"] == nil || out["cr_title"]?.isEmpty == true {
      if let title = apsAlertString(userInfo, key: "title"), !title.isEmpty {
        out["cr_title"] = title
      }
    }
    if out["cr_body"] == nil || out["cr_body"]?.isEmpty == true {
      if let body = apsAlertString(userInfo, key: "body"), !body.isEmpty {
        out["cr_body"] = body
      }
    }
    return out
  }

  static func stringMap(_ userInfo: [AnyHashable: Any]) -> [String: String] {
    var out: [String: String] = [:]
    for (key, value) in userInfo {
      guard let key = key as? String else { continue }
      if let string = value as? String {
        out[key] = string
      } else if let number = value as? NSNumber {
        out[key] = number.stringValue
      }
    }
    return out
  }

  private static func apsAlertString(_ userInfo: [AnyHashable: Any], key: String) -> String? {
    guard let aps = userInfo["aps"] as? [String: Any] else { return nil }
    if let alert = aps["alert"] as? [String: Any] {
      return alert[key] as? String
    }
    if key == "body", let alert = aps["alert"] as? String {
      return alert
    }
    return nil
  }
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
