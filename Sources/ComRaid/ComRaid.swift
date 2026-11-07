import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

public actor ComRaid {
  public static let shared = ComRaid()

  private var store: ComRaidStore?
  private var configuration: ComRaidConfiguration?
  private var api: MobileApiClient?
  private var subscriptionStore: (any SubscriptionCredentialStore)?
  private var tokenProvider: (any TokenProvider)?
  private var apnsTokenProvider: StoredAPNsTokenProvider?
  private var ackQueue: AckQueue?
  private var deviceProperties: DeviceProperties?
  private var externalUserId: String?
  /// Nil until first use so unit tests that only exercise the identity HTTP seam
  /// never touch `UNUserNotificationCenter.current()` (crashes under SwiftPM's helper).
  private var injectedNotificationCenter: UNUserNotificationCenter?
  /// Flushes queued ACKs on app foreground (NSE / background helpers flush separately).
  private var foregroundFlushObserver: NSObjectProtocol?

  public init(notificationCenter: UNUserNotificationCenter? = nil) {
    self.injectedNotificationCenter = notificationCenter
  }

  private var notificationCenter: UNUserNotificationCenter {
    if let injectedNotificationCenter { return injectedNotificationCenter }
    let center = UNUserNotificationCenter.current()
    injectedNotificationCenter = center
    return center
  }

  public func configure(_ configuration: ComRaidConfiguration) {
    precondition(!configuration.appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "appId is required (cr_app_…)")
    self.configuration = configuration
    store = ComRaidStore(suiteName: configuration.storageSuiteName)
    let credentials = KeychainSubscriptionStore(suiteName: configuration.storageSuiteName)
    subscriptionStore = credentials
    let apns = StoredAPNsTokenProvider()
    apnsTokenProvider = apns
    tokenProvider = apns
    let transport = URLSessionHttpTransport(apiBaseURL: configuration.apiBaseURL)
    api = MobileApiClient(
      appId: configuration.appId.trimmingCharacters(in: .whitespacesAndNewlines),
      apnsEnvironment: configuration.apnsEnvironment,
      transport: transport
    )
    let queue = AckQueue(
      apiBaseURL: configuration.apiBaseURL,
      store: UserDefaultsAckQueueStore(suiteName: configuration.storageSuiteName),
      transport: transport
    )
    ackQueue = queue
    deviceProperties = nil
    externalUserId = nil
    SdkConfigStore(suiteName: configuration.storageSuiteName).save(configuration)
    installForegroundFlushObserver()
    Task { await queue.flush() }
  }

  /// Test seam: injectable HTTP transport, token provider, subscription store, and ACK store.
  func configureForTests(
    _ configuration: ComRaidConfiguration,
    transport: any HttpTransport,
    tokenProvider: any TokenProvider,
    subscriptionStore: any SubscriptionCredentialStore,
    ackQueueStore: (any AckQueueStore)? = nil
  ) {
    precondition(!configuration.appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "appId is required (cr_app_…)")
    self.configuration = configuration
    store = ComRaidStore(suiteName: configuration.storageSuiteName)
    self.subscriptionStore = subscriptionStore
    self.tokenProvider = tokenProvider
    apnsTokenProvider = nil
    api = MobileApiClient(
      appId: configuration.appId.trimmingCharacters(in: .whitespacesAndNewlines),
      apnsEnvironment: configuration.apnsEnvironment,
      transport: transport
    )
    ackQueue = AckQueue(
      apiBaseURL: configuration.apiBaseURL,
      store: ackQueueStore ?? InMemoryAckQueueStoreForTests(),
      transport: transport
    )
    deviceProperties = nil
    externalUserId = nil
  }

  func resetForTests() {
    removeForegroundFlushObserver()
    configuration = nil
    store = nil
    api = nil
    subscriptionStore = nil
    tokenProvider = nil
    apnsTokenProvider = nil
    ackQueue = nil
    deviceProperties = nil
    externalUserId = nil
    RemoteReceiveHub.shared.resetForTests()
  }

  /// App foreground entry: drain any ACKs queued while offline / in background.
  /// Notification Service Extension uses `BackgroundAckHelpers` (no BGTask).
  func handleAppWillEnterForeground() async {
    await ackQueue?.flush()
  }

  private func installForegroundFlushObserver() {
    #if canImport(UIKit)
    removeForegroundFlushObserver()
    foregroundFlushObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      Task { await ComRaid.shared.handleAppWillEnterForeground() }
    }
    #endif
  }

  private func removeForegroundFlushObserver() {
    if let foregroundFlushObserver {
      NotificationCenter.default.removeObserver(foregroundFlushObserver)
      self.foregroundFlushObserver = nil
    }
  }

  /// Forward the APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
  public func setAPNsDeviceToken(_ tokenData: Data) async {
    await apnsTokenProvider?.setDeviceToken(tokenData)
    if let hex = try? await apnsTokenProvider?.currentToken() {
      RemoteReceiveHub.shared.notifyTokenRefresh(hex)
    }
  }

  /// Provider push token (APNs hex). Not a ComRaid Endpoint / Subscription id.
  public func getToken() async throws -> String {
    try await requireTokenProvider().currentToken()
  }

  /**
   Cold-start tap payload, if any. Cleared after the first successful read.
   */
  public func getInitialNotification() -> RemoteMessageEvent? {
    RemoteReceiveHub.shared.getInitialNotification()
  }

  @discardableResult
  public func addForegroundMessageListener(_ listener: @escaping RemoteMessageListener) -> ComRaidListenerToken {
    RemoteReceiveHub.shared.addForegroundMessageListener(listener)
  }

  public func removeForegroundMessageListener(_ token: ComRaidListenerToken) {
    RemoteReceiveHub.shared.removeForegroundMessageListener(token)
  }

  @discardableResult
  public func addBackgroundMessageListener(_ listener: @escaping RemoteMessageListener) -> ComRaidListenerToken {
    RemoteReceiveHub.shared.addBackgroundMessageListener(listener)
  }

  public func removeBackgroundMessageListener(_ token: ComRaidListenerToken) {
    RemoteReceiveHub.shared.removeBackgroundMessageListener(token)
  }

  @discardableResult
  public func addNotificationOpenedListener(_ listener: @escaping RemoteMessageListener) -> ComRaidListenerToken {
    RemoteReceiveHub.shared.addNotificationOpenedListener(listener)
  }

  public func removeNotificationOpenedListener(_ token: ComRaidListenerToken) {
    RemoteReceiveHub.shared.removeNotificationOpenedListener(token)
  }

  @discardableResult
  public func addTokenRefreshListener(_ listener: @escaping TokenRefreshListener) -> ComRaidListenerToken {
    RemoteReceiveHub.shared.addTokenRefreshListener(listener)
  }

  public func removeTokenRefreshListener(_ token: ComRaidListenerToken) {
    RemoteReceiveHub.shared.removeTokenRefreshListener(token)
  }

  /**
   Marks that a JS background message handler is registered (RN).
   Receive still never auto-opens; this only mirrors the Android flag.
   */
  public func setBackgroundHandlerRegistered(_ registered: Bool) {
    RemoteReceiveHub.shared.setBackgroundHandlerRegistered(registered)
  }

  public func isBackgroundHandlerRegistered() -> Bool {
    RemoteReceiveHub.shared.isBackgroundHandlerRegistered()
  }

  /**
   Post a local tray item from a received message's title/body/actions (optional promotion).
   Body/action taps auto ACK opened via `handleNotificationResponse` (with actionId for actions).
   */
  public func presentNotification(_ event: RemoteMessageEvent) async throws {
    _ = try requireConfigured()
    let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !title.isEmpty else {
      throw ComRaidError.apiError("presentNotification requires a non-blank title")
    }
    try await RemoteNotificationDisplay.present(data: RemoteMessageMapper.toPayload(event))
  }

  /// Present from raw APNs-shaped data map (title via `cr_title`).
  public func presentNotification(data: [String: String]) async throws {
    try await presentNotification(RemoteMessageMapper.toEvent(data))
  }

  /**
   Presentation options for `userNotificationCenter(_:willPresent:…)`.
   Data-only never presents; non–data-only follows `displayForegroundNotifications`.
   */
  public func presentationOptions(for userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions {
    presentationOptions(forData: PushPayload.fromUserInfo(userInfo))
  }

  public func presentationOptions(forData data: [String: String]) -> UNNotificationPresentationOptions {
    let displayFg = configuration?.displayForegroundNotifications
      ?? SdkConfigStore(suiteName: configuration?.storageSuiteName).load()?.displayForegroundNotifications
      ?? true
    return RemoteDisplayPolicy.presentationOptions(
      data: data,
      displayForegroundNotifications: displayFg
    )
  }

  /**
   Requests notification permission. When granted, asks the system for a remote notification token.
   Call `setAPNsDeviceToken` from AppDelegate, then `register()`.
   */
  // Notification Service Extensions link this module; UIApplication.shared is app-only.
  @available(iOSApplicationExtension, unavailable)
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

  @available(iOSApplicationExtension, unavailable)
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
    let result = try await api.register(token: token, properties: deviceProperties)
    store.save(subscriptionId: result.subscriptionId, credential: result.credential)
  }

  /// Token rotation: replace-token when credential exists, else full register.
  public func onPushTokenRefresh() async throws {
    let api = try requireAPI()
    let tokens = try requireTokenProvider()
    let store = try requireSubscriptionStore()
    let token = try await tokens.currentToken()
    if let subscriptionId = store.subscriptionId, let credential = store.credential {
      try await api.replaceToken(
        subscriptionId: subscriptionId,
        credential: credential,
        token: token,
        properties: deviceProperties
      )
    } else {
      let result = try await api.register(token: token, properties: deviceProperties)
      store.save(subscriptionId: result.subscriptionId, credential: result.credential)
    }
  }

  public func login(externalUserId: String, jwt: String? = nil) async throws {
    let api = try requireAPI()
    let (subscriptionId, credential) = try requireSubscription()
    let trimmed = externalUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ComRaidError.invalidIdentifier }
    try await api.login(
      subscriptionId: subscriptionId,
      credential: credential,
      externalUserId: trimmed,
      jwt: jwt
    )
    self.externalUserId = trimmed
  }

  public func logout() async throws {
    let api = try requireAPI()
    let (subscriptionId, credential) = try requireSubscription()
    try await api.logout(subscriptionId: subscriptionId, credential: credential)
    externalUserId = nil
  }

  /// Persist Subscription device Properties for the next register / token refresh.
  public func setDeviceProperties(_ properties: DeviceProperties) {
    _ = try? requireConfigured()
    deviceProperties = properties
  }

  /**
   Upsert Contact Attributes for the logged-in Contact
   (`PUT /mobile/subscriptions/{id}/attributes`).
   */
  public func setAttributes(_ attributes: sending [String: Any]) async throws {
    let api = try requireAPI()
    guard let externalUserId, !externalUserId.isEmpty else { throw ComRaidError.notReady }
    let (subscriptionId, credential) = try requireSubscription()
    try await api.upsertAttributes(
      subscriptionId: subscriptionId,
      credential: credential,
      attributes: attributes
    )
  }

  /// Enqueue + flush a delivered ACK. Returns false when ids are blank.
  @discardableResult
  public func acknowledgeDelivered(deliveryId: String, attributionToken: String) async -> Bool {
    guard let ackQueue else { return false }
    let trimmedId = deliveryId.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedToken = attributionToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedId.isEmpty, !trimmedToken.isEmpty else { return false }
    _ = await ackQueue.enqueueFromPayload(
      kind: .delivered,
      data: [
        "cr_delivery_id": trimmedId,
        "cr_attribution_token": trimmedToken,
      ]
    )
    await ackQueue.flush()
    return true
  }

  /// Enqueue + flush an opened ACK (optional action button id).
  @discardableResult
  public func acknowledgeOpened(
    deliveryId: String,
    attributionToken: String,
    actionId: String? = nil
  ) async -> Bool {
    guard let ackQueue else { return false }
    let trimmedId = deliveryId.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedToken = attributionToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedId.isEmpty, !trimmedToken.isEmpty else { return false }
    _ = await ackQueue.enqueueFromPayload(
      kind: .opened,
      data: [
        "cr_delivery_id": trimmedId,
        "cr_attribution_token": trimmedToken,
      ],
      actionId: actionId
    )
    await ackQueue.flush()
    return true
  }

  /// Flush any durable ACK backlog (safe to call from app launch).
  public func flushAcks() async {
    await ackQueue?.flush()
  }

  /**
   Process a remote notification payload: register action categories, enqueue delivered ACK,
   and notify foreground/background receive listeners. Does not mark opened (ADR 0006).
   Call from `UNUserNotificationCenterDelegate` / AppDelegate when a push arrives.
   */
  public func handleRemoteNotification(
    userInfo: [AnyHashable: Any],
    appInForeground: Bool = true
  ) async {
    await handleRemoteNotification(
      data: PushPayload.fromUserInfo(userInfo),
      appInForeground: appInForeground
    )
  }

  public func handleRemoteNotification(
    data: [String: String],
    appInForeground: Bool = true
  ) async {
    await RemoteNotificationDisplay.registerCategories(from: data)
    if let ackQueue {
      _ = await ackQueue.enqueueFromPayload(kind: .delivered, data: data)
      await ackQueue.flush()
    } else {
      await BackgroundAckHelpers.handleReceived(data: data)
    }
    // Delivered ≠ opened: never auto-ACK opened on receive (ADR 0006).
    RemoteReceiveHub.shared.notifyMessageReceived(
      RemoteMessageMapper.toEvent(data),
      appInForeground: appInForeground
    )
  }

  /**
   Process a notification response (tap / action). Enqueues opened ACK and notifies
   opened listeners (including SDK-presented tray taps from `presentNotification`).
   Call from `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
   */
  public func handleNotificationResponse(_ response: UNNotificationResponse) async {
    let actionId: String? = {
      switch response.actionIdentifier {
      case UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier:
        return nil
      default:
        return response.actionIdentifier
      }
    }()
    await handleNotificationOpen(
      userInfo: response.notification.request.content.userInfo,
      actionId: actionId
    )
  }

  /**
   Process a notification open from raw `userInfo` + optional action id (ObjC / RN hosts).
   */
  public func handleNotificationOpen(
    userInfo: [AnyHashable: Any],
    actionId: String? = nil
  ) async {
    await handleNotificationOpen(data: PushPayload.fromUserInfo(userInfo), actionId: actionId)
  }

  public func handleNotificationOpen(
    data: [String: String],
    actionId: String? = nil
  ) async {
    let trimmedAction = actionId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedAction = (trimmedAction?.isEmpty == false) ? trimmedAction : nil
    if let ackQueue {
      _ = await ackQueue.enqueueFromPayload(kind: .opened, data: data, actionId: resolvedAction)
      await ackQueue.flush()
    } else {
      await BackgroundAckHelpers.handleOpened(data: data, actionId: resolvedAction)
    }
    RemoteReceiveHub.shared.notifyNotificationOpened(
      RemoteMessageMapper.toEvent(data, actionId: resolvedAction)
    )
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

  public func capabilities() async -> ComRaidCapabilities {
    let settings = await notificationCenter.notificationSettings()
    let status: ComRaidAuthorizationStatus = switch settings.authorizationStatus {
    case .notDetermined: .notDetermined
    case .denied: .denied
    case .authorized: .authorized
    case .provisional: .provisional
    case .ephemeral: .ephemeral
    @unknown default: .unknown
    }
    let enabled = settings.alertSetting == .enabled || settings.authorizationStatus == .provisional
    return ComRaidCapabilities(authorizationStatus: status, notificationsEnabled: enabled)
  }

  public func schedule(_ request: ComRaidScheduleRequest) async throws {
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
      throw ComRaidError.persistenceFailed
    }
  }

  public func pendingSchedules() throws -> [ComRaidScheduleRequest] {
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
    notification: ComRaidNotification
  ) async throws -> ComRaidTimer {
    guard duration.isFinite, duration > 0 else { throw ComRaidError.triggerMustBeInFuture }
    let targetDate = Date().addingTimeInterval(duration)
    var adjustedNotification = notification
    adjustedNotification.id = id
    try await schedule(.init(notification: adjustedNotification, triggerDate: targetDate))

    let timer = ComRaidTimer(
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
  public func pauseTimer(id: String) throws -> ComRaidTimer {
    let currentStore = try configuredStore()
    var state = currentStore.read()
    guard let index = state.timers.firstIndex(where: { $0.id == id }) else { throw ComRaidError.timerNotFound }
    var timer = state.timers[index]
    guard timer.state == .running, let targetDate = timer.targetDate else { throw ComRaidError.timerNotPaused }
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
  public func resumeTimer(id: String) async throws -> ComRaidTimer {
    let currentStore = try configuredStore()
    let state = currentStore.read()
    guard var timer = state.timers.first(where: { $0.id == id }) else { throw ComRaidError.timerNotFound }
    guard timer.state == .paused else { throw ComRaidError.timerNotPaused }
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

  public func timers() throws -> [ComRaidTimer] {
    try configuredStore().read().timers
  }

  private func addSystemRequest(_ request: ComRaidScheduleRequest) async throws {
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

  private func updateTimer(_ timer: ComRaidTimer) throws {
    let currentStore = try configuredStore()
    var state = currentStore.read()
    state.timers.removeAll { $0.id == timer.id }
    state.timers.append(timer)
    try currentStore.write(state)
  }

  private func validate(_ request: ComRaidScheduleRequest) throws {
    guard !request.notification.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ComRaidError.invalidIdentifier
    }
    guard request.triggerDate.timeIntervalSince1970.isFinite, request.triggerDate.timeIntervalSinceNow > 0 else { throw ComRaidError.triggerMustBeInFuture }
  }

  private func configuredStore() throws -> ComRaidStore {
    guard let store else { throw ComRaidError.notConfigured }
    return store
  }

  private func requireConfigured() throws -> ComRaidConfiguration {
    guard let configuration else { throw ComRaidError.notConfigured }
    return configuration
  }

  private func requireAPI() throws -> MobileApiClient {
    guard let api else { throw ComRaidError.notConfigured }
    return api
  }

  private func requireTokenProvider() throws -> any TokenProvider {
    guard let tokenProvider else { throw ComRaidError.notConfigured }
    return tokenProvider
  }

  private func requireSubscriptionStore() throws -> any SubscriptionCredentialStore {
    guard let subscriptionStore else { throw ComRaidError.notConfigured }
    return subscriptionStore
  }

  private func requireSubscription() throws -> (String, String) {
    let store = try requireSubscriptionStore()
    guard let subscriptionId = store.subscriptionId, !subscriptionId.isEmpty,
          let credential = store.credential, !credential.isEmpty else {
      throw ComRaidError.notReady
    }
    return (subscriptionId, credential)
  }
}

private final class InMemoryAckQueueStoreForTests: AckQueueStore, @unchecked Sendable {
  private let lock = NSLock()
  private var map: [String: String] = [:]

  func get(_ key: String) -> String? {
    lock.withLock { map[key] }
  }

  func set(_ key: String, value: String) {
    lock.withLock { map[key] = value }
  }
}
