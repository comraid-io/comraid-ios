import Foundation

/// What an iOS Live Activity is doing, reduced to what ComRaid reports to the server.
enum LiveActivityState: Sendable, Equatable {
  case active
  case stale
  /// The activity ended (the app, the system or the timeout ended it).
  case ended
  /// The user removed it from the lock screen.
  case dismissed
}

/// One running Live activity as the tracker sees it. ActivityKit's `Activity<A>` is generic over
/// the host app's own attributes, so the tracker works through this small seam. Tests use a fake.
protocol LiveActivityHandle: Sendable {
  /// Apple's per-activity push token, as raw bytes, each time it is issued or rotated.
  func tokenUpdates() -> AsyncStream<Data>
  func stateUpdates() -> AsyncStream<LiveActivityState>
  /// End the activity now and remove it from the lock screen.
  func end() async
}

/// A Live activity the SDK is tracking, as listed by `ComRaid.trackedActivities()`.
public struct ComRaidTrackedActivity: Sendable, Equatable {
  public let id: String
  public let type: String

  public init(id: String, type: String) {
    self.id = id
    self.type = type
  }
}

#if canImport(ActivityKit)
import ActivityKit

/// ActivityKit's `Activity` is not declared `Sendable`. It is only read through its own async
/// streams from one task, so carrying it into that task is safe.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}

/// Adapts ActivityKit's `Activity` to `LiveActivityHandle`.
@available(iOS 16.2, *)
struct ActivityKitHandle<Attributes: ActivityAttributes>: LiveActivityHandle, @unchecked Sendable {
  let activity: Activity<Attributes>

  func tokenUpdates() -> AsyncStream<Data> {
    let box = UncheckedSendableBox(activity)
    return AsyncStream { continuation in
      let task = Task {
        for await token in box.value.pushTokenUpdates { continuation.yield(token) }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func stateUpdates() -> AsyncStream<LiveActivityState> {
    let box = UncheckedSendableBox(activity)
    return AsyncStream { continuation in
      let task = Task {
        for await state in box.value.activityStateUpdates {
          switch state {
          case .active: continuation.yield(.active)
          case .stale: continuation.yield(.stale)
          case .ended: continuation.yield(.ended)
          case .dismissed: continuation.yield(.dismissed)
          @unknown default: break
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func end() async {
    await activity.end(nil, dismissalPolicy: .immediate)
  }
}
#endif
