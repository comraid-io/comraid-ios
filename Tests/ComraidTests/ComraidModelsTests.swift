import Foundation
import Testing
@testable import Comraid

@Test func notificationRoundTripsThroughJSON() throws {
  let notification = ComraidNotification(
    id: "focus-1",
    title: "Focus complete",
    body: "Done",
    userInfo: ["route": "focus/1"]
  )
  let data = try JSONEncoder().encode(notification)
  #expect(try JSONDecoder().decode(ComraidNotification.self, from: data) == notification)
}

@Test func timerRoundTripsThroughJSON() throws {
  let timer = ComraidTimer(
    id: "timer-1",
    notification: .init(id: "timer-1", title: "Timer", body: "Done"),
    state: .paused,
    targetDate: nil,
    remainingDuration: 30
  )
  let data = try JSONEncoder().encode(timer)
  #expect(try JSONDecoder().decode(ComraidTimer.self, from: data) == timer)
}
