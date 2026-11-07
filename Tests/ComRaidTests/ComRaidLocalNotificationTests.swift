import Foundation
import Testing
@testable import ComRaid

@Suite(.serialized)
struct ComRaidLocalNotificationTests {
  @Test func schedulePersistsAndArmsSystemRequest() async throws {
    let harness = try await ScheduleHarness.make()
    let trigger = harness.clock.now.addingTimeInterval(30)

    try await harness.comraid.schedule(
      .init(
        notification: .init(id: "local-1", title: "Ping", body: "Soon"),
        triggerDate: trigger
      )
    )

    #expect(harness.scheduler.scheduled.map(\.notification.id) == ["local-1"])
    let pending = try await harness.comraid.pendingSchedules()
    #expect(pending.map(\.notification.id) == ["local-1"])
  }

  @Test func cancelRemovesFromStoreAndScheduler() async throws {
    let harness = try await ScheduleHarness.make()
    try await harness.comraid.schedule(
      .init(
        notification: .init(id: "local-1", title: "Ping", body: "Soon"),
        triggerDate: harness.clock.now.addingTimeInterval(30)
      )
    )

    try await harness.comraid.cancel(id: "local-1")

    #expect(try await harness.comraid.pendingSchedules().isEmpty)
    #expect(harness.scheduler.cancelled == ["local-1"])
  }

  @Test func pendingSchedulesListsActiveRequests() async throws {
    let harness = try await ScheduleHarness.make()
    try await harness.comraid.schedule(
      .init(
        notification: .init(id: "a", title: "A", body: "1"),
        triggerDate: harness.clock.now.addingTimeInterval(10)
      )
    )
    try await harness.comraid.schedule(
      .init(
        notification: .init(id: "b", title: "B", body: "2"),
        triggerDate: harness.clock.now.addingTimeInterval(20)
      )
    )

    let ids = Set(try await harness.comraid.pendingSchedules().map(\.notification.id))
    #expect(ids == Set(["a", "b"]))
  }

  @Test func schedulePastTriggerThrows() async throws {
    let harness = try await ScheduleHarness.make()

    await #expect(throws: ComRaidError.triggerMustBeInFuture) {
      try await harness.comraid.schedule(
        .init(
          notification: .init(id: "past", title: "Too late", body: "Nope"),
          triggerDate: harness.clock.now
        )
      )
    }
    #expect(harness.scheduler.scheduled.isEmpty)
    #expect(try await harness.comraid.pendingSchedules().isEmpty)
  }
}

private struct ScheduleHarness {
  let comraid: ComRaid
  let scheduler: RecordingLocalNotificationScheduler
  let clock: MutableDateClock

  static func make() async throws -> ScheduleHarness {
    let comraid = ComRaid()
    await comraid.resetForTests()
    let scheduler = RecordingLocalNotificationScheduler()
    let clock = MutableDateClock(Date(timeIntervalSince1970: 1_000_000))
    try await comraid.configureForTests(
      .init(
        appId: "cr_app_test",
        apnsEnvironment: .sandbox,
        storageSuiteName: "comraid.schedule.\(UUID().uuidString)"
      ),
      transport: UnusedTransport(),
      tokenProvider: FakeTokenProvider(token: "token"),
      subscriptionStore: InMemorySubscriptionStore(),
      localNotificationScheduler: scheduler,
      scheduleClock: { clock.now }
    )
    return ScheduleHarness(comraid: comraid, scheduler: scheduler, clock: clock)
  }
}

final class RecordingLocalNotificationScheduler: LocalNotificationScheduling, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var scheduled: [ComRaidScheduleRequest] = []
  private(set) var cancelled: [String] = []

  func schedule(_ request: ComRaidScheduleRequest) async throws {
    lock.withLock { scheduled.append(request) }
  }

  func cancel(id: String) {
    lock.withLock { cancelled.append(id) }
  }

  func clear() {
    lock.withLock {
      scheduled.removeAll()
      cancelled.removeAll()
    }
  }
}

final class MutableDateClock: @unchecked Sendable {
  private let lock = NSLock()
  private var _now: Date

  var now: Date {
    get { lock.withLock { _now } }
    set { lock.withLock { _now = newValue } }
  }

  init(_ now: Date) { _now = now }

  func advance(by interval: TimeInterval) {
    lock.withLock { _now = _now.addingTimeInterval(interval) }
  }
}

private final class UnusedTransport: HttpTransport, @unchecked Sendable {
  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    fatalError("HTTP should not be called from local notification tests")
  }
}

private struct FakeTokenProvider: TokenProvider {
  let token: String
  func currentToken() async throws -> String { token }
}
