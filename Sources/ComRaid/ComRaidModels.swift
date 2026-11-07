import Foundation

public enum APNsEnvironment: String, Sendable, Equatable {
  case sandbox
  case production
}

public struct ComRaidConfiguration: Sendable, Equatable {
  /// Publishable App ID (`cr_app_…`). Required for mobile API authentication.
  public var appId: String
  /// API base URL. Defaults to the hosted ComRaid API.
  public var apiBaseURL: URL
  /// Required for APNs Subscription register / token replace.
  public var apnsEnvironment: APNsEnvironment
  public var storageSuiteName: String?
  /**
   When true (default), non–data-only Notifications are shown by the SDK in the
   foreground (`willPresent` returns banner options). Set false to handle alerts
   only via receive listeners / `onMessage`.
   */
  public var displayForegroundNotifications: Bool

  public init(
    appId: String,
    apiBaseURL: URL = URL(string: "https://api.comraid.io")!,
    apnsEnvironment: APNsEnvironment,
    storageSuiteName: String? = nil,
    displayForegroundNotifications: Bool = true
  ) {
    self.appId = appId
    self.apiBaseURL = apiBaseURL
    self.apnsEnvironment = apnsEnvironment
    self.storageSuiteName = storageSuiteName
    self.displayForegroundNotifications = displayForegroundNotifications
  }
}

public struct ComRaidNotification: Codable, Sendable, Equatable {
  public var id: String
  public var title: String
  public var body: String
  public var subtitle: String?
  public var sound: String?
  public var categoryIdentifier: String?
  public var userInfo: [String: String]

  public init(
    id: String,
    title: String,
    body: String,
    subtitle: String? = nil,
    sound: String? = "default",
    categoryIdentifier: String? = nil,
    userInfo: [String: String] = [:]
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.subtitle = subtitle
    self.sound = sound
    self.categoryIdentifier = categoryIdentifier
    self.userInfo = userInfo
  }
}

public struct ComRaidScheduleRequest: Codable, Sendable, Equatable {
  public var notification: ComRaidNotification
  public var triggerDate: Date

  public init(notification: ComRaidNotification, triggerDate: Date) {
    self.notification = notification
    self.triggerDate = triggerDate
  }
}

public struct ComRaidCapabilities: Sendable, Equatable {
  public var authorizationStatus: ComRaidAuthorizationStatus
  public var notificationsEnabled: Bool

  public init(authorizationStatus: ComRaidAuthorizationStatus, notificationsEnabled: Bool) {
    self.authorizationStatus = authorizationStatus
    self.notificationsEnabled = notificationsEnabled
  }
}

public enum ComRaidAuthorizationStatus: String, Sendable, Equatable {
  case notDetermined
  case denied
  case authorized
  case provisional
  case ephemeral
  case unknown
}

public struct ComRaidTimer: Codable, Sendable, Equatable {
  public enum State: String, Codable, Sendable { case running, paused, cancelled, completed }

  public var id: String
  public var notification: ComRaidNotification
  public var state: State
  public var targetDate: Date?
  public var remainingDuration: TimeInterval

  public init(
    id: String,
    notification: ComRaidNotification,
    state: State,
    targetDate: Date?,
    remainingDuration: TimeInterval
  ) {
    self.id = id
    self.notification = notification
    self.state = state
    self.targetDate = targetDate
    self.remainingDuration = remainingDuration
  }
}

public enum ComRaidError: Error, Sendable, Equatable {
  case notConfigured
  case notReady
  case invalidIdentifier
  case triggerMustBeInFuture
  case timerNotFound
  case timerNotPaused
  case persistenceFailed
  case apiError(String)
}

/**
 Subscription / Contact Properties sent on register, token refresh, and session.
 The SDK fills these automatically; `setDeviceProperties` overrides individual
 fields (non-nil wins) for the next outbound call.
 */
public struct DeviceProperties: Sendable, Equatable {
  public var appVersion: String?
  public var sdkVersion: String?
  public var model: String?
  public var os: String?
  public var osVersion: String?
  public var locale: String?
  public var timezone: String?
  public var language: String?
  public var country: String?
  public var extras: [String: String]

  public init(
    appVersion: String? = nil,
    sdkVersion: String? = nil,
    model: String? = nil,
    os: String? = nil,
    osVersion: String? = nil,
    locale: String? = nil,
    timezone: String? = nil,
    language: String? = nil,
    country: String? = nil,
    extras: [String: String] = [:]
  ) {
    self.appVersion = appVersion
    self.sdkVersion = sdkVersion
    self.model = model
    self.os = os
    self.osVersion = osVersion
    self.locale = locale
    self.timezone = timezone
    self.language = language
    self.country = country
    self.extras = extras
  }
}
