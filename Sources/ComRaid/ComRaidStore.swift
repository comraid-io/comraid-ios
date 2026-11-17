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
  private let lock = NSLock()

  init(suiteName: String?) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  func read() -> ComRaidPersistedState {
    lock.withLock {
      guard let data = defaults.data(forKey: key) else { return ComRaidPersistedState() }
      return (try? decoder.decode(ComRaidPersistedState.self, from: data)) ?? ComRaidPersistedState()
    }
  }

  func write(_ state: ComRaidPersistedState) throws {
    try lock.withLock {
      let data = try encoder.encode(state)
      defaults.set(data, forKey: key)
    }
  }
}
