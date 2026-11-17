import Foundation
import UserNotifications

/**
 Decides whether a remote Notification should present in the foreground
 (`userNotificationCenter(_:willPresent:…)`).

 - Data-only Notifications never auto-draw (ADR 0006); apps use `presentNotification`.
 - Non–data-only alerts show in the foreground by default; hosts may opt out via configuration.
 */
public enum RemoteDisplayPolicy {
  public static func presentationOptions(
    data: [String: String],
    displayForegroundNotifications: Bool
  ) -> UNNotificationPresentationOptions {
    if PushPayload.isDataOnly(data) { return [] }
    if PushPayload.display(data).title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return []
    }
    if !displayForegroundNotifications { return [] }
    return [.banner, .list, .sound]
  }
}
