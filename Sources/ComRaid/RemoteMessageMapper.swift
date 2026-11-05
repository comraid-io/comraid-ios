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
      sound: display.sound,
      badge: display.badge,
      threadId: display.threadId
    )
  }
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
