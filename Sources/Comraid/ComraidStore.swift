import Foundation

struct ComraidPersistedState: Codable, Sendable {
  var schedules: [ComraidScheduleRequest] = []
  var timers: [ComraidTimer] = []
}

final class ComraidStore: @unchecked Sendable {
  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let key = "comraide.state.v1"
  private let lock = NSLock()

  init(suiteName: String?) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  func read() -> ComraidPersistedState {
    lock.withLock {
      guard let data = defaults.data(forKey: key) else { return ComraidPersistedState() }
      return (try? decoder.decode(ComraidPersistedState.self, from: data)) ?? ComraidPersistedState()
    }
  }

  func write(_ state: ComraidPersistedState) throws {
    try lock.withLock {
      let data = try encoder.encode(state)
      defaults.set(data, forKey: key)
    }
  }
}
