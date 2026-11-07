import Foundation

/// Decides when a foreground should POST `/session`.
/// A new session is recorded on cold start (no prior session this process) or when
/// the app returns to foreground after being backgrounded for at least `debounce`.
struct SessionTracker: Sendable {
  static let defaultDebounce: TimeInterval = 30 * 60

  private let debounce: TimeInterval
  private let clock: @Sendable () -> TimeInterval
  private var lastBackgroundAt: TimeInterval?
  private var lastSessionAt: TimeInterval?

  init(
    debounce: TimeInterval = Self.defaultDebounce,
    clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
  ) {
    self.debounce = debounce
    self.clock = clock
  }

  mutating func onBackground() {
    lastBackgroundAt = clock()
  }

  func shouldRecordSession() -> Bool {
    let now = clock()
    if let lastBackgroundAt {
      return now - lastBackgroundAt >= debounce
    }
    return lastSessionAt == nil
  }

  mutating func markSessionRecorded() {
    lastSessionAt = clock()
  }
}
