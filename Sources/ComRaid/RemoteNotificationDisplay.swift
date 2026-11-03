import Foundation
import UserNotifications

/// Builds UNNotification content and categories from ComRaid push data keys.
public enum RemoteNotificationDisplay {
  /// APNs category id the server sets on action-bearing alerts (`comraid.actions`).
  /// Must match server `IOSActionsCategory` so remote pushes show their buttons.
  public static let actionsCategoryIdentifier = "comraid.actions"

  public static func content(from data: [String: String]) -> UNMutableNotificationContent {
    let display = PushPayload.display(data)
    let content = UNMutableNotificationContent()
    content.title = display.title
    content.body = display.body
    content.userInfo = data
    content.sound = .default
    if !PushPayload.actions(data).isEmpty {
      content.categoryIdentifier = actionsCategoryIdentifier
    }
    return content
  }

  public static func categories(from data: [String: String]) -> [UNNotificationCategory] {
    let actions = PushPayload.actions(data)
    guard !actions.isEmpty else {
      return []
    }
    let unActions = actions.map { action in
      UNNotificationAction(
        identifier: action.id,
        title: action.text,
        options: [.foreground]
      )
    }
    return [
      UNNotificationCategory(
        identifier: actionsCategoryIdentifier,
        actions: unActions,
        intentIdentifiers: [],
        options: []
      ),
    ]
  }

  /// Category id for action-bearing pushes. Matches the server APNs/FCM category.
  /// - Parameter deliveryId: Unused; kept for source compatibility with earlier per-delivery ids.
  @available(*, deprecated, message: "Use actionsCategoryIdentifier; deliveryId is ignored")
  public static func categoryIdentifier(for deliveryId: String) -> String {
    _ = deliveryId
    return actionsCategoryIdentifier
  }

  /// Register action categories with the system notification center.
  /// Updates the shared `comraid.actions` category from the payload's buttons.
  /// Background OS-drawn alerts only show buttons when this category was already
  /// registered (for example after a prior present/register, or via an NSE).
  public static func registerCategories(from data: [String: String]) async {
    let next = categories(from: data)
    guard !next.isEmpty else { return }
    let center = UNUserNotificationCenter.current()
    let existing = await center.notificationCategories()
    var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.identifier, $0) })
    for category in next {
      merged[category.identifier] = category
    }
    center.setNotificationCategories(Set(merged.values))
  }

  /**
   Post a local tray item immediately from `cr_*` payload keys (optional promotion).
   Requires a non-blank `cr_title`.
   */
  public static func present(
    data: [String: String],
    notificationCenter: UNUserNotificationCenter = .current()
  ) async throws {
    let display = PushPayload.display(data)
    let title = display.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      throw ComRaidError.invalidIdentifier
    }
    await registerCategories(from: data)
    let content = content(from: data)
    let deliveryId = data["cr_delivery_id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let identifier = (deliveryId?.isEmpty == false ? deliveryId! : UUID().uuidString)
    try await notificationCenter.add(
      UNNotificationRequest(identifier: "comraid.present.\(identifier)", content: content, trigger: nil)
    )
  }
}
