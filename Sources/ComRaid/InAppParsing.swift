import Foundation

/// A fetched In-app message with the Delivery credentials its ACKs need (absent for a Test send).
struct FetchedInAppMessage: Sendable, Equatable {
  var message: InAppMessage
  var deliveryId: String?
  var attributionToken: String?
}

/// RFC 3339 instant parsing, with or without fractional seconds.
func parseRFC3339(_ value: String?) -> Date? {
  guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
  let plain = ISO8601DateFormatter()
  plain.formatOptions = [.withInternetDateTime]
  if let date = plain.date(from: value) { return date }
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return fractional.date(from: value)
}

/// Parse the `messages` array of GET /in-app-messages, dropping any message the SDK cannot draw.
func parseInAppMessages(_ raw: Any?) -> [FetchedInAppMessage] {
  guard let array = raw as? [[String: Any]] else { return [] }
  return array.compactMap(parseInAppMessage)
}

private func parseInAppMessage(_ object: [String: Any]) -> FetchedInAppMessage? {
  guard let id = (object["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
        let layoutRaw = object["layout"] as? String,
        let layout = InAppLayout(rawValue: layoutRaw)
  else { return nil }

  let buttons: [InAppButton] = ((object["buttons"] as? [[String: Any]]) ?? []).compactMap { raw in
    guard let buttonId = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !buttonId.isEmpty else {
      return nil
    }
    return InAppButton(
      id: buttonId,
      label: raw["label"] as? String ?? "",
      deepLink: nonEmpty(raw["deep_link"] as? String)
    )
  }
  let isTest = object["test"] as? Bool ?? false
  return FetchedInAppMessage(
    message: InAppMessage(
      id: id,
      layout: layout,
      title: object["title"] as? String ?? "",
      body: object["body"] as? String ?? "",
      imageURL: nonEmpty(object["image_url"] as? String),
      buttons: buttons,
      startAt: parseRFC3339(object["start_at"] as? String),
      endAt: parseRFC3339(object["end_at"] as? String),
      isTest: isTest
    ),
    // A Test send has no Delivery; never ACK it even if credentials were somehow present.
    deliveryId: isTest ? nil : nonEmpty(object["delivery_id"] as? String),
    attributionToken: isTest ? nil : nonEmpty(object["attribution_token"] as? String)
  )
}

private func nonEmpty(_ value: String?) -> String? {
  guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
  return trimmed
}

extension FetchedInAppMessage {
  /// Cache form: like the wire form, but with the window already as epoch seconds.
  func toCacheJSON() -> [String: Any] {
    var json: [String: Any] = [
      "id": message.id,
      "layout": message.layout.rawValue,
      "title": message.title,
      "body": message.body,
      "buttons": message.buttons.map { button -> [String: Any] in
        var item: [String: Any] = ["id": button.id, "label": button.label]
        if let deepLink = button.deepLink { item["deep_link"] = deepLink }
        return item
      },
      "test": message.isTest,
    ]
    if let imageURL = message.imageURL { json["image_url"] = imageURL }
    if let startAt = message.startAt { json["start_ts"] = startAt.timeIntervalSince1970 }
    if let endAt = message.endAt { json["end_ts"] = endAt.timeIntervalSince1970 }
    if let deliveryId { json["delivery_id"] = deliveryId }
    if let attributionToken { json["attribution_token"] = attributionToken }
    return json
  }
}

func parseCachedInAppMessages(_ raw: Any?) -> [FetchedInAppMessage] {
  guard let array = raw as? [[String: Any]] else { return [] }
  return array.compactMap { object in
    guard var parsed = parseInAppMessage(object) else { return nil }
    let start = (object["start_ts"] as? Double).map { Date(timeIntervalSince1970: $0) }
    let end = (object["end_ts"] as? Double).map { Date(timeIntervalSince1970: $0) }
    parsed.message = InAppMessage(
      id: parsed.message.id,
      layout: parsed.message.layout,
      title: parsed.message.title,
      body: parsed.message.body,
      imageURL: parsed.message.imageURL,
      buttons: parsed.message.buttons,
      startAt: start,
      endAt: end,
      isTest: parsed.message.isTest
    )
    return parsed
  }
}
