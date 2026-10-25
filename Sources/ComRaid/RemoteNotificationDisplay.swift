import Foundation
import UserNotifications

/// Builds UNNotification content and categories from ComRaid push data keys.
public enum RemoteNotificationDisplay {
  public static func content(from data: [String: String]) -> UNMutableNotificationContent {
    let display = PushPayload.display(data)
    let content = UNMutableNotificationContent()
    content.title = display.title
    content.body = display.body
    content.userInfo = data
    content.sound = .default
    if let deliveryId = data["cr_delivery_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !deliveryId.isEmpty,
       !PushPayload.actions(data).isEmpty {
      content.categoryIdentifier = categoryIdentifier(for: deliveryId)
    }
    return content
  }

  public static func categories(from data: [String: String]) -> [UNNotificationCategory] {
    let actions = PushPayload.actions(data)
    guard !actions.isEmpty,
          let deliveryId = data["cr_delivery_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !deliveryId.isEmpty else {
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
        identifier: categoryIdentifier(for: deliveryId),
        actions: unActions,
        intentIdentifiers: [],
        options: []
      ),
    ]
  }

  public static func categoryIdentifier(for deliveryId: String) -> String {
    "comraid.\(deliveryId)"
  }

  /// Register action categories with the system notification center.
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
