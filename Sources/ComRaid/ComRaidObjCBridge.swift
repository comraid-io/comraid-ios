import Foundation

@objc(ComraidBridge)
public final class ComRaidObjCBridge: NSObject, @unchecked Sendable {
  @objc public static let shared = ComRaidObjCBridge()

  private override init() {}

  @objc public func configure(
    appId: String,
    apiBaseURL: String?,
    apnsEnvironment: String,
    storageSuiteName: String?,
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
      await ComRaid.shared.configure(
        .init(
          appId: appId,
          apiBaseURL: baseURL,
          apnsEnvironment: env,
          storageSuiteName: configuredSuite
        )
      )
      completion(nil)
    }
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

  @objc public func requestNotificationPermission(
    completion: @escaping @Sendable (Bool, NSError?) -> Void
  ) {
    Task {
      do {
        completion(try await ComRaid.shared.requestPermission(), nil)
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

  private func stringDictionary(_ value: NSDictionary) -> [String: String] {
    value.reduce(into: [:]) { result, entry in
      guard let key = entry.key as? String, let string = entry.value as? String else { return }
      result[key] = string
    }
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
