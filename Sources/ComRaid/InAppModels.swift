import Foundation

/// How an In-app message is laid out. The SDK draws these natively; an `InAppMessagePresenter` can draw its own.
public enum InAppLayout: String, Sendable, Equatable, CaseIterable {
  case modal
  case bannerTop = "banner_top"
  case bannerBottom = "banner_bottom"
  case fullscreen
}

/// A button on an In-app message. The host app routes `deepLink`; the SDK never opens it.
public struct InAppButton: Sendable, Equatable {
  public let id: String
  public let label: String
  public let deepLink: String?

  public init(id: String, label: String, deepLink: String? = nil) {
    self.id = id
    self.label = label
    self.deepLink = deepLink
  }
}

/// One In-app message as received from ComRaid.
public struct InAppMessage: Sendable, Equatable {
  public let id: String
  public let layout: InAppLayout
  public let title: String
  public let body: String
  public let imageURL: String?
  public let buttons: [InAppButton]
  /// Start of the display window; nil means no start.
  public let startAt: Date?
  /// End of the display window; nil means no end.
  public let endAt: Date?
  /// True for a Dashboard Test send: shown normally, but the SDK makes no ACKs for it.
  public let isTest: Bool

  public init(
    id: String,
    layout: InAppLayout,
    title: String,
    body: String,
    imageURL: String? = nil,
    buttons: [InAppButton] = [],
    startAt: Date? = nil,
    endAt: Date? = nil,
    isTest: Bool = false
  ) {
    self.id = id
    self.layout = layout
    self.title = title
    self.body = body
    self.imageURL = imageURL
    self.buttons = buttons
    self.startAt = startAt
    self.endAt = endAt
    self.isTest = isTest
  }
}

/// Reports what happened to one In-app message. An `InAppMessagePresenter` calls these as the user
/// sees, taps or dismisses its own UI; the default layouts call them for you. Calling them for a
/// Test send is safe: no ACK is sent.
public protocol InAppMessageHandle: AnyObject, Sendable {
  /// The message is on screen. Records an impression once.
  func impression()
  /// The user tapped the button with `buttonId`. Unknown ids are ignored.
  func clicked(buttonId: String)
  /// The user closed the message. Records a dismissal once, unless a button was tapped first.
  func dismissed()
}

/// Draws In-app messages in place of the SDK's default layouts. Register one with
/// `ComRaid.setInAppMessagePresenter`; the SDK then draws nothing itself and you report what
/// happened through the handle. `triggers` are the values set with `ComRaid.addTrigger`.
public typealias InAppMessagePresenter = @MainActor @Sendable (
  InAppMessage, any InAppMessageHandle, [String: String]
) -> Void

/// Observes the life of In-app messages (display and dismissal) and button taps. It cannot change
/// or suppress a message. Every method has a no-op default.
public protocol InAppMessageListener: AnyObject, Sendable {
  func willDisplay(_ message: InAppMessage)
  func didDisplay(_ message: InAppMessage)
  func willDismiss(_ message: InAppMessage)
  func didDismiss(_ message: InAppMessage)
  /// A button was tapped. Route `button.deepLink` yourself: the SDK never opens it.
  func didClick(_ message: InAppMessage, button: InAppButton)
}

public extension InAppMessageListener {
  func willDisplay(_ message: InAppMessage) {}
  func didDisplay(_ message: InAppMessage) {}
  func willDismiss(_ message: InAppMessage) {}
  func didDismiss(_ message: InAppMessage) {}
  func didClick(_ message: InAppMessage, button: InAppButton) {}
}
