import Foundation

/// Opaque token returned from `add*Listener` for later removal.
public struct ComRaidListenerToken: Hashable, Sendable {
  let id: UUID
  init() { id = UUID() }
}

/**
 Thread-safe receive/open/token listener registry outside the `ComRaid` actor so
 React Native / ObjC hosts can attach synchronously.
 */
final class RemoteReceiveHub: @unchecked Sendable {
  static let shared = RemoteReceiveHub()

  private let lock = NSLock()
  private var foregroundListeners: [UUID: RemoteMessageListener] = [:]
  private var backgroundListeners: [UUID: RemoteMessageListener] = [:]
  private var openedListeners: [UUID: RemoteMessageListener] = [:]
  private var tokenListeners: [UUID: TokenRefreshListener] = [:]
  private var initialNotification: RemoteMessageEvent?
  private var initialNotificationConsumed = false
  private var backgroundHandlerRegistered = false

  private init() {}

  func resetForTests() {
    lock.withLock {
      foregroundListeners.removeAll()
      backgroundListeners.removeAll()
      openedListeners.removeAll()
      tokenListeners.removeAll()
      initialNotification = nil
      initialNotificationConsumed = false
      backgroundHandlerRegistered = false
    }
  }

  func addForegroundMessageListener(_ listener: @escaping RemoteMessageListener) -> ComRaidListenerToken {
    let token = ComRaidListenerToken()
    lock.withLock { foregroundListeners[token.id] = listener }
    return token
  }

  func removeForegroundMessageListener(_ token: ComRaidListenerToken) {
    lock.withLock { _ = foregroundListeners.removeValue(forKey: token.id) }
  }

  func addBackgroundMessageListener(_ listener: @escaping RemoteMessageListener) -> ComRaidListenerToken {
    let token = ComRaidListenerToken()
    lock.withLock { backgroundListeners[token.id] = listener }
    return token
  }

  func removeBackgroundMessageListener(_ token: ComRaidListenerToken) {
    lock.withLock { _ = backgroundListeners.removeValue(forKey: token.id) }
  }

  func addNotificationOpenedListener(_ listener: @escaping RemoteMessageListener) -> ComRaidListenerToken {
    let token = ComRaidListenerToken()
    lock.withLock { openedListeners[token.id] = listener }
    return token
  }

  func removeNotificationOpenedListener(_ token: ComRaidListenerToken) {
    lock.withLock { _ = openedListeners.removeValue(forKey: token.id) }
  }

  func addTokenRefreshListener(_ listener: @escaping TokenRefreshListener) -> ComRaidListenerToken {
    let token = ComRaidListenerToken()
    lock.withLock { tokenListeners[token.id] = listener }
    return token
  }

  func removeTokenRefreshListener(_ token: ComRaidListenerToken) {
    lock.withLock { _ = tokenListeners.removeValue(forKey: token.id) }
  }

  func setBackgroundHandlerRegistered(_ registered: Bool) {
    lock.withLock { backgroundHandlerRegistered = registered }
  }

  func isBackgroundHandlerRegistered() -> Bool {
    lock.withLock { backgroundHandlerRegistered }
  }

  func getInitialNotification() -> RemoteMessageEvent? {
    lock.withLock {
      if initialNotificationConsumed { return nil }
      guard let value = initialNotification else { return nil }
      initialNotificationConsumed = true
      initialNotification = nil
      return value
    }
  }

  func notifyMessageReceived(_ event: RemoteMessageEvent, appInForeground: Bool) {
    let targets: [RemoteMessageListener] = lock.withLock {
      Array((appInForeground ? foregroundListeners : backgroundListeners).values)
    }
    for listener in targets {
      listener(event)
    }
  }

  func notifyNotificationOpened(_ event: RemoteMessageEvent) {
    let targets: [RemoteMessageListener] = lock.withLock {
      let listeners = Array(openedListeners.values)
      if !initialNotificationConsumed && initialNotification == nil && listeners.isEmpty {
        initialNotification = event
      }
      return listeners
    }
    for listener in targets {
      listener(event)
    }
  }

  func notifyTokenRefresh(_ token: String) {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let targets: [TokenRefreshListener] = lock.withLock { Array(tokenListeners.values) }
    for listener in targets {
      listener(trimmed)
    }
  }
}
