# Comraid Apple SDK

Swift Package for local notification schedules/timers and the ComRaid mobile identity loop (Subscription register, Login, Logout, Contact-level push opt-in/out).

## Setup

Configure early with a publishable App ID and APNs environment:

```swift
await Comraid.shared.configure(
  .init(
    appId: "cr_app_your_id",
    // apiBaseURL: URL(string: "http://localhost:8080")!, // optional
    apnsEnvironment: .sandbox // or .production
  )
)
```

## Identity loop

1. Request permission (registers for remote notifications when granted).
2. Forward the APNs device token from AppDelegate.
3. Call `register()` to create a Subscription.
4. Use Login / Logout / opt-in / opt-out.

```swift
let granted = try await Comraid.shared.requestPermission()

// In AppDelegate:
func application(
  _ application: UIApplication,
  didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
  Task {
    await Comraid.shared.setAPNsDeviceToken(deviceToken)
    try? await Comraid.shared.register()
  }
}

try await Comraid.shared.login(externalUserId: "user_123")
try await Comraid.shared.login(externalUserId: "user_123", identityToken: jwtFromYourBackend)

try await Comraid.shared.logout()

try await Comraid.shared.optOut() // Contact Opted out of the push Channel (all Subscriptions)
try await Comraid.shared.optIn()
```

Logout makes the Subscription Inactive; Opted out is Contact × Channel and independent of Inactive.

On APNs token refresh, call `setAPNsDeviceToken` then `onPushTokenRefresh()`.

## Local timers

```swift
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

Wire field is `external_user_id` (never `external_id`). Logout keeps the stored credential so Contact-level opt-in/out still works while Inactive. Remote notification display and delivery ACKs are out of scope for this package version.
