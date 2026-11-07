import Foundation
import UserNotifications

@objc(ComraidBridge)
public final class ComRaidObjCBridge: NSObject, @unchecked Sendable {
  @objc public static let shared = ComRaidObjCBridge()

  private override init() {}

  private var eventEmitter: (@Sendable (String, NSDictionary) -> Void)?
  private var foregroundToken: ComRaidListenerToken?
  private var backgroundToken: ComRaidListenerToken?
  private var openedToken: ComRaidListenerToken?
  private var tokenRefreshToken: ComRaidListenerToken?
  private let listenerLock = NSLock()

  @objc public func configure(
    appId: String,
    apiBaseURL: String?,
    apnsEnvironment: String,
    storageSuiteName: String?,
    displayForegroundNotifications: Bool,
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    let configuredSuite = storageSuiteName?.isEmpty == false
      ? storageSuiteName
      : (Bundle.main.object(forInfoDictionaryKey: "ComRaidStorageSuiteName") as? String)
    let env: APNsEnvironment
    switch apnsEnvironment {
    case "sandbox": env = .sandbox
    case "production": env = .production
    default:
      completion(NSError(
        domain: "ComRaid",
        code: 1004,
        userInfo: [NSLocalizedDescriptionKey: "apnsEnvironment must be sandbox or production"]
      ))
      return
    }
    let baseURL = apiBaseURL.flatMap { URL(string: $0) } ?? URL(string: "https://api.comraid.io")!
    Task {
      do {
        try await ComRaid.shared.configure(
          .init(
            appId: appId,
            apiBaseURL: baseURL,
            apnsEnvironment: env,
            storageSuiteName: configuredSuite,
            displayForegroundNotifications: displayForegroundNotifications
          )
        )
        self.attachReceiveListenersIfNeeded()
        completion(nil)
      } catch {
        completion(error as NSError)
      }
    }
  }

  /// Backward-compatible configure (foreground display defaults to true).
  @objc public func configure(
    appId: String,
    apiBaseURL: String?,
    apnsEnvironment: String,
    storageSuiteName: String?,
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    configure(
      appId: appId,
      apiBaseURL: apiBaseURL,
      apnsEnvironment: apnsEnvironment,
      storageSuiteName: storageSuiteName,
      displayForegroundNotifications: true,
      completion: completion
    )
  }

  /**
   RN / ObjC hosts set this to receive `comraid_message`, `comraid_background_message`,
   `comraid_notification_opened`, and `comraid_token_refresh` payloads.
   */
  @objc public func setEventEmitter(_ emitter: (@Sendable (String, NSDictionary) -> Void)?) {
    listenerLock.withLock { eventEmitter = emitter }
    if emitter != nil {
      attachReceiveListenersIfNeeded()
    }
  }

  @objc public func getToken(
    completion: @escaping @Sendable (String?, NSError?) -> Void
  ) {
    Task {
      do {
        completion(try await ComRaid.shared.getToken(), nil)
      } catch {
        completion(nil, error as NSError)
      }
    }
  }

  @objc public func getInitialNotification(
    completion: @escaping @Sendable (NSDictionary?, NSError?) -> Void
  ) {
    Task {
      let event = await ComRaid.shared.getInitialNotification()
      completion(event.map { Self.remoteMessageDictionary($0) }, nil)
    }
  }

  @objc public func presentNotification(
    messageJson: String,
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    Task {
      do {
        let event = try Self.parseRemoteMessage(messageJson)
        try await ComRaid.shared.presentNotification(event)
        completion(nil)
      } catch {
        completion(error as NSError)
      }
    }
  }

  /// Notification Service Extension helper; see `RemoteNotificationDisplay.enrich(_:)`.
  @objc public func enrichNotificationRequest(
    _ request: UNNotificationRequest,
    completion: @escaping @Sendable (UNNotificationContent) -> Void
  ) {
    // UNNotificationRequest is immutable but not marked Sendable.
    nonisolated(unsafe) let request = request
    Task {
      completion(await RemoteNotificationDisplay.enrich(request))
    }
  }

  @objc public func setBackgroundHandlerRegistered(
    _ registered: Bool,
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    Task {
      await ComRaid.shared.setBackgroundHandlerRegistered(registered)
      completion(nil)
    }
  }

  @objc public func handleRemoteNotification(
    userInfo: NSDictionary,
    appInForeground: Bool,
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    let data = PushPayload.fromUserInfo(Self.anyHashableDictionary(userInfo))
    Task {
      await ComRaid.shared.handleRemoteNotification(data: data, appInForeground: appInForeground)
      completion(nil)
    }
  }

  @objc public func presentationOptions(
    forUserInfo userInfo: NSDictionary,
    completion: @escaping @Sendable (UInt, NSError?) -> Void
  ) {
    let data = PushPayload.fromUserInfo(Self.anyHashableDictionary(userInfo))
    Task {
      let options = await ComRaid.shared.presentationOptions(forData: data)
      completion(options.rawValue, nil)
    }
  }

  @objc public func handleNotificationResponse(
    userInfo: NSDictionary,
    actionIdentifier: String,
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    let data = PushPayload.fromUserInfo(Self.anyHashableDictionary(userInfo))
    let actionId: String? = {
      switch actionIdentifier {
      case UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier:
        return nil
      default:
        return actionIdentifier.isEmpty ? nil : actionIdentifier
      }
    }()
    Task {
      await ComRaid.shared.handleNotificationOpen(data: data, actionId: actionId)
      completion(nil)
    }
  }

  private func attachReceiveListenersIfNeeded() {
    listenerLock.withLock {
      if foregroundToken == nil {
        foregroundToken = RemoteReceiveHub.shared.addForegroundMessageListener { [weak self] event in
          self?.emit("comraid_message", Self.remoteMessageDictionary(event))
        }
      }
      if backgroundToken == nil {
        backgroundToken = RemoteReceiveHub.shared.addBackgroundMessageListener { [weak self] event in
          self?.emit("comraid_background_message", Self.remoteMessageDictionary(event))
        }
      }
      if openedToken == nil {
        openedToken = RemoteReceiveHub.shared.addNotificationOpenedListener { [weak self] event in
          self?.emit("comraid_notification_opened", Self.remoteMessageDictionary(event))
        }
      }
      if tokenRefreshToken == nil {
        tokenRefreshToken = RemoteReceiveHub.shared.addTokenRefreshListener { [weak self] token in
          self?.emit("comraid_token_refresh", ["token": token])
        }
      }
    }
  }

  private func emit(_ name: String, _ payload: NSDictionary) {
    let emitter = listenerLock.withLock { eventEmitter }
    emitter?(name, payload)
  }

  private static func anyHashableDictionary(_ value: NSDictionary) -> [AnyHashable: Any] {
    var out: [AnyHashable: Any] = [:]
    for (key, obj) in value {
      guard let hashable = key as? AnyHashable else { continue }
      out[hashable] = obj
    }
    return out
  }

  private static func remoteMessageDictionary(_ event: RemoteMessageEvent) -> NSDictionary {
    let result = NSMutableDictionary()
    if let messageId = event.messageId { result["messageId"] = messageId }
    if let deliveryId = event.deliveryId { result["deliveryId"] = deliveryId }
    if let attributionToken = event.attributionToken { result["attributionToken"] = attributionToken }
    if let title = event.title { result["title"] = title }
    if let body = event.body { result["body"] = body }
    if let deepLink = event.deepLink { result["deepLink"] = deepLink }
    if let actionId = event.actionId { result["actionId"] = actionId }
    if let imageUrl = event.imageUrl { result["imageUrl"] = imageUrl }
    if let subtitle = event.subtitle { result["subtitle"] = subtitle }
    if let sound = event.sound { result["sound"] = sound }
    if let badge = event.badge { result["badge"] = badge }
    if let threadId = event.threadId { result["threadId"] = threadId }
    if let androidChannelId = event.androidChannelId {
      result["androidChannelId"] = androidChannelId
    }
    result["priority"] = event.priority
    result["data"] = event.data as NSDictionary
    if !event.actions.isEmpty {
      result["actions"] = event.actions.map { action -> NSDictionary in
        let obj = NSMutableDictionary()
        obj["id"] = action.id
        obj["text"] = action.text
        if let icon = action.icon { obj["icon"] = icon }
        return obj
      } as NSArray
    }
    return result
  }

  private static func parseRemoteMessage(_ messageJson: String) throws -> RemoteMessageEvent {
    guard let raw = messageJson.data(using: .utf8),
          let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
      throw NSError(
        domain: "ComRaid",
        code: 2001,
        userInfo: [NSLocalizedDescriptionKey: "presentNotification message must be a JSON object"]
      )
    }
    let dataObj = json["data"] as? [String: Any] ?? [:]
    var data: [String: String] = [:]
    for (key, value) in dataObj {
      if let string = value as? String {
        data[key] = string
      } else if let number = value as? NSNumber {
        data[key] = number.stringValue
      }
    }
    var actions: [RemoteMessageAction] = []
    if let actionsJson = json["actions"] as? [[String: Any]] {
      for obj in actionsJson {
        let id = (obj["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, !text.isEmpty else { continue }
        let icon = (obj["icon"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        actions.append(RemoteMessageAction(
          id: id,
          text: text,
          icon: (icon?.isEmpty == false) ? icon : nil
        ))
      }
    }
    func string(_ key: String) -> String? {
      (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    return RemoteMessageEvent(
      messageId: string("messageId"),
      deliveryId: string("deliveryId"),
      attributionToken: string("attributionToken"),
      title: string("title"),
      body: string("body"),
      data: data,
      deepLink: string("deepLink"),
      actions: actions,
      actionId: string("actionId"),
      imageUrl: string("imageUrl"),
      subtitle: string("subtitle"),
      sound: string("sound"),
      badge: (json["badge"] as? NSNumber).map(\.intValue).flatMap { $0 >= 0 ? $0 : nil },
      threadId: string("threadId"),
      androidChannelId: string("androidChannelId"),
      priority: string("priority") ?? "high"
    )
  }

  @objc public func setAPNsDeviceToken(
    _ tokenData: Data,
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    Task {
      await ComRaid.shared.setAPNsDeviceToken(tokenData)
      completion(nil)
    }
  }

  @objc public func onPushTokenRefresh(
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    Task {
      do {
        try await ComRaid.shared.onPushTokenRefresh()
        completion(nil)
      } catch {
        completion(error as NSError)
      }
    }
  }

  @objc public func register(completion: @escaping @Sendable (NSError?) -> Void) {
    Task {
      do {
        try await ComRaid.shared.register()
        completion(nil)
      } catch {
        completion(error as NSError)
      }
    }
  }

  @objc public func login(
    externalUserId: String,
    jwt: String?,
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    Task {
      do {
        try await ComRaid.shared.login(
          externalUserId: externalUserId,
          jwt: jwt?.isEmpty == false ? jwt : nil
        )
        completion(nil)
      } catch {
        completion(error as NSError)
      }
    }
  }

  @objc public func logout(completion: @escaping @Sendable (NSError?) -> Void) {
    Task {
      do {
        try await ComRaid.shared.logout()
        completion(nil)
      } catch {
        completion(error as NSError)
      }
    }
  }

  @objc public func optOut(completion: @escaping @Sendable (NSError?) -> Void) {
    Task {
      do {
        try await ComRaid.shared.optOut()
        completion(nil)
      } catch {
        completion(error as NSError)
      }
    }
  }

  @objc public func optIn(completion: @escaping @Sendable (NSError?) -> Void) {
    Task {
      do {
        try await ComRaid.shared.optIn()
        completion(nil)
      } catch {
        completion(error as NSError)
      }
    }
  }

  @objc public func capabilities(
    completion: @escaping @Sendable (NSDictionary?, NSError?) -> Void
  ) {
    Task {
      let value = await ComRaid.shared.capabilities()
      completion([
        "platform": "ios",
        "notificationsEnabled": value.notificationsEnabled,
        "authorizationStatus": value.authorizationStatus.rawValue,
        "exactAlarmsAvailable": false,
      ], nil)
    }
  }

  @available(iOSApplicationExtension, unavailable)
  @objc public func requestNotificationPermission(
    completion: @escaping @Sendable (Bool, NSError?) -> Void
  ) {
    requestNotificationPermission(options: ["alert", "badge", "sound"], completion: completion)
  }

  /**
   Requests notification permission with explicit options.
   Recognized option strings: `alert`, `badge`, `sound`, `provisional`, `carPlay`,
   `criticalAlert`, `providesAppNotificationSettings`, `announcement`.
   */
  @available(iOSApplicationExtension, unavailable)
  @objc public func requestNotificationPermission(
    options: [String],
    completion: @escaping @Sendable (Bool, NSError?) -> Void
  ) {
    let authorizationOptions = Self.authorizationOptions(options)
    Task {
      do {
        completion(try await ComRaid.shared.requestPermission(options: authorizationOptions), nil)
      } catch {
        completion(false, error as NSError)
      }
    }
  }

  @objc public func schedule(
    id: String,
    title: String,
    body: String,
    triggerAtMillis: Double,
    requestedPrecision: String,
    fallbackPolicy: String,
    userInfo: NSDictionary,
    completion: @escaping @Sendable (NSDictionary?, NSError?) -> Void
  ) {
    let safeUserInfo = stringDictionary(userInfo)
    Task {
      do {
        let fallbackReason = try precisionFallback(
          requestedPrecision: requestedPrecision,
          fallbackPolicy: fallbackPolicy
        )
        let notification = ComRaidNotification(
          id: id,
          title: title,
          body: body,
          userInfo: safeUserInfo
        )
        let date = Date(timeIntervalSince1970: triggerAtMillis / 1_000)
        try await ComRaid.shared.schedule(.init(notification: notification, triggerDate: date))
        let result = NSMutableDictionary(dictionary: [
          "id": id,
          "requestedPrecision": requestedPrecision,
          "appliedPrecision": "inexact",
          "triggerAtMillis": triggerAtMillis,
          "fallbackReason": fallbackReason,
        ])
        completion(result, nil)
      } catch {
        completion(nil, error as NSError)
      }
    }
  }

  @objc public func startTimer(
    id: String,
    title: String,
    body: String,
    durationMillis: Double,
    requestedPrecision: String,
    fallbackPolicy: String,
    userInfo: NSDictionary,
    completion: @escaping @Sendable (NSDictionary?, NSError?) -> Void
  ) {
    let safeUserInfo = stringDictionary(userInfo)
    Task {
      do {
        let fallbackReason = try precisionFallback(
          requestedPrecision: requestedPrecision,
          fallbackPolicy: fallbackPolicy
        )
        let timer = try await ComRaid.shared.startTimer(
          id: id,
          duration: durationMillis / 1_000,
          notification: ComRaidNotification(
            id: id,
            title: title,
            body: body,
            userInfo: safeUserInfo
          )
        )
        completion([
          "id": id,
          "requestedPrecision": requestedPrecision,
          "appliedPrecision": "inexact",
          "triggerAtMillis": (timer.targetDate?.timeIntervalSince1970 ?? 0) * 1_000,
          "fallbackReason": fallbackReason,
        ], nil)
      } catch {
        completion(nil, error as NSError)
      }
    }
  }

  @objc public func pauseTimer(
    id: String,
    completion: @escaping @Sendable (NSDictionary?, NSError?) -> Void
  ) {
    Task {
      do {
        completion(Self.timerDictionary(try await ComRaid.shared.pauseTimer(id: id)), nil)
      } catch {
        completion(nil, error as NSError)
      }
    }
  }

  @objc public func resumeTimer(
    id: String,
    completion: @escaping @Sendable (NSDictionary?, NSError?) -> Void
  ) {
    Task {
      do {
        completion(Self.timerDictionary(try await ComRaid.shared.resumeTimer(id: id)), nil)
      } catch {
        completion(nil, error as NSError)
      }
    }
  }

  @objc public func cancelTimer(
    id: String,
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    Task {
      do {
        try await ComRaid.shared.cancelTimer(id: id)
        completion(nil)
      } catch {
        completion(error as NSError)
      }
    }
  }

  @objc public func timers(
    completion: @escaping @Sendable (NSArray?, NSError?) -> Void
  ) {
    Task {
      do {
        let values = try await ComRaid.shared.timers().map(Self.timerDictionary)
        completion(values as NSArray, nil)
      } catch {
        completion(nil, error as NSError)
      }
    }
  }

  @objc public func cancel(
    id: String,
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    Task {
      do {
        try await ComRaid.shared.cancel(id: id)
        completion(nil)
      } catch {
        completion(error as NSError)
      }
    }
  }

  @objc public func pendingSchedules(
    completion: @escaping @Sendable (NSArray?, NSError?) -> Void
  ) {
    Task {
      do {
        let schedules = try await ComRaid.shared.pendingSchedules().map { request in
          [
            "id": request.notification.id,
            "title": request.notification.title,
            "body": request.notification.body,
            "triggerAtMillis": request.triggerDate.timeIntervalSince1970 * 1_000,
          ] as NSDictionary
        }
        completion(schedules as NSArray, nil)
      } catch {
        completion(nil, error as NSError)
      }
    }
  }

  @objc public func setDeviceProperties(
    appVersion: String?,
    model: String?,
    osVersion: String?,
    extras: NSDictionary?,
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    let properties = DeviceProperties(
      appVersion: appVersion?.nilIfEmpty,
      model: model?.nilIfEmpty,
      osVersion: osVersion?.nilIfEmpty,
      extras: stringExtras(extras)
    )
    Task {
      await ComRaid.shared.setDeviceProperties(properties)
      completion(nil)
    }
  }

  @objc public func setAttributes(
    _ attributes: NSDictionary,
    completion: @escaping @Sendable (NSError?) -> Void
  ) {
    guard JSONSerialization.isValidJSONObject(attributes) else {
      completion(NSError(
        domain: "ComRaid",
        code: 2001,
        userInfo: [NSLocalizedDescriptionKey: "attributes must encode a JSON object"]
      ))
      return
    }
    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: attributes)
    } catch {
      completion(error as NSError)
      return
    }
    Task {
      do {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let map = object as? [String: Any] else {
          throw NSError(
            domain: "ComRaid",
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "attributes must encode a JSON object"]
          )
        }
        try await ComRaid.shared.setAttributes(map)
        completion(nil)
      } catch {
        completion(error as NSError)
      }
    }
  }

  @objc public func acknowledgeDelivered(
    deliveryId: String,
    attributionToken: String,
    completion: @escaping @Sendable (Bool, NSError?) -> Void
  ) {
    Task {
      let ok = await ComRaid.shared.acknowledgeDelivered(
        deliveryId: deliveryId,
        attributionToken: attributionToken
      )
      completion(ok, nil)
    }
  }

  @objc public func acknowledgeOpened(
    deliveryId: String,
    attributionToken: String,
    actionId: String?,
    completion: @escaping @Sendable (Bool, NSError?) -> Void
  ) {
    let action = actionId.flatMap { $0.isEmpty ? nil : $0 }
    Task {
      let ok = await ComRaid.shared.acknowledgeOpened(
        deliveryId: deliveryId,
        attributionToken: attributionToken,
        actionId: action
      )
      completion(ok, nil)
    }
  }

  @objc public func flushAcks(completion: @escaping @Sendable (NSError?) -> Void) {
    Task {
      await ComRaid.shared.flushAcks()
      completion(nil)
    }
  }

  private func stringDictionary(_ value: NSDictionary) -> [String: String] {
    value.reduce(into: [:]) { result, entry in
      guard let key = entry.key as? String, let string = entry.value as? String else { return }
      result[key] = string
    }
  }

  private func stringExtras(_ value: NSDictionary?) -> [String: String] {
    guard let value else { return [:] }
    return value.reduce(into: [:]) { result, entry in
      guard let key = entry.key as? String else { return }
      switch entry.value {
      case is NSNull:
        break
      case let string as String:
        result[key] = string
      case let number as NSNumber:
        result[key] = number.stringValue
      default:
        result[key] = "\(entry.value)"
      }
    }
  }

}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

extension ComRaidObjCBridge {
  private static func timerDictionary(_ timer: ComRaidTimer) -> NSDictionary {
    [
      "id": timer.id,
      "title": timer.notification.title,
      "body": timer.notification.body,
      "state": timer.state.rawValue,
      "triggerAtMillis": (timer.targetDate?.timeIntervalSince1970 ?? 0) * 1_000,
      "remainingDurationMs": timer.remainingDuration * 1_000,
    ] as NSDictionary
  }

  private static func authorizationOptions(_ names: [String]) -> UNAuthorizationOptions {
    var options: UNAuthorizationOptions = []
    for name in names {
      switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "alert": options.insert(.alert)
      case "badge": options.insert(.badge)
      case "sound": options.insert(.sound)
      case "provisional": options.insert(.provisional)
      case "carplay": options.insert(.carPlay)
      case "criticalalert": options.insert(.criticalAlert)
      case "providesappnotificationsettings": options.insert(.providesAppNotificationSettings)
      case "announcement":
        if #available(iOS 15.0, *) {
          options.insert(.announcement)
        }
      default:
        break
      }
    }
    return options.isEmpty ? [.alert, .badge, .sound] : options
  }

  private func precisionFallback(
    requestedPrecision: String,
    fallbackPolicy: String
  ) throws -> String {
    guard requestedPrecision == "inexact" || requestedPrecision == "exact" else {
      throw NSError(
        domain: "ComRaid",
        code: 1001,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported precision '\(requestedPrecision)'"]
      )
    }
    guard fallbackPolicy == "fail" || fallbackPolicy == "useInexact" else {
      throw NSError(
        domain: "ComRaid",
        code: 1002,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported fallback policy '\(fallbackPolicy)'"]
      )
    }
    if requestedPrecision == "exact" {
      guard fallbackPolicy == "useInexact" else {
        throw NSError(
          domain: "ComRaid",
          code: 1003,
          userInfo: [NSLocalizedDescriptionKey: "Exact alarm semantics are unavailable in this iOS notification API"]
        )
      }
      return "Exact alarm semantics are unavailable on iOS; scheduled as a notification"
    }
    return ""
  }
}
