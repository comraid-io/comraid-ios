import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

public actor Comraid {
  public static let shared = Comraid()

  private var store: ComraidStore?
  private var configuration: ComraidConfiguration?
  private var api: MobileApiClient?
  private var subscriptionStore: (any SubscriptionCredentialStore)?
  private var tokenProvider: (any TokenProvider)?
  private var apnsTokenProvider: StoredAPNsTokenProvider?
  /// Nil until first use so unit tests that only exercise the identity HTTP seam
  /// never touch `UNUserNotificationCenter.current()` (crashes under SwiftPM's helper).
  private var injectedNotificationCenter: UNUserNotificationCenter?

  public init(notificationCenter: UNUserNotificationCenter? = nil) {
    self.injectedNotificationCenter = notificationCenter
  }

  private var notificationCenter: UNUserNotificationCenter {
    if let injectedNotificationCenter { return injectedNotificationCenter }
    let center = UNUserNotificationCenter.current()
    injectedNotificationCenter = center
    return center
  }

  public func configure(_ configuration: ComraidConfiguration) {
    precondition(!configuration.appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "appId is required (cr_app_…)")
    self.configuration = configuration
    store = ComraidStore(suiteName: configuration.storageSuiteName)
    let credentials = KeychainSubscriptionStore(suiteName: configuration.storageSuiteName)
    subscriptionStore = credentials
    let apns = StoredAPNsTokenProvider()
    apnsTokenProvider = apns
    tokenProvider = apns
    api = MobileApiClient(
      appId: configuration.appId.trimmingCharacters(in: .whitespacesAndNewlines),
      apnsEnvironment: configuration.apnsEnvironment,
      transport: URLSessionHttpTransport(apiBaseURL: configuration.apiBaseURL)
    )
  }

  /// Test seam: injectable HTTP transport, token provider, and subscription store.
  func configureForTests(
    _ configuration: ComraidConfiguration,
    transport: any HttpTransport,
    tokenProvider: any TokenProvider,
    subscriptionStore: any SubscriptionCredentialStore
  ) {
    precondition(!configuration.appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "appId is required (cr_app_…)")
    self.configuration = configuration
    store = ComraidStore(suiteName: configuration.storageSuiteName)
    self.subscriptionStore = subscriptionStore
    self.tokenProvider = tokenProvider
    apnsTokenProvider = nil
    api = MobileApiClient(
      appId: configuration.appId.trimmingCharacters(in: .whitespacesAndNewlines),
      apnsEnvironment: configuration.apnsEnvironment,
      transport: transport
    )
  }

  func resetForTests() {
    configuration = nil
    store = nil
    api = nil
    subscriptionStore = nil
    tokenProvider = nil
    apnsTokenProvider = nil
  }

  /// Forward the APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
  public func setAPNsDeviceToken(_ tokenData: Data) async {
    await apnsTokenProvider?.setDeviceToken(tokenData)
  }

  /**
   Requests notification permission. When granted, asks the system for a remote notification token.
   Call `setAPNsDeviceToken` from AppDelegate, then `register()`.
   */
  @discardableResult
  public func requestPermission(options: UNAuthorizationOptions = [.alert, .badge, .sound]) async throws -> Bool {
    _ = try requireConfigured()
    let granted = try await notificationCenter.requestAuthorization(options: options)
    if granted {
      #if canImport(UIKit) && !os(watchOS)
      await MainActor.run {
        UIApplication.shared.registerForRemoteNotifications()
      }
      #endif
    }
    return granted
  }

  @discardableResult
  public func requestAuthorization(options: UNAuthorizationOptions = [.alert, .badge, .sound]) async throws -> Bool {
    try await requestPermission(options: options)
  }

  /// Fetches the APNs token via TokenProvider and registers a Subscription.
  public func register() async throws {
    let api = try requireAPI()
    let tokens = try requireTokenProvider()
    let store = try requireSubscriptionStore()
    let token = try await tokens.currentToken()
    let result = try await api.register(token: token)
    store.save(subscriptionId: result.subscriptionId, credential: result.credential)
  }

  /// Token rotation: replace-token when credential exists, else full register.
  public func onPushTokenRefresh() async throws {
    let api = try requireAPI()
    let tokens = try requireTokenProvider()
    let store = try requireSubscriptionStore()
    let token = try await tokens.currentToken()
    if let subscriptionId = store.subscriptionId, let credential = store.credential {
      try await api.replaceToken(subscriptionId: subscriptionId, credential: credential, token: token)
    } else {
      let result = try await api.register(token: token)
      store.save(subscriptionId: result.subscriptionId, credential: result.credential)
    }
  }

  public func login(externalUserId: String, identityToken: String? = nil) async throws {
    let api = try requireAPI()
    let (subscriptionId, credential) = try requireSubscription()
    let trimmed = externalUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ComraidError.invalidIdentifier }
    try await api.login(
      subscriptionId: subscriptionId,
      credential: credential,
      externalUserId: trimmed,
      identityToken: identityToken
    )
  }

  public func logout() async throws {
    let api = try requireAPI()
    let (subscriptionId, credential) = try requireSubscription()
    try await api.logout(subscriptionId: subscriptionId, credential: credential)
  }

  public func optOut() async throws {
    let api = try requireAPI()
    let (subscriptionId, credential) = try requireSubscription()
    try await api.optOut(subscriptionId: subscriptionId, credential: credential, channel: "push")
  }

  public func optIn() async throws {
    let api = try requireAPI()
    let (subscriptionId, credential) = try requireSubscription()
    try await api.optIn(subscriptionId: subscriptionId, credential: credential, channel: "push")
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

  private func requireConfigured() throws -> ComraidConfiguration {
    guard let configuration else { throw ComraidError.notConfigured }
    return configuration
  }

  private func requireAPI() throws -> MobileApiClient {
    guard let api else { throw ComraidError.notConfigured }
    return api
  }

  private func requireTokenProvider() throws -> any TokenProvider {
    guard let tokenProvider else { throw ComraidError.notConfigured }
    return tokenProvider
  }

  private func requireSubscriptionStore() throws -> any SubscriptionCredentialStore {
    guard let subscriptionStore else { throw ComraidError.notConfigured }
    return subscriptionStore
  }

  private func requireSubscription() throws -> (String, String) {
    let store = try requireSubscriptionStore()
    guard let subscriptionId = store.subscriptionId, !subscriptionId.isEmpty,
          let credential = store.credential, !credential.isEmpty else {
      throw ComraidError.notReady
    }
    return (subscriptionId, credential)
  }
}
