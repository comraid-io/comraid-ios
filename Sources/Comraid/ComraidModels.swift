import Foundation

public struct ComraidConfiguration: Sendable, Equatable {
  public var storageSuiteName: String?

  public init(storageSuiteName: String? = nil) {
    self.storageSuiteName = storageSuiteName
  }
}

public struct ComraidNotification: Codable, Sendable, Equatable {
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

public struct ComraidScheduleRequest: Codable, Sendable, Equatable {
  public var notification: ComraidNotification
  public var triggerDate: Date

  public init(notification: ComraidNotification, triggerDate: Date) {
    self.notification = notification
    self.triggerDate = triggerDate
  }
}

public struct ComraidCapabilities: Sendable, Equatable {
  public var authorizationStatus: ComraidAuthorizationStatus
  public var notificationsEnabled: Bool

  public init(authorizationStatus: ComraidAuthorizationStatus, notificationsEnabled: Bool) {
    self.authorizationStatus = authorizationStatus
    self.notificationsEnabled = notificationsEnabled
  }
}

public enum ComraidAuthorizationStatus: String, Sendable, Equatable {
  case notDetermined
  case denied
  case authorized
  case provisional
  case ephemeral
  case unknown
}

public struct ComraidTimer: Codable, Sendable, Equatable {
  public enum State: String, Codable, Sendable { case running, paused, cancelled, completed }

  public var id: String
  public var notification: ComraidNotification
  public var state: State
  public var targetDate: Date?
  public var remainingDuration: TimeInterval

  public init(
    id: String,
    notification: ComraidNotification,
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

public enum ComraidError: Error, Sendable, Equatable {
  case notConfigured
  case invalidIdentifier
  case triggerMustBeInFuture
  case timerNotFound
  case timerNotPaused
  case persistenceFailed
}
