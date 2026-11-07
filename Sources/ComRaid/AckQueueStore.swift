import Foundation

protocol AckQueueStore: Sendable {
  func get(_ key: String) -> String?
  func set(_ key: String, value: String)
}

/// Persists ACK queue JSON in UserDefaults so background handlers can flush without foreground init.
final class UserDefaultsAckQueueStore: AckQueueStore, @unchecked Sendable {
  private let defaults: UserDefaults
  private let lock = NSLock()

  init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  func get(_ key: String) -> String? {
    lock.withLock { defaults.string(forKey: key) }
  }

  func set(_ key: String, value: String) {
    lock.withLock { defaults.set(value, forKey: key) }
  }
}
