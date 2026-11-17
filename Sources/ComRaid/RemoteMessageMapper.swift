import Foundation

enum RemoteMessageMapper {
  static func toEvent(_ data: [String: String], actionId: String? = nil) -> RemoteMessageEvent {
    let display = PushPayload.display(data)
    return RemoteMessageEvent(
      messageId: PushPayload.messageId(data),
      deliveryId: data["cr_delivery_id"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      attributionToken: data["cr_attribution_token"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      title: display.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      body: display.body.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      data: PushPayload.senderData(data),
      deepLink: PushPayload.deepLink(data),
      actions: PushPayload.actions(data).map {
        RemoteMessageAction(id: $0.id, text: $0.text, icon: $0.icon)
      },
      actionId: actionId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      imageUrl: display.imageUrl,
      subtitle: display.subtitle,
      sound: display.sound,
      badge: display.badge,
      threadId: display.threadId,
      androidChannelId: display.androidChannelId,
      priority: display.priority
    )
  }

  /// Inverse of `toEvent` so `presentNotification(event)` shares the raw-map display path.
  static func toPayload(_ event: RemoteMessageEvent) -> [String: String] {
    let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let actionsJson: String? = {
      guard !event.actions.isEmpty else { return nil }
      let array: [[String: Any]] = event.actions.map { action in
        var obj: [String: Any] = ["id": action.id, "text": action.text]
        if let icon = action.icon { obj["icon"] = icon }
        return obj
      }
      guard JSONSerialization.isValidJSONObject(array),
            let data = try? JSONSerialization.data(withJSONObject: array),
            let string = String(data: data, encoding: .utf8) else { return nil }
      return string
    }()
    var payload = event.data
    if let deliveryId = event.deliveryId { payload["cr_delivery_id"] = deliveryId }
    if let attributionToken = event.attributionToken { payload["cr_attribution_token"] = attributionToken }
    if let messageId = event.messageId { payload["cr_message_id"] = messageId }
    payload["cr_title"] = title
    payload["cr_body"] = event.body ?? ""
    if let deepLink = event.deepLink { payload["cr_deep_link"] = deepLink }
    if let actionsJson { payload["cr_actions"] = actionsJson }
    if let imageUrl = event.imageUrl { payload["cr_image_url"] = imageUrl }
    if let subtitle = event.subtitle { payload["cr_subtitle"] = subtitle }
    if let sound = event.sound { payload["cr_sound"] = sound }
    if let badge = event.badge { payload["cr_badge"] = String(badge) }
    if let threadId = event.threadId { payload["cr_thread_id"] = threadId }
    if let androidChannelId = event.androidChannelId {
      payload["cr_android_channel_id"] = androidChannelId
    }
    payload["cr_priority"] = RemoteMessageEvent.normalizedPriority(event.priority)
    return payload
  }
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
