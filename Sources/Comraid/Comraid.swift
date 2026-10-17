import Foundation
import UserNotifications

public actor Comraid {
  public static let shared = Comraid()

  private var store: ComraidStore?
  private let notificationCenter: UNUserNotificationCenter

  public init(notificationCenter: UNUserNotificationCenter = .current()) {
    self.notificationCenter = notificationCenter
  }

  public func configure(_ configuration: ComraidConfiguration = .init()) {
    store = ComraidStore(suiteName: configuration.storageSuiteName)
  }

  @discardableResult
  public func requestAuthorization(options: UNAuthorizationOptions = [.alert, .badge, .sound]) async throws -> Bool {
    try await notificationCenter.requestAuthorization(options: options)
  }

  public func capabilities() async -> ComraidCapabilities {
    let settings = await notificationCenter.notificationSettings()
    let status: ComraidAuthorizationStatus = switch settings.authorizationStatus {
    case .notDetermined: .notDetermined
    case .denied: .denied
    case .authorized: .authorized
    case .provisional: .provisional
    case .ephemeral: .ephemeral
    @unknown default: .unknown
    }
    let enabled = settings.alertSetting == .enabled || settings.authorizationStatus == .provisional
    return ComraidCapabilities(authorizationStatus: status, notificationsEnabled: enabled)
  }

  public func schedule(_ request: ComraidScheduleRequest) async throws {
    let currentStore = try configuredStore()
    try validate(request)
    try await addSystemRequest(request)

    var state = currentStore.read()
    state.schedules.removeAll { $0.notification.id == request.notification.id }
    state.schedules.append(request)
    do {
      try currentStore.write(state)
    } catch {
      notificationCenter.removePendingNotificationRequests(withIdentifiers: [request.notification.id])
      throw ComraidError.persistenceFailed
    }
  }

  public func pendingSchedules() throws -> [ComraidScheduleRequest] {
    try configuredStore().read().schedules.filter { $0.triggerDate > Date() }.sorted { $0.triggerDate < $1.triggerDate }
  }

  public func cancel(id: String) throws {
    let currentStore = try configuredStore()
    notificationCenter.removePendingNotificationRequests(withIdentifiers: [id])
    var state = currentStore.read()
    state.schedules.removeAll { $0.notification.id == id }
    if let index = state.timers.firstIndex(where: { $0.id == id }) {
      state.timers[index].state = .cancelled
      state.timers[index].targetDate = nil
    }
    try currentStore.write(state)
  }

  @discardableResult
  public func startTimer(
    id: String,
    duration: TimeInterval,
    notification: ComraidNotification
  ) async throws -> ComraidTimer {
    guard duration.isFinite, duration > 0 else { throw ComraidError.triggerMustBeInFuture }
    let targetDate = Date().addingTimeInterval(duration)
    var adjustedNotification = notification
    adjustedNotification.id = id
    try await schedule(.init(notification: adjustedNotification, triggerDate: targetDate))

    let timer = ComraidTimer(
      id: id,
      notification: adjustedNotification,
      state: .running,
      targetDate: targetDate,
      remainingDuration: duration
    )
    try updateTimer(timer)
    return timer
  }

  @discardableResult
  public func pauseTimer(id: String) throws -> ComraidTimer {
    let currentStore = try configuredStore()
    var state = currentStore.read()
    guard let index = state.timers.firstIndex(where: { $0.id == id }) else { throw ComraidError.timerNotFound }
    var timer = state.timers[index]
    guard timer.state == .running, let targetDate = timer.targetDate else { throw ComraidError.timerNotPaused }
    timer.remainingDuration = max(0, targetDate.timeIntervalSinceNow)
    timer.targetDate = nil
    timer.state = .paused
    state.timers[index] = timer
    state.schedules.removeAll { $0.notification.id == id }
    notificationCenter.removePendingNotificationRequests(withIdentifiers: [id])
    try currentStore.write(state)
    return timer
  }

  @discardableResult
  public func resumeTimer(id: String) async throws -> ComraidTimer {
    let currentStore = try configuredStore()
    let state = currentStore.read()
    guard var timer = state.timers.first(where: { $0.id == id }) else { throw ComraidError.timerNotFound }
    guard timer.state == .paused else { throw ComraidError.timerNotPaused }
    let targetDate = Date().addingTimeInterval(max(timer.remainingDuration, 0.1))
    timer.state = .running
    timer.targetDate = targetDate
    try await schedule(.init(notification: timer.notification, triggerDate: targetDate))
    try updateTimer(timer)
    return timer
  }

  public func cancelTimer(id: String) throws {
    let currentStore = try configuredStore()
    notificationCenter.removePendingNotificationRequests(withIdentifiers: [id])
    var state = currentStore.read()
    state.schedules.removeAll { $0.notification.id == id }
    if let index = state.timers.firstIndex(where: { $0.id == id }) {
      state.timers[index].state = .cancelled
      state.timers[index].targetDate = nil
    }
    try currentStore.write(state)
  }

  public func timers() throws -> [ComraidTimer] {
    try configuredStore().read().timers
  }

  private func addSystemRequest(_ request: ComraidScheduleRequest) async throws {
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
    let interval = max(request.triggerDate.timeIntervalSinceNow, 0.1)
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
    try await notificationCenter.add(
      UNNotificationRequest(identifier: request.notification.id, content: content, trigger: trigger)
    )
  }

  private func updateTimer(_ timer: ComraidTimer) throws {
    let currentStore = try configuredStore()
    var state = currentStore.read()
    state.timers.removeAll { $0.id == timer.id }
    state.timers.append(timer)
    try currentStore.write(state)
  }

  private func validate(_ request: ComraidScheduleRequest) throws {
    guard !request.notification.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ComraidError.invalidIdentifier
    }
    guard request.triggerDate.timeIntervalSince1970.isFinite, request.triggerDate.timeIntervalSinceNow > 0 else { throw ComraidError.triggerMustBeInFuture }
  }

  private func configuredStore() throws -> ComraidStore {
    guard let store else { throw ComraidError.notConfigured }
    return store
  }
}
