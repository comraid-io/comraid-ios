import Foundation

struct ComRaidPersistedState: Codable, Sendable {
  var schedules: [ComRaidScheduleRequest] = []
  var timers: [ComRaidTimer] = []
}

final class ComRaidStore: @unchecked Sendable {
  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let key = "comraid.state.v1"
  private let legacyKey = "comraide.state.v1"
  private let lock = NSLock()

  init(suiteName: String?) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  func read() -> ComRaidPersistedState {
    lock.withLock {
      if let data = defaults.data(forKey: key) {
        return (try? decoder.decode(ComRaidPersistedState.self, from: data)) ?? ComRaidPersistedState()
      }
      // One-shot read-fallback from pre-migrate key.
      guard let legacy = defaults.data(forKey: legacyKey) else { return ComRaidPersistedState() }
      defaults.set(legacy, forKey: key)
      defaults.removeObject(forKey: legacyKey)
      return (try? decoder.decode(ComRaidPersistedState.self, from: legacy)) ?? ComRaidPersistedState()
    }
  }

  func write(_ state: ComRaidPersistedState) throws {
    try lock.withLock {
      let data = try encoder.encode(state)
      defaults.set(data, forKey: key)
      defaults.removeObject(forKey: legacyKey)
    }
  }
}
