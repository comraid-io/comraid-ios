import Foundation

/**
 RNFirebase-shaped remote Notification event payload.
 `data` holds sender keys only (ComRaid `cr_*` reserved keys stripped).
 `attributionToken` is first-class so JS / presentNotification can ACK opened.
 Presentation fields (`imageUrl`, `subtitle`, `sound`, `badge`, `threadId`,
 `androidChannelId`, `priority`) are first-class so `presentNotification` keeps them.
 `priority` is always `"high"` or `"normal"` on received events.
 */
public struct RemoteMessageEvent: Sendable, Equatable {
  public var messageId: String?
  public var deliveryId: String?
  public var attributionToken: String?
  public var title: String?
  public var body: String?
  public var data: [String: String]
  public var deepLink: String?
  public var actions: [RemoteMessageAction]
  public var actionId: String?
  public var imageUrl: String?
  public var subtitle: String?
  public var sound: String?
  public var badge: Int?
  public var threadId: String?
  public var androidChannelId: String?
  /// Always `"high"` or `"normal"` on received events (default `"high"`).
  public var priority: String

  public init(
    messageId: String? = nil,
    deliveryId: String? = nil,
    attributionToken: String? = nil,
    title: String? = nil,
    body: String? = nil,
    data: [String: String] = [:],
    deepLink: String? = nil,
    actions: [RemoteMessageAction] = [],
    actionId: String? = nil,
    imageUrl: String? = nil,
    subtitle: String? = nil,
    sound: String? = nil,
    badge: Int? = nil,
    threadId: String? = nil,
    androidChannelId: String? = nil,
    priority: String = "high"
  ) {
    self.messageId = messageId
    self.deliveryId = deliveryId
    self.attributionToken = attributionToken
    self.title = title
    self.body = body
    self.data = data
    self.deepLink = deepLink
    self.actions = actions
    self.actionId = actionId
    self.imageUrl = imageUrl
    self.subtitle = subtitle
    self.sound = sound
    self.badge = badge
    self.threadId = threadId
    self.androidChannelId = androidChannelId
    self.priority = Self.normalizedPriority(priority)
  }

  static func normalizedPriority(_ raw: String?) -> String {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return trimmed == "normal" ? "normal" : "high"
  }
}

public struct RemoteMessageAction: Sendable, Equatable {
  public var id: String
  public var text: String
  public var icon: String?

  public init(id: String, text: String, icon: String? = nil) {
    self.id = id
    self.text = text
    self.icon = icon
  }
}

public typealias RemoteMessageListener = @Sendable (RemoteMessageEvent) -> Void
public typealias TokenRefreshListener = @Sendable (String) -> Void
