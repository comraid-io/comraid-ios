import Foundation

/**
 RNFirebase-shaped remote Notification event payload.
 `data` holds sender keys only (ComRaid `cr_*` reserved keys stripped).
 `attributionToken` is first-class so JS / presentNotification can ACK opened.
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

  public init(
    messageId: String? = nil,
    deliveryId: String? = nil,
    attributionToken: String? = nil,
    title: String? = nil,
    body: String? = nil,
    data: [String: String] = [:],
    deepLink: String? = nil,
    actions: [RemoteMessageAction] = [],
    actionId: String? = nil
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
