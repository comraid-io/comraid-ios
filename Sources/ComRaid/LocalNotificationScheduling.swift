import Foundation
@preconcurrency import UserNotifications

/// Seam for arming / cancelling device Local notifications (mirrors Android `NotificationScheduler`).
protocol LocalNotificationScheduling: Sendable {
  func schedule(_ request: ComRaidScheduleRequest) async throws
  func cancel(id: String)
}

final class SystemLocalNotificationScheduler: LocalNotificationScheduling, @unchecked Sendable {
  private let center: UNUserNotificationCenter
  private let clock: @Sendable () -> Date

  init(center: UNUserNotificationCenter, clock: @escaping @Sendable () -> Date) {
    self.center = center
    self.clock = clock
  }

  func schedule(_ request: ComRaidScheduleRequest) async throws {
    let content = UNMutableNotificationContent()
    content.title = request.notification.title
    content.body = request.notification.body
    if let subtitle = request.notification.subtitle { content.subtitle = subtitle }
    if let category = request.notification.categoryIdentifier { content.categoryIdentifier = category }
    content.userInfo = request.notification.userInfo
    if request.notification.sound == "default" {
      content.sound = .default
    } else if let sound = request.notification.sound {
      content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
    }
    let interval = max(request.triggerDate.timeIntervalSince(clock()), 0.1)
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
    try await center.add(
      UNNotificationRequest(identifier: request.notification.id, content: content, trigger: trigger)
    )
  }

  func cancel(id: String) {
    center.removePendingNotificationRequests(withIdentifiers: [id])
  }
}
