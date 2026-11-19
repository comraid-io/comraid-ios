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
  /// Tracks Live activities the host app started (see `trackActivity`).
  var activityTracker: ActivityTracker?
  private var deviceProperties: DeviceProperties?
  private var externalUserId: String?
  private var deviceInfoProvider: DeviceInfoProvider = { SystemDeviceInfo.collect() }
  private var sessionTracker = SessionTracker()
  private var lifecycleObserversInstalled = false
  /// Nil until first use so unit tests that only exercise the identity HTTP seam
  /// never touch `UNUserNotificationCenter.current()` (crashes under SwiftPM's helper).
  private var injectedNotificationCenter: UNUserNotificationCenter?
  /// Injectable Local notification arm/cancel (defaults to `UNUserNotificationCenter`).
  private var localNotificationScheduler: (any LocalNotificationScheduling)?
  /// Injectable clock for schedule / timer remaining calculations (tests).
  private var clock: @Sendable () -> Date = { Date() }
  /// Flushes queued ACKs on app foreground (NSE / background helpers flush separately).
  private var foregroundFlushObserver: NSObjectProtocol?
  /// Set when `register` times out waiting for APNs; cleared on success or late auto-register.
  private var pendingRegisterAfterToken = false
  /// In-app messages. The registrations below live here, not on the manager, so they apply even when
  /// the host sets a presenter, listener or trigger before `configure`, and survive re-configuring.
  private var inApp: InAppMessageManager?
  private var inAppPresenter: InAppMessagePresenter?
  private var inAppPaused = false
  private var inAppListeners: [ComRaidListenerToken: any InAppMessageListener] = [:]
  private var inAppTriggers: [String: String] = [:]
  /// True until the first foreground after launch or after the app went to the background, so a
  /// brief active/inactive blip (a system alert) does not refetch.
  private var needsInAppForegroundFetch = true
  /// The latest In-app fetch, run apart from the session recording so a slow network never delays it.
  private var inAppFetchTask: Task<Void, Never>?

  public init(notificationCenter: UNUserNotificationCenter? = nil) {
    self.injectedNotificationCenter = notificationCenter
  }

  private var notificationCenter: UNUserNotificationCenter {
    if let injectedNotificationCenter { return injectedNotificationCenter }
    let center = UNUserNotificationCenter.current()
    injectedNotificationCenter = center
    return center
  }

  private func requireLocalNotificationScheduler() -> any LocalNotificationScheduling {
    if let localNotificationScheduler { return localNotificationScheduler }
    let scheduler = SystemLocalNotificationScheduler(center: notificationCenter, clock: clock)
    localNotificationScheduler = scheduler
    return scheduler
  }

  public func configure(_ configuration: ComRaidConfiguration) throws {
    let trimmedAppId = configuration.appId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedAppId.isEmpty else {
      throw ComRaidError.invalidConfiguration("appId is required (cr_app_…)")
    }
    self.configuration = configuration
    store = ComRaidStore(suiteName: configuration.storageSuiteName)
    let credentials = KeychainSubscriptionStore(suiteName: configuration.storageSuiteName)
    subscriptionStore = credentials
    let apns = StoredAPNsTokenProvider()
    apnsTokenProvider = apns
    tokenProvider = apns
    let transport = URLSessionHttpTransport(apiBaseURL: configuration.apiBaseURL)
    api = MobileApiClient(
      appId: trimmedAppId,
      apnsEnvironment: configuration.apnsEnvironment,
      transport: transport
    )
    let queue = AckQueue(
      apiBaseURL: configuration.apiBaseURL,
      store: UserDefaultsAckQueueStore(suiteName: configuration.storageSuiteName),
      transport: transport
    )
    ackQueue = queue
    replaceActivityTracker(api: api!, retryDelays: ActivityTracker.defaultRetryDelays)
    deviceProperties = nil
    externalUserId = credentials.externalUserId
    pendingRegisterAfterToken = false
    deviceInfoProvider = { SystemDeviceInfo.collect() }
    sessionTracker = SessionTracker()
    needsInAppForegroundFetch = true
    #if canImport(UIKit)
    inApp = makeInAppManager(
      api: api!,
      store: credentials,
      queue: queue,
      stateStore: UserDefaultsAckQueueStore(suiteName: configuration.storageSuiteName),
      stateKey: inAppStateKey(apiBaseURL: configuration.apiBaseURL, appId: trimmedAppId),
      clock: { Date() },
      display: UIKitInAppDisplay(),
      flush: { await queue.flush() }
    )
    #endif
    SdkConfigStore(suiteName: configuration.storageSuiteName).save(configuration)
    installForegroundFlushObserver()
    installLifecycleObserversIfNeeded()
    Task { await queue.flush() }
  }

  /// Test seam: injectable HTTP transport, token provider, subscription store, ACK store,
  /// Local notification scheduler, device info, session clock, and schedule clock.
  func configureForTests(
    _ configuration: ComRaidConfiguration,
    transport: any HttpTransport,
    tokenProvider: any TokenProvider,
    subscriptionStore: any SubscriptionCredentialStore,
    ackQueueStore: (any AckQueueStore)? = nil,
    localNotificationScheduler: (any LocalNotificationScheduling)? = nil,
    deviceInfoProvider: @escaping DeviceInfoProvider = { DeviceProperties() },
    clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
    scheduleClock: (@Sendable () -> Date)? = nil,
    inAppDisplay: (any InAppDisplay)? = nil,
    activityRetryDelays: [TimeInterval] = []
  ) throws {
    let trimmedAppId = configuration.appId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedAppId.isEmpty else {
      throw ComRaidError.invalidConfiguration("appId is required (cr_app_…)")
    }
    self.configuration = configuration
    store = ComRaidStore(suiteName: configuration.storageSuiteName)
    self.subscriptionStore = subscriptionStore
    self.tokenProvider = tokenProvider
    apnsTokenProvider = tokenProvider as? StoredAPNsTokenProvider
    api = MobileApiClient(
      appId: trimmedAppId,
      apnsEnvironment: configuration.apnsEnvironment,
      transport: transport
    )
    ackQueue = AckQueue(
      apiBaseURL: configuration.apiBaseURL,
      store: ackQueueStore ?? InMemoryAckQueueStoreForTests(),
      transport: transport
    )
    self.localNotificationScheduler = localNotificationScheduler
    replaceActivityTracker(api: api!, retryDelays: activityRetryDelays)
    if let scheduleClock { self.clock = scheduleClock }
    deviceProperties = nil
    externalUserId = subscriptionStore.externalUserId
    pendingRegisterAfterToken = false
    self.deviceInfoProvider = deviceInfoProvider
    sessionTracker = SessionTracker(clock: clock)
    needsInAppForegroundFetch = true
    if let queue = ackQueue, let apiClient = api {
      // Tests run with a fake display (or none), keep In-app state in memory, and flush ACKs explicitly.
      inApp = makeInAppManager(
        api: apiClient,
        store: subscriptionStore,
        queue: queue,
        stateStore: InMemoryAckQueueStoreForTests(),
        stateKey: inAppStateKey(apiBaseURL: configuration.apiBaseURL, appId: trimmedAppId),
        clock: { Date() },
        display: inAppDisplay ?? NoWindowInAppDisplay(),
        flush: {}
      )
    }
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
    if let old = activityTracker { Task { await old.cancelAll() } }
    activityTracker = nil
    localNotificationScheduler = nil
    clock = { Date() }
    deviceProperties = nil
    externalUserId = nil
    pendingRegisterAfterToken = false
    deviceInfoProvider = { SystemDeviceInfo.collect() }
    sessionTracker = SessionTracker()
    lifecycleObserversInstalled = false
    inApp = nil
    inAppFetchTask = nil
    inAppPresenter = nil
    inAppPaused = false
    inAppListeners = [:]
    inAppTriggers = [:]
    needsInAppForegroundFetch = true
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

  /// Test seam: simulate process foreground without UIKit notifications.
  func handleAppForegroundForTests() async {
    await onAppForeground()
    await inAppFetchTask?.value
  }

  /// Test seam: like `handleAppForegroundForTests`, but returns without waiting for the In-app fetch.
  func handleAppForegroundWithoutSettlingForTests() async {
    await onAppForeground()
  }

  /// Test seam: wait for the In-app fetch started by the last foreground, login, register or opt-in.
  func settleInAppForTests() async {
    await inAppFetchTask?.value
  }

  /// Test seam: simulate process background without UIKit notifications.
  func handleAppBackgroundForTests() {
    handleDidEnterBackground()
  }

  /// Forward the APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
  /// When a Subscription credential already exists, calls `/token` automatically.
  /// When a prior `register` timed out waiting for this token, registers automatically.
  public func setAPNsDeviceToken(_ tokenData: Data) async {
    await apnsTokenProvider?.setDeviceToken(tokenData)
    if let hex = try? await apnsTokenProvider?.currentToken() {
      RemoteReceiveHub.shared.notifyTokenRefresh(hex)
    }
    if pendingRegisterAfterToken {
      pendingRegisterAfterToken = false
      try? await register(tokenWaitTimeout: 0)
      return
    }
    if let store = subscriptionStore,
       let subscriptionId = store.subscriptionId, !subscriptionId.isEmpty,
       let credential = store.credential, !credential.isEmpty {
      try? await onPushTokenRefresh()
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
    // Completion-handler API keeps UNUserNotificationCenter on this actor; the async
    // overload is nonisolated and trips Swift 6 "sending" checks.
    let granted = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Bool, Error>) in
      notificationCenter.requestAuthorization(options: options) { granted, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: granted)
        }
      }
    }
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
  /// When no APNs token is stored yet, waits up to `tokenWaitTimeout` (default 10 s).
  /// On timeout throws `tokenTimeout` and registers automatically when the token later arrives.
  public func register(tokenWaitTimeout: TimeInterval = 10) async throws {
    let api = try requireAPI()
    let tokens = try requireTokenProvider()
    let store = try requireSubscriptionStore()
    let token: String
    if let apns = apnsTokenProvider {
      do {
        token = try await apns.waitForToken(timeout: tokenWaitTimeout)
      } catch ComRaidError.tokenTimeout {
        pendingRegisterAfterToken = true
        throw ComRaidError.tokenTimeout
      }
    } else {
      token = try await tokens.currentToken()
    }
    pendingRegisterAfterToken = false
    let result = try await api.register(
      token: token,
      properties: resolvedProperties(),
      subscriptionCredential: store.credential
    )
    store.save(subscriptionId: result.subscriptionId, credential: result.credential)
    sessionTracker.markSessionRecorded()
    // A fresh install has no Subscription at launch, so its foreground fetch could not run: do it now.
    needsInAppForegroundFetch = false
    startInAppFetch()
    await activityTracker?.scheduleFlush()
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
        properties: resolvedProperties()
      )
    } else {
      let result = try await api.register(
        token: token,
        properties: resolvedProperties(),
        subscriptionCredential: nil
      )
      store.save(subscriptionId: result.subscriptionId, credential: result.credential)
      needsInAppForegroundFetch = false
      startInAppFetch()
      sessionTracker.markSessionRecorded()
    }
  }

  public func login(externalUserId: String, jwt: String? = nil) async throws {
    let api = try requireAPI()
    let store = try requireSubscriptionStore()
    let (subscriptionId, credential) = try requireSubscription()
    let trimmed = externalUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ComRaidError.invalidIdentifier }
    let previousExternalUserId = self.externalUserId
    try await api.login(
      subscriptionId: subscriptionId,
      credential: credential,
      externalUserId: trimmed,
      jwt: jwt
    )
    store.setExternalUserId(trimmed)
    self.externalUserId = trimmed
    // The Contact may change (an anonymous one merging into a known one): let the server decide again.
    // Logging in again as the same user changes nothing, so what was shown stays recorded.
    if previousExternalUserId != trimmed {
      await inApp?.reset()
      startInAppFetch()
    }
    await activityTracker?.scheduleFlush()
  }

  public func logout() async throws {
    let api = try requireAPI()
    let store = try requireSubscriptionStore()
    let (subscriptionId, credential) = try requireSubscription()
    try await api.logout(subscriptionId: subscriptionId, credential: credential)
    store.clear()
    externalUserId = nil
    // The next user must not see, or acknowledge, the previous user's messages.
    await inApp?.reset()
    try await register()
  }

  /**
   Override automatically collected Properties for subsequent register / token /
   session calls. Nil fields keep the auto-collected value.
   */
  public func setDeviceProperties(_ properties: DeviceProperties) {
    _ = try? requireConfigured()
    deviceProperties = properties
  }

  /**
   Upsert Contact Attributes for the logged-in Contact
   (`PUT /mobile/subscriptions/{id}/attributes`).
   Pass `NSNull()` for a key to remove that Attribute.
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
      await BackgroundAckHelpers.handleReceived(
        data: data,
        storageSuiteName: configuration?.storageSuiteName
      )
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
      await BackgroundAckHelpers.handleOpened(
        data: data,
        actionId: resolvedAction,
        storageSuiteName: configuration?.storageSuiteName
      )
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

  // MARK: In-app messages

  /// Opt this Contact out of In-app messages (the `in_app` channel, independent of push).
  /// Cached messages stop showing immediately.
  public func optOutInApp() async throws {
    let api = try requireAPI()
    let (subscriptionId, credential) = try requireSubscription()
    try await api.optOut(subscriptionId: subscriptionId, credential: credential, channel: "in_app")
    await inApp?.clearLocalState()
  }

  /// Opt this Contact back in to In-app messages.
  public func optInInApp() async throws {
    let api = try requireAPI()
    let (subscriptionId, credential) = try requireSubscription()
    try await api.optIn(subscriptionId: subscriptionId, credential: credential, channel: "in_app")
    startInAppFetch() // messages the Contact was held back from may be eligible again
  }

  /// Draw In-app messages yourself. While a presenter is set the SDK draws nothing: you receive the
  /// message and a handle, and report `impression()`, `clicked(buttonId:)` and `dismissed()`.
  /// Pass nil to go back to the SDK's layouts. May be called before `configure`.
  public func setInAppMessagePresenter(_ presenter: InAppMessagePresenter?) async {
    inAppPresenter = presenter
    await inApp?.setPresenter(presenter)
  }

  /// Observe In-app messages being displayed, clicked and dismissed.
  public func addInAppMessageListener(_ listener: any InAppMessageListener) async -> ComRaidListenerToken {
    let token = ComRaidListenerToken()
    inAppListeners[token] = listener
    _ = await inApp?.addListener(listener, token: token)
    return token
  }

  public func removeInAppMessageListener(_ token: ComRaidListenerToken) async {
    inAppListeners[token] = nil
    await inApp?.removeListener(token)
  }

  /// Set a local trigger. Triggers stay on the device and are passed to your presenter; they do not
  /// decide which message shows.
  public func addTrigger(key: String, value: String) async {
    inAppTriggers[key] = value
    await inApp?.addTrigger(key: key, value: value)
  }

  public func addTriggers(_ triggers: [String: String]) async {
    inAppTriggers.merge(triggers) { _, new in new }
    await inApp?.addTriggers(triggers)
  }

  public func removeTrigger(key: String) async {
    inAppTriggers[key] = nil
    await inApp?.removeTrigger(key: key)
  }

  public func clearTriggers() async {
    inAppTriggers.removeAll()
    await inApp?.clearTriggers()
  }

  public func getTriggers() -> [String: String] { inAppTriggers }

  /// Pause or resume showing In-app messages on this device. Messages wait while paused.
  public func setInAppMessagesPaused(_ paused: Bool) async {
    inAppPaused = paused
    await inApp?.setPaused(paused)
  }

  public func isInAppMessagesPaused() -> Bool { inAppPaused }

  private func makeInAppManager(
    api: MobileApiClient,
    store: any SubscriptionCredentialStore,
    queue: AckQueue,
    stateStore: any AckQueueStore,
    stateKey: String,
    clock: @escaping @Sendable () -> Date,
    display: any InAppDisplay,
    flush: @escaping @Sendable () async -> Void
  ) -> InAppMessageManager {
    InAppMessageManager(
      fetcher: {
        guard let id = store.subscriptionId, !id.isEmpty, let credential = store.credential, !credential.isEmpty else {
          throw ComRaidError.notReady
        }
        return try await api.listInAppMessages(subscriptionId: id, credential: credential)
      },
      acks: AckQueueInAppSink(
        queue: queue,
        clock: { Int64(Date().timeIntervalSince1970 * 1000) },
        flush: flush
      ),
      store: stateStore,
      stateKey: stateKey,
      clock: clock,
      display: display,
      presenter: inAppPresenter,
      paused: inAppPaused,
      listeners: inAppListeners,
      triggers: inAppTriggers
    )
  }

  public func capabilities() async -> ComRaidCapabilities {
    // Extract Sendable fields in the notification-center callback so UNNotificationSettings
    // (non-Sendable) never crosses isolation under Swift 6.
    let (authorizationStatus, alertSetting) = await withCheckedContinuation {
      (continuation: CheckedContinuation<(UNAuthorizationStatus, UNNotificationSetting), Never>) in
      notificationCenter.getNotificationSettings { settings in
        continuation.resume(returning: (settings.authorizationStatus, settings.alertSetting))
      }
    }
    let status: ComRaidAuthorizationStatus = switch authorizationStatus {
    case .notDetermined: .notDetermined
    case .denied: .denied
    case .authorized: .authorized
    case .provisional: .provisional
    case .ephemeral: .ephemeral
    @unknown default: .unknown
    }
    let enabled = alertSetting == .enabled || authorizationStatus == .provisional
    return ComRaidCapabilities(authorizationStatus: status, notificationsEnabled: enabled)
  }

  public func schedule(_ request: ComRaidScheduleRequest) async throws {
    let currentStore = try configuredStore()
    let scheduler = requireLocalNotificationScheduler()
    try validate(request)
    try await scheduler.schedule(request)

    var state = currentStore.read()
    state.schedules.removeAll { $0.notification.id == request.notification.id }
    state.schedules.append(request)
    do {
      try currentStore.write(state)
    } catch {
      scheduler.cancel(id: request.notification.id)
      throw ComRaidError.persistenceFailed
    }
  }

  public func pendingSchedules() throws -> [ComRaidScheduleRequest] {
    let now = clock()
    return try configuredStore().read().schedules.filter { $0.triggerDate > now }.sorted { $0.triggerDate < $1.triggerDate }
  }

  public func cancel(id: String) throws {
    let currentStore = try configuredStore()
    requireLocalNotificationScheduler().cancel(id: id)
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
    let targetDate = clock().addingTimeInterval(duration)
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
    timer.remainingDuration = max(0, targetDate.timeIntervalSince(clock()))
    timer.targetDate = nil
    timer.state = .paused
    state.timers[index] = timer
    state.schedules.removeAll { $0.notification.id == id }
    requireLocalNotificationScheduler().cancel(id: id)
    try currentStore.write(state)
    return timer
  }

  @discardableResult
  public func resumeTimer(id: String) async throws -> ComRaidTimer {
    let currentStore = try configuredStore()
    let state = currentStore.read()
    guard var timer = state.timers.first(where: { $0.id == id }) else { throw ComRaidError.timerNotFound }
    guard timer.state == .paused else { throw ComRaidError.timerNotPaused }
    let targetDate = clock().addingTimeInterval(max(timer.remainingDuration, 0.1))
    timer.state = .running
    timer.targetDate = targetDate
    try await schedule(.init(notification: timer.notification, triggerDate: targetDate))
    try updateTimer(timer)
    return timer
  }

  public func cancelTimer(id: String) throws {
    let currentStore = try configuredStore()
    requireLocalNotificationScheduler().cancel(id: id)
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
    guard request.triggerDate.timeIntervalSince1970.isFinite, request.triggerDate > clock() else {
      throw ComRaidError.triggerMustBeInFuture
    }
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

  /// The Subscription to report under, or nil while the SDK is not registered or the Contact is not
  /// logged in: the server refuses activity tokens from anonymous Subscriptions.
  func activityReadiness() -> ActivityReadiness? {
    guard let store = subscriptionStore,
          let subscriptionId = store.subscriptionId, !subscriptionId.isEmpty,
          let credential = store.credential, !credential.isEmpty,
          let externalUserId, !externalUserId.isEmpty
    else { return nil }
    return ActivityReadiness(subscriptionId: subscriptionId, credential: credential)
  }

  private func requireSubscription() throws -> (String, String) {
    let store = try requireSubscriptionStore()
    guard let subscriptionId = store.subscriptionId, !subscriptionId.isEmpty,
          let credential = store.credential, !credential.isEmpty else {
      throw ComRaidError.notReady
    }
    return (subscriptionId, credential)
  }

  private func resolvedProperties() -> DeviceProperties {
    mergeDeviceProperties(auto: deviceInfoProvider(), override: deviceProperties)
  }

  private func installLifecycleObserversIfNeeded() {
    guard !lifecycleObserversInstalled else { return }
    lifecycleObserversInstalled = true
    #if canImport(UIKit) && !os(watchOS)
    let center = NotificationCenter.default
    center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Task { await self.handleDidEnterBackground() }
    }
    // didBecomeActive covers cold start and return-from-background; SessionTracker debounces.
    center.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Task { await self.onAppForeground() }
    }
    #endif
  }

  private func hasRegisteredSubscription() -> Bool {
    guard let store = subscriptionStore,
          let id = store.subscriptionId, !id.isEmpty,
          let credential = store.credential, !credential.isEmpty else { return false }
    return true
  }

  /// Fetch and show In-app messages without making the caller wait for the network.
  private func startInAppFetch() {
    guard let manager = inApp else { return }
    inAppFetchTask = Task { await manager.onForeground() }
  }

  private func handleDidEnterBackground() {
    sessionTracker.onBackground()
    needsInAppForegroundFetch = true
  }

  private func onAppForeground() async {
    await activityTracker?.scheduleFlush()
    // In-app messages are fetched on every real foreground, independent of the session debounce below,
    // and in their own task so a slow network never delays recording the session.
    if needsInAppForegroundFetch {
      // Without a Subscription there is nothing to fetch yet: keep the flag so the next active
      // moment, or the registration itself, does it instead of losing this foreground.
      if hasRegisteredSubscription() {
        needsInAppForegroundFetch = false
        startInAppFetch()
      }
    } else {
      await inApp?.onHostReady() // active again: a message that was waiting for a window can show now
    }
    guard sessionTracker.shouldRecordSession() else { return }
    guard let api,
          let store = subscriptionStore,
          let subscriptionId = store.subscriptionId, !subscriptionId.isEmpty,
          let credential = store.credential, !credential.isEmpty else {
      return
    }
    do {
      try await api.session(
        subscriptionId: subscriptionId,
        credential: credential,
        properties: resolvedProperties()
      )
      sessionTracker.markSessionRecorded()
    } catch {
      // Best-effort; next eligible foreground retries.
    }
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

/// A display with no window: messages wait. Used by tests that do not inject a display.
@MainActor
private final class NoWindowInAppDisplay: InAppDisplay {
  func isAvailable() -> Bool { false }
  func show(_ message: InAppMessage, handle: any InAppMessageHandle) -> Bool { false }
}
