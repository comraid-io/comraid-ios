import Foundation

/// Decides when a foreground should POST `/session`.
/// A new session is recorded on cold start (no prior session this process) or when
/// the app returns to foreground after being backgrounded for at least `debounce`.
/// If background was never observed, debounce against the last recorded session time
/// so repeated foregrounds do not immediately re-POST.
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
    guard let lastSessionAt else { return true }
    return now - lastSessionAt >= debounce
  }

  mutating func markSessionRecorded() {
    lastSessionAt = clock()
    // Consume the background signal so later foregrounds debounce from session time
    // until a new background is observed.
    lastBackgroundAt = nil
  }
}
