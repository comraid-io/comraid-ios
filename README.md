# ComRaid Apple SDK

Swift Package for local notification schedules/timers and the ComRaid mobile identity loop (**Subscription** register, **Login**, **Logout**, Contact-level push opt-in/out), plus remote display helpers and durable delivery ACKs. Vocabulary: **Endpoint** / **Subscription**, `external_user_id`, Identity verification **JWT** (`login(externalUserId:jwt:)`). Server-side sends use **Message** / **Notification**, **Campaign**, **Single send**, **Broadcast**, and **Multi-send**.

Public Swift type aliases prefer **`ComRaid`** (`typealias ComRaid = Comraid`, etc.). CocoaPods: **`pod 'ComRaid'`** (primary `ComRaid.podspec`; compatibility alias at `aliases/Comraid.podspec`). SPM product/module remains `Comraid` until a dedicated SPM identity cutover.

## Setup

Configure early with a publishable App ID and APNs environment:

```swift
await ComRaid.shared.configure(
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
let granted = try await ComRaid.shared.requestPermission()

// In AppDelegate:
func application(
  _ application: UIApplication,
  didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
  Task {
    await ComRaid.shared.setAPNsDeviceToken(deviceToken)
    try? await ComRaid.shared.register()
  }
}

try await ComRaid.shared.login(externalUserId: "user_123")
try await ComRaid.shared.login(externalUserId: "user_123", jwt: jwtFromYourBackend)

try await ComRaid.shared.logout()

try await ComRaid.shared.optOut() // Contact Opted out of the push Channel (all Subscriptions)
try await ComRaid.shared.optIn()
```

Logout makes the Subscription Inactive; Opted out is Contact × Channel and independent of Inactive.

On APNs token refresh, call `setAPNsDeviceToken` then `onPushTokenRefresh()` (preserves Subscription identity when a credential exists).

## Device properties and attributes

```swift
await ComRaid.shared.setDeviceProperties(
  DeviceProperties(appVersion: "1.2.3", model: "iPhone16,1", osVersion: "18.0")
)

try await ComRaid.shared.login(externalUserId: "user_123")
try await ComRaid.shared.setAttributes(["plan": "premium", "tier": 2])
```

## Remote notifications and ACKs

```swift
// When a remote notification arrives:
await ComRaid.shared.handleRemoteNotification(userInfo: userInfo)

// When the user opens / taps an action:
await ComRaid.shared.handleNotificationResponse(response)

// Or acknowledge explicitly:
await ComRaid.shared.acknowledgeDelivered(deliveryId: id, attributionToken: token)
await ComRaid.shared.acknowledgeOpened(deliveryId: id, attributionToken: token, actionId: "accept")

// On launch (flush durable backlog without requiring prior init in this process if configure persisted):
await ComRaid.shared.flushAcks()
```

Use `RemoteNotificationDisplay.content(from:)` / `.categories(from:)` to build `UNNotificationContent` and action categories from `cr_*` payload keys. Delivered/opened ACKs use a durable UserDefaults queue that survives background delivery.

## Local timers

```swift
try await ComRaid.shared.startTimer(
  id: "focus-1",
  duration: 25 * 60,
  notification: ComRaidNotification(
    id: "focus-1",
    title: "Focus complete",
    body: "Your timer has finished."
  )
)
```

Wire field is `external_user_id` (never `external_id`). Logout keeps the stored credential so Contact-level opt-in/out still works while Inactive.

## Tests

```bash
swift test
```
