import Foundation

/// Persists configure() settings so ACK / remote handlers can run without a
/// foreground `Comraid` singleton in this process lifetime.
struct SdkPersistedConfig: Equatable, Sendable {
  var appId: String
  var apiBaseURL: URL
  var apnsEnvironment: APNsEnvironment
  var storageSuiteName: String?
}

final class SdkConfigStore: @unchecked Sendable {
  private let defaults: UserDefaults
  private let lock = NSLock()
  private let prefix = "comraid.sdk_config."

  init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  func save(_ configuration: ComraidConfiguration) {
    lock.withLock {
      defaults.set(configuration.appId.trimmingCharacters(in: .whitespacesAndNewlines), forKey: prefix + "app_id")
      defaults.set(configuration.apiBaseURL.absoluteString, forKey: prefix + "api_base_url")
      defaults.set(configuration.apnsEnvironment.rawValue, forKey: prefix + "apns_environment")
      if let suite = configuration.storageSuiteName {
        defaults.set(suite, forKey: prefix + "storage_suite")
      } else {
        defaults.removeObject(forKey: prefix + "storage_suite")
      }
    }
  }

  func load() -> SdkPersistedConfig? {
    lock.withLock {
      guard let appId = defaults.string(forKey: prefix + "app_id")?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !appId.isEmpty else { return nil }
      let base = defaults.string(forKey: prefix + "api_base_url").flatMap(URL.init(string:))
        ?? URL(string: "https://api.comraid.io")!
      let envRaw = defaults.string(forKey: prefix + "apns_environment") ?? APNsEnvironment.sandbox.rawValue
      let env = APNsEnvironment(rawValue: envRaw) ?? .sandbox
      let suite = defaults.string(forKey: prefix + "storage_suite")
      return SdkPersistedConfig(
        appId: appId,
        apiBaseURL: base,
        apnsEnvironment: env,
        storageSuiteName: suite
      )
    }
  }
}
