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

Logout makes the Subscription Inactive and clears Keychain identity; the SDK then registers a fresh Subscription. Opted out is Contact × Channel and independent of Inactive. Forward APNs tokens with `setAPNsDeviceToken` — when a Subscription credential already exists, the SDK calls `/token` automatically. Wire field is `external_user_id` (never `external_id`).

## Method reference

Depth B: signature, purpose, parameters, and return type. Examples are clustered per lifecycle group above/below — not one snippet per method.

### Configure

#### `configure(_:)`

```swift
func configure(_ configuration: ComRaidConfiguration)
```

Persists App ID / API base / APNs environment, sets up Keychain Subscription storage (id, credential, External user ID), restores a logged-in External user ID when present, and starts ACK flush.

| Parameter | Type | Description |
|-----------|------|-------------|
| `configuration` | `ComRaidConfiguration` | `appId` (`cr_app_…`), optional `apiBaseURL` (default `https://api.comraid.io`), required `apnsEnvironment`, optional `storageSuiteName`, optional `displayForegroundNotifications` (default `true`) |

**Returns:** `Void`

#### `setAPNsDeviceToken(_:)`

```swift
func setAPNsDeviceToken(_ tokenData: Data) async
```

Stores the APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. Notifies `addTokenRefreshListener` subscribers. When a Subscription credential already exists, also calls `/token` (same path as `onPushTokenRefresh`).

| Parameter | Type | Description |
|-----------|------|-------------|
| `tokenData` | `Data` | Raw APNs device token |

**Returns:** `Void`

#### `getToken()`

```swift
func getToken() async throws -> String
```

Provider push token (APNs hex). Not a ComRaid Endpoint / Subscription id.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | — |

**Returns:** `String` — APNs device token hex

#### `getInitialNotification()`

```swift
func getInitialNotification() -> RemoteMessageEvent?
```

Cold-start tap payload, if any. Cleared after the first successful read.

| Parameter | Type | Description |
|-----------|------|-------------|
| — | — | — |

**Returns:** `RemoteMessageEvent?`

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

Fetches the current APNs token and creates or refreshes a Subscription (`mobileRegisterSubscription`). Sends a persisted Keychain credential when present so a repeat register keeps the same Subscription and Contact. Requires a prior `setAPNsDeviceToken` (or a token already available to the provider).

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

Binds the Subscription to a known Contact. Pass Identity verification **JWT** when the Project requires it. Persists the External user ID in the Keychain with the Subscription id and credential so `setAttributes` works after an app restart.

| Parameter | Type | Description |
|-----------|------|-------------|
| `externalUserId` | `String` | Contact External user ID (required, non-empty) |
| `jwt` | `String?` | Optional Identity verification JWT from your backend |

**Returns:** `Void`

#### `logout()`

```swift
func logout() async throws
```

Makes the Subscription **Inactive** and clears its server credential. Clears the Keychain Subscription id, credential, and External user ID, then immediately registers a fresh Subscription on a new Anonymous contact. Mobile routes refuse the old row with `401 unauthorized` or `409 subscription_inactive`.

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

#### Automatic Properties and sessions

On `register` and on each eligible foreground the SDK sends:

| Field | Source |
|-------|--------|
| `app_version` | Host `CFBundleShortVersionString` |
| `sdk_version` | ComRaid iOS library version |
| `device.os` / `device.os_version` / `device.model` | `UIDevice` + hardware model id |
| `locale` / `language` / `country` | Device locale / region |
| `timezone` | IANA id from the device timezone |

Foreground session POSTs are debounced (~30 minutes since last background). There is
**no** public `session` method.

#### `setDeviceProperties(_:)`

```swift
func setDeviceProperties(_ properties: DeviceProperties)
```

Optional overrides for automatically collected Properties on the next register / token /
session call. Nil fields keep the auto-collected value.

| Parameter | Type | Description |
|-----------|------|-------------|
| `properties` | `DeviceProperties` | Optional overrides (`appVersion`, `sdkVersion`, `model`, `os`, `osVersion`, `locale`, `timezone`, `language`, `country`, `extras`) |

**Returns:** `Void`

#### `setAttributes(_:)`

```swift
func setAttributes(_ attributes: sending [String: Any]) async throws
```

Upserts Contact Attributes for the logged-in Contact (`PUT /mobile/subscriptions/{id}/attributes`). Requires prior Login.

| Parameter | Type | Description |
|-----------|------|-------------|
| `attributes` | `[String: Any]` | Attribute map (empty map is a successful empty update). Pass `NSNull()` for a key to remove that Attribute. |

**Returns:** `Void`

### Remote notifications and ACKs

```swift
await ComRaid.shared.handleRemoteNotification(userInfo: userInfo, appInForeground: true)
let options = await ComRaid.shared.presentationOptions(for: userInfo)
await ComRaid.shared.handleNotificationResponse(response)
try await ComRaid.shared.presentNotification(event)
await ComRaid.shared.acknowledgeDelivered(deliveryId: id, attributionToken: token)
await ComRaid.shared.acknowledgeOpened(deliveryId: id, attributionToken: token, actionId: "accept")
await ComRaid.shared.flushAcks()
```

Delivered/opened ACKs use a durable UserDefaults queue that survives background delivery. `flushAcks` is safe on launch when `configure` has persisted. Receive never auto-marks opened (ADR 0006). Data-only Notifications (`cr_data_only`) never auto-present; use `presentNotification` for optional tray promotion.

API `content.push.deep_link` arrives as `cr_deep_link` in `userInfo`. Read it in your open handler and navigate yourself — the SDK does **not** auto-open URLs. For standard APNs alerts, `sound`, `subtitle`, `badge`, and `thread-id` are applied by the system from the aps payload; `presentNotification` / `RemoteNotificationDisplay.present(data:)` apply `cr_sound`, `cr_badge`, `cr_thread_id`, `cr_subtitle` (or the matching `aps` / `aps.alert` fields) and attach `cr_image_url`. Received events also carry `androidChannelId` and `priority` (`high` / `normal`) when present in the payload. iOS data-only delivery is best-effort when the OS runs the app.

#### `handleRemoteNotification(userInfo:appInForeground:)`

```swift
func handleRemoteNotification(userInfo: [AnyHashable: Any], appInForeground: Bool = true) async
```

Registers action categories from `cr_*` payload keys, enqueues a delivered ACK, and notifies foreground/background receive listeners.

| Parameter | Type | Description |
|-----------|------|-------------|
| `userInfo` | `[AnyHashable: Any]` | Remote notification `userInfo` |
| `appInForeground` | `Bool` | Routes the event to foreground vs background listeners |

**Returns:** `Void`

#### `presentationOptions(for:)`

```swift
func presentationOptions(for userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions
```

Options for `userNotificationCenter(_:willPresent:…)`. Data-only never presents; non–data-only follows `displayForegroundNotifications`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `userInfo` | `[AnyHashable: Any]` | Remote notification `userInfo` |

**Returns:** `UNNotificationPresentationOptions`

#### `handleNotificationResponse(_:)`

```swift
func handleNotificationResponse(_ response: UNNotificationResponse) async
```

Enqueues an opened ACK (optional action button id from the response) and notifies opened listeners (including taps on SDK-presented notifications).

| Parameter | Type | Description |
|-----------|------|-------------|
| `response` | `UNNotificationResponse` | Tap / action response from the system |

**Returns:** `Void`

#### `handleNotificationOpen(userInfo:actionId:)`

```swift
func handleNotificationOpen(userInfo: [AnyHashable: Any], actionId: String? = nil) async
```

ObjC / RN-friendly open path equivalent to `handleNotificationResponse`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `userInfo` | `[AnyHashable: Any]` | Notification `userInfo` |
| `actionId` | `String?` | Optional action button id |

**Returns:** `Void`

#### `presentNotification(_:)` / `presentNotification(data:)`

```swift
func presentNotification(_ event: RemoteMessageEvent) async throws
func presentNotification(data: [String: String]) async throws
```

Posts a local tray item from title/body/actions (optional promotion). Requires a non-blank title. Body/action taps flow through `handleNotificationResponse` / `handleNotificationOpen` and auto-ACK opened. Presentation fields travel on the event (`imageUrl`, `subtitle`, `sound`, `badge`, `threadId`, `androidChannelId`, `priority`), so either form applies them (iOS draws image, subtitle, sound, badge and thread; `androidChannelId` is carried for parity and not drawn).

| Parameter | Type | Description |
|-----------|------|-------------|
| `event` / `data` | `RemoteMessageEvent` / `[String: String]` | Message to present |

**Returns:** `Void`

#### `addForegroundMessageListener` / `addBackgroundMessageListener` / `addNotificationOpenedListener` / `addTokenRefreshListener`

Register receive/open/token listeners (tokens from `ComRaidListenerToken` for removal). Same event shape as React Native `onMessage` / background / opened / token refresh.

#### `setBackgroundHandlerRegistered(_:)`

```swift
func setBackgroundHandlerRegistered(_ registered: Bool)
```

Marks that a JS background message handler is registered (RN). Receive still never auto-opens.

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
| `content(from:)` | `UNMutableNotificationContent` | Title/body/subtitle/userInfo, `cr_sound` / `cr_badge` / `cr_thread_id` (+ category when actions present) |
| `categories(from:)` | `[UNNotificationCategory]` | Action buttons from payload |
| `categoryIdentifier(for:)` | `String` | Fixed `comraid.actions` (matches server APNs category) |
| `registerCategories(from:)` | `Void` (async) | Merges categories into `UNUserNotificationCenter` |
| `present(data:)` | `Void` (async throws) | Post a local tray item immediately |
| `enrich(_:)` | `UNNotificationContent` (async) | Notification Service Extension: attach `cr_image_url`, register `comraid.actions` buttons |

#### Images and action buttons (Notification Service Extension)

The server sets `mutable-content` when a push has an image or action buttons. iOS only shows the image (and, on a cold device, the buttons) when a Notification Service Extension adds them. Add an extension target that links `ComRaid`:

```swift
import ComRaid
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    Task { contentHandler(await RemoteNotificationDisplay.enrich(request)) }
  }
}
```

`ComRaid` is extension-safe: `requestPermission`, `requestAuthorization` and the bridge's `requestNotificationPermission` are unavailable in app extensions, and nothing else in the module needs `UIApplication`. Images are downloaded over http(s) with a 10 s timeout and a 5 MB cap (JPEG, PNG, GIF, HEIC); on failure the original content is shown. ObjC hosts can call `ComraidBridge.shared.enrichNotificationRequest(_:completion:)`.

### Models

| Type | Role |
|------|------|
| `ComRaidConfiguration` | App ID, API base URL, `APNsEnvironment`, optional storage suite, `displayForegroundNotifications` |
| `APNsEnvironment` | `.sandbox` / `.production` |
| `DeviceProperties` | Subscription Properties for register / token refresh |
| `RemoteMessageEvent` / `RemoteMessageAction` | RNFirebase-shaped receive/open payload (`imageUrl`, `subtitle`, `sound`, `badge`, `threadId`, `androidChannelId`, `priority`) |
| `ComRaidListenerToken` | Opaque token for removing receive listeners |
| `RemoteDisplayPolicy` | Foreground presentation options for data_only / alert |
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
| `invalidIdentifier` | Empty External user ID |
| `triggerMustBeInFuture` | Invalid schedule/timer duration or past trigger |
| `timerNotFound` | Unknown timer id |
| `timerNotPaused` | Pause/resume state mismatch |
| `persistenceFailed` | Local store write failed after scheduling |
| `apiError(String)` | Mobile API failure message |

## Objective-C bridge

`ComRaidObjCBridge` (`@objc(ComraidBridge)`) exposes a **subset** of the Swift API for React Native / ObjC hosts: configure (including `displayForegroundNotifications`), APNs token, permission, register, login/logout, opt-in/out, capabilities, schedule/cancel/pendingSchedules, `startTimer`, `setDeviceProperties`, Attributes, ACK helpers, `getToken`, `getInitialNotification`, `presentNotification`, `enrichNotificationRequest` (Notification Service Extension), receive event emitter, and remote handle/presentation helpers.

It does **not** mirror full Swift parity (for example timer pause/resume/list, `onPushTokenRefresh`, or direct `RemoteNotificationDisplay` builders). Prefer the Swift `ComRaid` actor when possible.

## Sessions

`POST /mobile/subscriptions/{id}/session` runs automatically from the SDK on eligible
foregrounds (see Automatic Properties and sessions). Hosts should not call it directly
and should not invent a public client method.

## Tests

```bash
swift test
```
