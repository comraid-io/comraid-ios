import Foundation
import Testing
@testable import ComRaid

@Suite(.serialized)
struct ComRaidTimerTests {
  @Test func startTimerPersistsRunningTimerAndSchedules() async throws {
    let harness = try await TimerHarness.make()

    let timer = try await harness.comraid.startTimer(
      id: "focus-1",
      duration: 60,
      notification: .init(id: "ignored", title: "Focus", body: "Done")
    )

    #expect(timer.id == "focus-1")
    #expect(timer.state == .running)
    #expect(timer.targetDate == harness.clock.now.addingTimeInterval(60))
    #expect(timer.remainingDuration == 60)
    #expect(harness.scheduler.scheduled.count == 1)
    #expect(try await harness.comraid.timers().count == 1)
    #expect(try await harness.comraid.pendingSchedules().count == 1)
  }

  @Test func pauseTimerClearsScheduleAndStoresRemaining() async throws {
    let harness = try await TimerHarness.make()
    _ = try await harness.comraid.startTimer(
      id: "focus-1",
      duration: 60,
      notification: .init(id: "focus-1", title: "Focus", body: "Done")
    )
    harness.clock.advance(by: 15)

    let paused = try await harness.comraid.pauseTimer(id: "focus-1")

    #expect(paused.state == .paused)
    #expect(paused.targetDate == nil)
    #expect(paused.remainingDuration == 45)
    #expect(try await harness.comraid.pendingSchedules().isEmpty)
    #expect(harness.scheduler.cancelled == ["focus-1"])
  }

  @Test func resumeTimerReschedulesFromRemaining() async throws {
    let harness = try await TimerHarness.make()
    _ = try await harness.comraid.startTimer(
      id: "focus-1",
      duration: 60,
      notification: .init(id: "focus-1", title: "Focus", body: "Done")
    )
    harness.clock.advance(by: 20)
    _ = try await harness.comraid.pauseTimer(id: "focus-1")
    harness.scheduler.clear()
    harness.clock.advance(by: 5)

    let resumed = try await harness.comraid.resumeTimer(id: "focus-1")

    #expect(resumed.state == .running)
    #expect(resumed.targetDate == harness.clock.now.addingTimeInterval(40))
    #expect(resumed.remainingDuration == 40)
    #expect(harness.scheduler.scheduled.count == 1)
    #expect(harness.scheduler.scheduled[0].triggerDate == harness.clock.now.addingTimeInterval(40))
  }

  @Test func cancelTimerMarksCancelledAndRemovesSchedule() async throws {
    let harness = try await TimerHarness.make()
    _ = try await harness.comraid.startTimer(
      id: "focus-1",
      duration: 60,
      notification: .init(id: "focus-1", title: "Focus", body: "Done")
    )

    try await harness.comraid.cancelTimer(id: "focus-1")

    let timer = try await harness.comraid.timers().first
    #expect(timer?.state == .cancelled)
    #expect(timer?.targetDate == nil)
    #expect(try await harness.comraid.pendingSchedules().isEmpty)
  }

  @Test func pauseTimerUnknownIdThrowsTimerNotFound() async throws {
    let harness = try await TimerHarness.make()
    await #expect(throws: ComRaidError.timerNotFound) {
      try await harness.comraid.pauseTimer(id: "missing")
    }
  }

  @Test func pauseTimerWhenPausedThrowsTimerNotPaused() async throws {
    let harness = try await TimerHarness.make()
    _ = try await harness.comraid.startTimer(
      id: "focus-1",
      duration: 60,
      notification: .init(id: "focus-1", title: "Focus", body: "Done")
    )
    _ = try await harness.comraid.pauseTimer(id: "focus-1")

    await #expect(throws: ComRaidError.timerNotPaused) {
      try await harness.comraid.pauseTimer(id: "focus-1")
    }
  }
}

private struct TimerHarness {
  let comraid: ComRaid
  let scheduler: RecordingLocalNotificationScheduler
  let clock: MutableDateClock

  static func make() async throws -> TimerHarness {
    let comraid = ComRaid()
    await comraid.resetForTests()
    let scheduler = RecordingLocalNotificationScheduler()
    let clock = MutableDateClock(Date(timeIntervalSince1970: 1_000_000))
    try await comraid.configureForTests(
      .init(
        appId: "cr_app_test",
        apnsEnvironment: .sandbox,
        storageSuiteName: "comraid.timer.\(UUID().uuidString)"
      ),
      transport: UnusedTransport(),
      tokenProvider: FakeTokenProvider(token: "token"),
      subscriptionStore: InMemorySubscriptionStore(),
      localNotificationScheduler: scheduler,
      clock: { clock.now }
    )
    return TimerHarness(comraid: comraid, scheduler: scheduler, clock: clock)
  }
}

private final class UnusedTransport: HttpTransport, @unchecked Sendable {
  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    fatalError("HTTP should not be called from timer tests")
  }
}

private struct FakeTokenProvider: TokenProvider {
  let token: String
  func currentToken() async throws -> String { token }
}
