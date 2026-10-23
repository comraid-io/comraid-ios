# ComRaid Apple SDK

Swift Package for the ComRaid mobile identity loop (**Subscription** register, **Login**, **Logout**, Contact-level push opt-in/out), remote display helpers, durable delivery ACKs, and local notification schedules/timers.

Vocabulary: **Endpoint** / **Subscription**, `external_user_id`, Identity verification **JWT** (`login(externalUserId:jwt:)`). Server-side sends use **Message** / **Notification**, **Campaign**, **Single send**, **Broadcast**, and **Multi-send**.

Canonical docs: [docs.comraid.io/sdks/ios](https://docs.comraid.io/sdks/ios) (Install · Getting started · Method reference). This README stays at method-reference parity with the public Swift surface.

Package product/module: **`ComRaid`**. CocoaPods: **`pod 'ComRaid'`**.

## Install

**Swift Package Manager** — add the package dependency and import `ComRaid`:

```swift
import ComRaid
```

**CocoaPods:**

```ruby
pod 'ComRaid'
```

## Getting started

Configure early with a publishable App ID and APNs environment, then run the identity loop:

```swift
await ComRaid.shared.configure(
  .init(
    appId: "cr_app_your_id",
    // apiBaseURL: URL(string: "http://localhost:8080")!, // optional; default https://api.comraid.io
    apnsEnvironment: .sandbox // or .production
  )
)

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

Logout makes the Subscription Inactive; Opted out is Contact × Channel and independent of Inactive. On APNs token refresh, call `setAPNsDeviceToken` then `onPushTokenRefresh()` (preserves Subscription identity when a credential exists). Wire field is `external_user_id` (never `external_id`).

## Method reference

Depth B: signature, purpose, parameters, and return type. Examples are clustered per lifecycle group above/below — not one snippet per method.

### Configure

#### `configure(_:)`

```swift
func configure(_ configuration: ComRaidConfiguration)
```

Persists App ID / API base / APNs environment, sets up Keychain Subscription storage, and starts ACK flush.

| Parameter | Type | Description |
|-----------|------|-------------|
| `configuration` | `ComRaidConfiguration` | `appId` (`cr_app_…`), optional `apiBaseURL` (default `https://api.comraid.io`), required `apnsEnvironment`, optional `storageSuiteName` |

**Returns:** `Void`

#### `setAPNsDeviceToken(_:)`

```swift
func setAPNsDeviceToken(_ tokenData: Data) async
```

Stores the APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `tokenData` | `Data` | Raw APNs device token |

**Returns:** `Void`

#### `capabilities()`

```swift
func capabilities() async -> ComRaidCapabilities
```

Reads current notification authorization settings from `UNUserNotificationCenter`.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | — |

**Returns:** `ComRaidCapabilities` (`authorizationStatus`, `notificationsEnabled`)

### Identity

#### `requestPermission(options:)` / `requestAuthorization(options:)`

```swift
func requestPermission(options: UNAuthorizationOptions = [.alert, .badge, .sound]) async throws -> Bool
func requestAuthorization(options: UNAuthorizationOptions = [.alert, .badge, .sound]) async throws -> Bool
```

Requests notification permission. When granted, registers for remote notifications. `requestAuthorization` is an alias of `requestPermission`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `options` | `UNAuthorizationOptions` | Authorization options (default alert, badge, sound) |

**Returns:** `Bool` — whether permission was granted

#### `register()`

```swift
func register() async throws
```

Fetches the current APNs token and creates a Subscription (`mobileRegisterSubscription`). Requires a prior `setAPNsDeviceToken` (or a token already available to the provider).

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | — |

**Returns:** `Void`

#### `onPushTokenRefresh()`

```swift
func onPushTokenRefresh() async throws
```

Token rotation: replaces the Subscription token when a credential exists; otherwise full register (`mobileReplaceSubscriptionToken` / register).

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | — |

**Returns:** `Void`

#### `login(externalUserId:jwt:)`

```swift
func login(externalUserId: String, jwt: String? = nil) async throws
```

Binds the Subscription to a known Contact. Pass Identity verification **JWT** when the Project requires it.

| Parameter | Type | Description |
|-----------|------|-------------|
| `externalUserId` | `String` | Contact External user ID (required, non-empty) |
| `jwt` | `String?` | Optional Identity verification JWT from your backend |

**Returns:** `Void`

#### `logout()`

```swift
func logout() async throws
```

Makes the Subscription Inactive. Keeps the stored credential so Contact-level opt-in/out still works while Inactive.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | — |

**Returns:** `Void`

#### `optOut()` / `optIn()`

```swift
func optOut() async throws
func optIn() async throws
```

Contact-level push Channel opt-out / opt-in (all Subscriptions for that Contact).

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | — |

**Returns:** `Void`

### Properties and Attributes

```swift
await ComRaid.shared.setDeviceProperties(
  DeviceProperties(appVersion: "1.2.3", model: "iPhone16,1", osVersion: "18.0")
)
try await ComRaid.shared.login(externalUserId: "user_123")
try await ComRaid.shared.setAttributes(["plan": "premium", "tier": 2])
```

#### `setDeviceProperties(_:)`

```swift
func setDeviceProperties(_ properties: DeviceProperties)
```

Caches Subscription device Properties for the next `register` / token refresh (`app_version` + `device` object).

| Parameter | Type | Description |
|-----------|------|-------------|
| `properties` | `DeviceProperties` | Optional `appVersion`, `model`, `osVersion`, `extras` |

**Returns:** `Void`

#### `setAttributes(_:)`

```swift
func setAttributes(_ attributes: sending [String: Any]) async throws
```

Upserts Contact Attributes for the logged-in Contact (`PUT /mobile/subscriptions/{id}/attributes`). Requires prior Login.

| Parameter | Type | Description |
|-----------|------|-------------|
| `attributes` | `[String: Any]` | Non-empty Attribute map |

**Returns:** `Void`

### Remote notifications and ACKs

```swift
await ComRaid.shared.handleRemoteNotification(userInfo: userInfo)
await ComRaid.shared.handleNotificationResponse(response)
await ComRaid.shared.acknowledgeDelivered(deliveryId: id, attributionToken: token)
await ComRaid.shared.acknowledgeOpened(deliveryId: id, attributionToken: token, actionId: "accept")
await ComRaid.shared.flushAcks()
```

Delivered/opened ACKs use a durable UserDefaults queue that survives background delivery. `flushAcks` is safe on launch when `configure` has persisted.

API `content.push.deep_link` arrives as `cr_deep_link` in `userInfo`. Read it in your open handler and navigate yourself — the SDK does **not** auto-open URLs. For standard APNs alerts, `sound`, `subtitle`, `badge`, and `thread-id` are applied by the system from the aps payload.

#### `handleRemoteNotification(userInfo:)`

```swift
func handleRemoteNotification(userInfo: [AnyHashable: Any]) async
```

Registers action categories from `cr_*` payload keys and enqueues a delivered ACK.

| Parameter | Type | Description |
|-----------|------|-------------|
| `userInfo` | `[AnyHashable: Any]` | Remote notification `userInfo` |

**Returns:** `Void`

#### `handleNotificationResponse(_:)`

```swift
func handleNotificationResponse(_ response: UNNotificationResponse) async
```

Enqueues an opened ACK (optional action button id from the response).

| Parameter | Type | Description |
|-----------|------|-------------|
| `response` | `UNNotificationResponse` | Tap / action response from the system |

**Returns:** `Void`

#### `acknowledgeDelivered(deliveryId:attributionToken:)`

```swift
func acknowledgeDelivered(deliveryId: String, attributionToken: String) async -> Bool
```

Enqueues and flushes a delivered ACK. Returns `false` when ids are blank or the ACK queue is unavailable.

| Parameter | Type | Description |
|-----------|------|-------------|
| `deliveryId` | `String` | Delivery id (`cr_delivery_id`) |
| `attributionToken` | `String` | Attribution token (`cr_attribution_token`) |

**Returns:** `Bool`

#### `acknowledgeOpened(deliveryId:attributionToken:actionId:)`

```swift
func acknowledgeOpened(deliveryId: String, attributionToken: String, actionId: String? = nil) async -> Bool
```

Enqueues and flushes an opened ACK.

| Parameter | Type | Description |
|-----------|------|-------------|
| `deliveryId` | `String` | Delivery id |
| `attributionToken` | `String` | Attribution token |
| `actionId` | `String?` | Optional action button identifier |

**Returns:** `Bool`

#### `flushAcks()`

```swift
func flushAcks() async
```

Flushes any durable ACK backlog.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | — |

**Returns:** `Void`

### Local schedules

```swift
try await ComRaid.shared.schedule(
  ComRaidScheduleRequest(
    notification: ComRaidNotification(
      id: "promo-1",
      title: "Reminder",
      body: "Your offer expires soon."
    ),
    triggerDate: Date().addingTimeInterval(3600)
  )
)
let pending = try ComRaid.shared.pendingSchedules()
try ComRaid.shared.cancel(id: "promo-1")
```

#### `schedule(_:)`

```swift
func schedule(_ request: ComRaidScheduleRequest) async throws
```

Schedules a local notification at `triggerDate` and persists it. Trigger must be in the future; notification `id` must be non-empty.

| Parameter | Type | Description |
|-----------|------|-------------|
| `request` | `ComRaidScheduleRequest` | `notification` + `triggerDate` |

**Returns:** `Void`

#### `pendingSchedules()`

```swift
func pendingSchedules() throws -> [ComRaidScheduleRequest]
```

Returns persisted schedules whose `triggerDate` is still in the future, sorted ascending.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | — |

**Returns:** `[ComRaidScheduleRequest]`

#### `cancel(id:)`

```swift
func cancel(id: String) throws
```

Cancels a pending local schedule (and marks a matching timer cancelled if present).

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | `String` | Notification / schedule id |

**Returns:** `Void`

### Timers (iOS-only lifecycle)

```swift
let timer = try await ComRaid.shared.startTimer(
  id: "focus-1",
  duration: 25 * 60,
  notification: ComRaidNotification(
    id: "focus-1",
    title: "Focus complete",
    body: "Your timer has finished."
  )
)
_ = try ComRaid.shared.pauseTimer(id: "focus-1")
_ = try await ComRaid.shared.resumeTimer(id: "focus-1")
let all = try ComRaid.shared.timers()
try ComRaid.shared.cancelTimer(id: "focus-1")
```

`pauseTimer` / `resumeTimer` / `cancelTimer` / `timers` are local timer lifecycle APIs (iOS-only relative to other ComRaid mobile SDKs).

#### `startTimer(id:duration:notification:)`

```swift
func startTimer(id: String, duration: TimeInterval, notification: ComRaidNotification) async throws -> ComRaidTimer
```

Starts a countdown timer that fires a local notification when complete. `duration` must be finite and greater than 0.

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | `String` | Timer id (also forces `notification.id`) |
| `duration` | `TimeInterval` | Seconds until fire |
| `notification` | `ComRaidNotification` | Local notification content |

**Returns:** `ComRaidTimer`

#### `pauseTimer(id:)`

```swift
func pauseTimer(id: String) throws -> ComRaidTimer
```

Pauses a running timer, clears its pending system request, and stores remaining duration.

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | `String` | Timer id |

**Returns:** `ComRaidTimer` (state `.paused`)

#### `resumeTimer(id:)`

```swift
func resumeTimer(id: String) async throws -> ComRaidTimer
```

Resumes a paused timer from remaining duration.

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | `String` | Timer id |

**Returns:** `ComRaidTimer` (state `.running`)

#### `cancelTimer(id:)`

```swift
func cancelTimer(id: String) throws
```

Cancels a timer and removes its pending schedule.

| Parameter | Type | Description |
|-----------|------|-------------|
| `id` | `String` | Timer id |

**Returns:** `Void`

#### `timers()`

```swift
func timers() throws -> [ComRaidTimer]
```

Lists persisted timers (`running`, `paused`, `cancelled`, `completed`).

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | — |

**Returns:** `[ComRaidTimer]`

### Display helpers (`RemoteNotificationDisplay`)

Use these to build `UNNotificationContent` and action categories from `cr_*` payload keys (app-rendered / data-heavy paths). Not required for typical OS-presented Notifications.

| Method | Returns | Purpose |
|--------|---------|---------|
| `content(from:)` | `UNMutableNotificationContent` | Title/body/userInfo (+ category when actions present) |
| `categories(from:)` | `[UNNotificationCategory]` | Action buttons from payload |
| `categoryIdentifier(for:)` | `String` | Stable category id for a delivery |
| `registerCategories(from:)` | `Void` (async) | Merges categories into `UNUserNotificationCenter` |

### Models

| Type | Role |
|------|------|
| `ComRaidConfiguration` | App ID, API base URL, `APNsEnvironment`, optional storage suite |
| `APNsEnvironment` | `.sandbox` / `.production` |
| `DeviceProperties` | Subscription Properties for register / token refresh |
| `ComRaidNotification` | Local notification content |
| `ComRaidScheduleRequest` | Local schedule (`notification` + `triggerDate`) |
| `ComRaidCapabilities` / `ComRaidAuthorizationStatus` | Permission snapshot from `capabilities()` |
| `ComRaidTimer` | Timer state (`running` / `paused` / `cancelled` / `completed`) |

## Errors

Public `ComRaidError` cases:

| Case | When |
|------|------|
| `notConfigured` | Called before `configure` |
| `notReady` | Missing Subscription credential or Login required (e.g. `setAttributes`) |
| `invalidIdentifier` | Empty External user ID or empty Attributes map |
| `triggerMustBeInFuture` | Invalid schedule/timer duration or past trigger |
| `timerNotFound` | Unknown timer id |
| `timerNotPaused` | Pause/resume state mismatch |
| `persistenceFailed` | Local store write failed after scheduling |
| `apiError(String)` | Mobile API failure message |

## Objective-C bridge

`ComRaidObjCBridge` (`@objc(ComraidBridge)`) exposes a **subset** of the Swift API for React Native / ObjC hosts: configure, APNs token, permission, register, login/logout, opt-in/out, capabilities, schedule/cancel/pendingSchedules, `startTimer`, Attributes, and ACK helpers.

It does **not** mirror full Swift parity (for example timer pause/resume/list, `onPushTokenRefresh`, `setDeviceProperties`, `handleRemoteNotification` / `handleNotificationResponse`, or `RemoteNotificationDisplay`). Prefer the Swift `ComRaid` actor when possible.

## Not wrapped (HTTP-only)

`mobileSubscriptionSession` (`POST /mobile/subscriptions/{id}/session`) has **no** iOS SDK wrapper. Call it via the Mobile HTTP API / [API Reference](https://docs.comraid.io/api-reference) until product work adds an SDK method — do not invent a client method from this README.

## Tests

```bash
swift test
```
