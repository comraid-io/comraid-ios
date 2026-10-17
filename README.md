# Comraid Apple SDK

Swift Package foundation for local notification schedules and durable timers.

```swift
await Comraid.shared.configure()
let granted = try await Comraid.shared.requestAuthorization()

try await Comraid.shared.startTimer(
  id: "focus-1",
  duration: 25 * 60,
  notification: ComraidNotification(
    id: "focus-1",
    title: "Focus complete",
    body: "Your timer has finished."
  )
)
```

Call permission APIs from an appropriate user interaction. A timer expiry uses a system-scheduled local notification and does not require the app process to remain alive. This first slice does not yet include APNs registration, notification actions, ActivityKit, AlarmKit, extensions, or Handoff.
