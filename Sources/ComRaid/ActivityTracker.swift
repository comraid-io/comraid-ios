import Foundation

/// What the tracker needs to talk to the server for one Contact.
struct ActivityReadiness: Sendable {
  let subscriptionId: String
  let credential: String
}

/// Keeps ComRaid informed about the Live activities the host app started: sends Apple's update
/// token (and every rotation), and reports when an activity ends or the user dismisses it.
///
/// It waits until the Subscription exists and the Contact is logged in (the server refuses tokens
/// from anonymous Subscriptions), sends the newest token only, and retries network errors.
actor ActivityTracker {
  private struct Entry {
    var generation: Int
    var handle: any LiveActivityHandle
    var type: String
    var latestToken: String?
    var sentToken: String?
    var pendingEnd: String?
    var draining = false
    var tasks: [Task<Void, Never>] = []
  }

  /// The retry schedule (seconds between attempts) for network errors.
  static let defaultRetryDelays: [TimeInterval] = [1, 3, 8]

  private enum Outcome { case done, rejected, refused, retryLater }

  private var entries: [String: Entry] = [:]
  private var nextGeneration = 0
  private var flushTasks: [Task<Void, Never>] = []
  private let api: MobileApiClient
  private let readiness: @Sendable () async -> ActivityReadiness?
  private let retryDelays: [TimeInterval]

  init(
    api: MobileApiClient,
    retryDelays: [TimeInterval],
    readiness: @escaping @Sendable () async -> ActivityReadiness?
  ) {
    self.api = api
    self.retryDelays = retryDelays
    self.readiness = readiness
  }

  /// Start tracking. Tracking the same id again replaces the earlier tracking.
  func track(handle: any LiveActivityHandle, id: String, type: String) {
    if let old = entries[id] { old.tasks.forEach { $0.cancel() } }
    nextGeneration += 1
    let generation = nextGeneration
    let tokenTask = Task { [weak self] in
      for await data in handle.tokenUpdates() {
        await self?.tokenArrived(id: id, generation: generation, token: data.map { String(format: "%02x", $0) }.joined())
      }
    }
    let stateTask = Task { [weak self] in
      for await state in handle.stateUpdates() {
        await self?.stateChanged(id: id, generation: generation, state: state)
      }
    }
    entries[id] = Entry(generation: generation, handle: handle, type: type, tasks: [tokenTask, stateTask])
  }

  /// Activities still running. One that ended but could not be reported yet (the Contact is not
  /// logged in) is over, so it is not listed even though its report is still waiting.
  func tracked() -> [ComRaidTrackedActivity] {
    entries.filter { $0.value.pendingEnd == nil }
      .map { ComRaidTrackedActivity(id: $0.key, type: $0.value.type) }
      .sorted { $0.id < $1.id }
  }

  /// Stop tracking everything (the SDK was configured again or reset).
  func cancelAll() {
    entries.values.forEach { $0.tasks.forEach { $0.cancel() } }
    flushTasks.forEach { $0.cancel() }
    entries = [:]
    flushTasks = []
  }

  /// End a tracked activity. The state stream then reports it ended to the server.
  func end(id: String) async -> Bool {
    guard let handle = entries[id]?.handle else { return false }
    await handle.end()
    return true
  }

  /// Send whatever is waiting (after login, register or app foreground), every activity at once.
  func flush() async {
    let pending = entries.map { ($0.key, $0.value.generation) }
    await withTaskGroup(of: Void.self) { group in
      for (id, generation) in pending {
        group.addTask { await self.drain(id: id, generation: generation) }
      }
    }
  }

  /// Flush in the background so login, register and foreground never wait on the network.
  func scheduleFlush() {
    flushTasks.append(Task { await self.flush() })
  }

  /// Test seam: wait for every tracking and flush task to finish (the fake streams are finished first).
  func settleForTests() async {
    let tasks = entries.values.flatMap(\.tasks) + flushTasks
    for task in tasks { await task.value }
  }

  private func tokenArrived(id: String, generation: Int, token: String) async {
    guard entries[id]?.generation == generation else { return }
    entries[id]?.latestToken = token
    await drain(id: id, generation: generation)
  }

  private func stateChanged(id: String, generation: Int, state: LiveActivityState) async {
    guard entries[id]?.generation == generation else { return }
    switch state {
    case .ended: entries[id]?.pendingEnd = "ended"
    case .dismissed: entries[id]?.pendingEnd = "dismissed"
    case .active, .stale: return
    }
    await drain(id: id, generation: generation)
  }

  /// Send the pending end report or the newest unsent token, one request at a time per activity.
  private func drain(id: String, generation: Int) async {
    guard entries[id]?.generation == generation, entries[id]?.draining == false else { return }
    entries[id]?.draining = true
    defer { if entries[id]?.generation == generation { entries[id]?.draining = false } }

    while true {
      guard let ready = await readiness() else { return }
      // Read the entry after the await: a token or an end may have arrived while we waited.
      guard let entry = entries[id], entry.generation == generation else { return }

      if let reason = entry.pendingEnd {
        let outcome = await attempt {
          try await self.api.reportActivityEnded(
            subscriptionId: ready.subscriptionId, credential: ready.credential, activityId: id, reason: reason)
        }
        if outcome == .retryLater || outcome == .refused { return }
        // Reported, or refused for good: either way there is nothing more to track.
        entries[id]?.tasks.forEach { $0.cancel() }
        entries[id] = nil
        return
      }

      guard let token = entry.latestToken, token != entry.sentToken else { return }
      let outcome = await attempt {
        try await self.api.registerActivityToken(
          subscriptionId: ready.subscriptionId, credential: ready.credential,
          activityId: id, activityType: entry.type, updateToken: token)
      }
      if outcome == .retryLater || outcome == .refused { return }
      // Sent, or refused for good (do not send the same token again). A newer token loops again.
      if entries[id]?.generation == generation { entries[id]?.sentToken = token }
    }
  }

  private func attempt(_ operation: () async throws -> Void) async -> Outcome {
    let schedule: [TimeInterval?] = [nil] + retryDelays.map { Optional($0) }
    for (index, delay) in schedule.enumerated() {
      if index > 0, let delay, delay > 0 {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
      // Replaced or cancelled while waiting: do not send for a tracking that no longer exists.
      if Task.isCancelled { return .retryLater }
      do {
        try await operation()
        return .done
      } catch ActivityRequestError.rejected {
        return .rejected
      } catch ActivityRequestError.refused {
        return .refused
      } catch {
        continue
      }
    }
    return .retryLater
  }
}
