import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

extension ComRaid {
  /// Install a fresh tracker, stopping the one it replaces so its tasks do not leak.
  func replaceActivityTracker(api: MobileApiClient, retryDelays: [TimeInterval]) {
    if let old = activityTracker { Task { await old.cancelAll() } }
    activityTracker = ActivityTracker(api: api, retryDelays: retryDelays) { [weak self] in
      await self?.activityReadiness()
    }
  }

  /// Start tracking a running Live activity. Used by `trackActivity` and by tests with a fake handle.
  func track(handle: any LiveActivityHandle, id: String, type: String) async {
    await activityTracker?.track(handle: handle, id: id, type: type)
  }

  func flushActivitiesForTests() async {
    await activityTracker?.flush()
  }

  func settleActivitiesForTests() async {
    await activityTracker?.settleForTests()
  }

  /// Live activities the SDK is tracking in this process.
  public func trackedActivities() async -> [ComRaidTrackedActivity] {
    await activityTracker?.tracked() ?? []
  }

  /// End a tracked Live activity and remove it from the lock screen. Returns false for an unknown id.
  @discardableResult
  public func endActivity(id: String) async -> Bool {
    await activityTracker?.end(id: id) ?? false
  }

  #if canImport(ActivityKit)
  /// Tell ComRaid about a Live activity your app just started with `pushType: .token`.
  ///
  /// ComRaid sends Apple's update token (and every rotation) to the server, so your backend can update
  /// the activity through the API, and reports when it ends or the user dismisses it. `id` is your own
  /// activity id (for example an order id), the same one you use in the ComRaid API; `type` names the
  /// kind of activity, for example `"delivery"`.
  ///
  /// Safe to call before the Contact is logged in: nothing is sent until they are.
  @available(iOS 16.2, *)
  public func trackActivity<Attributes: ActivityAttributes>(
    _ activity: Activity<Attributes>,
    id: String,
    type: String
  ) async {
    await track(handle: ActivityKitHandle(activity: activity), id: id, type: type)
  }

  /// Re-attach to the activities that are still running when your app launches. Call it once at
  /// launch for each of your attribute types; it tracks every running `Activity<Attributes>`.
  ///
  ///     await ComRaid.shared.trackRunningActivities(of: DeliveryAttributes.self, type: "delivery") {
  ///       $0.attributes.orderId
  ///     }
  @available(iOS 16.2, *)
  public func trackRunningActivities<Attributes: ActivityAttributes>(
    of attributes: Attributes.Type,
    type: String,
    id: @Sendable (Activity<Attributes>) -> String
  ) async {
    for activity in Activity<Attributes>.activities {
      await trackActivity(activity, id: id(activity), type: type)
    }
  }
  #endif
}
