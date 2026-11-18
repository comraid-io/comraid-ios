import Foundation
import Testing
@testable import ComRaid

/// Seam: `InAppMessageManager`, the core of In-app messages on iOS. It is driven with a fake
/// fetcher, display, ACK sink, clock and store; nothing here needs a window or a network.

private final class MemoryStore: AckQueueStore, @unchecked Sendable {
  private let lock = NSLock()
  private var map: [String: String] = [:]
  func get(_ key: String) -> String? { lock.withLock { map[key] } }
  func set(_ key: String, value: String) { lock.withLock { map[key] = value } }
}

private final class RecordingAcks: InAppAckSink, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  var events: [String] { lock.withLock { recorded } }
  func delivered(deliveryId: String, token: String) async { lock.withLock { recorded.append("delivered:\(deliveryId):\(token)") } }
  func opened(deliveryId: String, token: String, actionId: String?) async {
    lock.withLock { recorded.append("opened:\(deliveryId):\(token):\(actionId ?? "nil")") }
  }
  func dismissed(deliveryId: String, token: String) async { lock.withLock { recorded.append("dismissed:\(deliveryId):\(token)") } }
}

private final class RecordingListener: InAppMessageListener, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  var events: [String] { lock.withLock { recorded } }
  func willDisplay(_ message: InAppMessage) { lock.withLock { recorded.append("willDisplay:\(message.id)") } }
  func didDisplay(_ message: InAppMessage) { lock.withLock { recorded.append("didDisplay:\(message.id)") } }
  func willDismiss(_ message: InAppMessage) { lock.withLock { recorded.append("willDismiss:\(message.id)") } }
  func didDismiss(_ message: InAppMessage) { lock.withLock { recorded.append("didDismiss:\(message.id)") } }
  func didClick(_ message: InAppMessage, button: InAppButton) {
    lock.withLock { recorded.append("didClick:\(message.id):\(button.id):\(button.deepLink ?? "nil")") }
  }
}

@MainActor
private final class FakeDisplay: InAppDisplay {
  var available = true
  var shown: [InAppMessage] = []
  var lastHandle: (any InAppMessageHandle)?
  func isAvailable() -> Bool { available }
  func show(_ message: InAppMessage, handle: any InAppMessageHandle) -> Bool {
    guard available else { return false }
    shown.append(message)
    lastHandle = handle
    return true
  }
}

/// Holds a fetch open until the test releases it, to interleave other calls with an in-flight fetch.
private final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var waiter: CheckedContinuation<Void, Never>?
  private var opened = false
  private var entered = false

  var hasEntered: Bool { lock.withLock { entered } }

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      entered = true
      if opened {
        lock.unlock()
        continuation.resume()
      } else {
        waiter = continuation
        lock.unlock()
      }
    }
  }

  func open() {
    lock.lock()
    opened = true
    let pending = waiter
    waiter = nil
    lock.unlock()
    pending?.resume()
  }

  func waitUntilEntered() async {
    for _ in 0..<2_000 where !hasEntered { await Task.yield() }
  }
}

private final class Fixture: @unchecked Sendable {
  let store = MemoryStore()
  let acks = RecordingAcks()
  let listener = RecordingListener()
  let clock = NowBox()
  let lock = NSLock()
  private var _fetched: [FetchedInAppMessage] = []
  private var _fails = false
  var gate: Gate?
  /// When true only the first fetch waits on `gate`; later fetches return at once.
  var gateFirstFetchOnly = false
  private var fetchCount = 0

  var fetched: [FetchedInAppMessage] {
    get { lock.withLock { _fetched } }
    set { lock.withLock { _fetched = newValue } }
  }
  var fetchFails: Bool {
    get { lock.withLock { _fails } }
    set { lock.withLock { _fails = newValue } }
  }

  @MainActor let display = FakeDisplay()

  @MainActor
  func manager(store customStore: (any AckQueueStore)? = nil) -> InAppMessageManager {
    InAppMessageManager(
      fetcher: { [self] in
        let call = lock.withLock { () -> Int in fetchCount += 1; return fetchCount }
        if let gate, !gateFirstFetchOnly || call == 1 { await gate.wait() }
        if fetchFails { throw ComRaidError.apiError("offline") }
        return fetched
      },
      acks: acks,
      store: customStore ?? store,
      stateKey: "state:test",
      clock: { [clock] in clock.now },
      display: display
    )
  }
}

private final class NowBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_000_000)
  var now: Date {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}

private func msg(
  _ id: String,
  start: Date? = nil,
  end: Date? = nil,
  test: Bool = false,
  buttons: [InAppButton] = [InAppButton(id: "open", label: "Open", deepLink: "myapp://x")]
) -> FetchedInAppMessage {
  FetchedInAppMessage(
    message: InAppMessage(
      id: id, layout: .modal, title: "Title \(id)", body: "Body \(id)",
      buttons: buttons, startAt: start, endAt: end, isTest: test
    ),
    deliveryId: test ? nil : "delivery-\(id)",
    attributionToken: test ? nil : "token-\(id)"
  )
}

private func settle(_ handle: (any InAppMessageHandle)?) async {
  await (handle as? InAppOutcomeHandle)?.settle()
}

@MainActor private func shownIds(_ f: Fixture) -> [String] { f.display.shown.map(\.id) }

@Test @MainActor func foregroundFetchesAndShowsTheOldestMessageOncePerForeground() async {
  let f = Fixture()
  f.fetched = [msg("a"), msg("b")]
  let manager = f.manager()

  await manager.onForeground()
  #expect(shownIds(f) == ["a"])

  await manager.onHostReady() // a second message is not shown in the same foreground
  #expect(shownIds(f) == ["a"])

  await manager.onForeground() // the next foreground shows the next message, never one already shown
  #expect(shownIds(f) == ["a", "b"])
  await manager.onForeground()
  #expect(shownIds(f) == ["a", "b"])
}

@Test @MainActor func cachedMessagesSurviveARestartAndAreNotShownTwice() async {
  let f = Fixture()
  f.fetched = [msg("a")]
  await f.manager().onForeground() // shows and caches "a"
  f.display.shown.removeAll()

  f.fetched = [msg("a"), msg("b")]
  await f.manager().onForeground() // a fresh manager over the same store: "a" already shown, "b" is new
  #expect(shownIds(f) == ["b"])

  f.display.shown.removeAll()
  f.fetchFails = true
  await f.manager().onForeground() // offline after a restart: nothing new in the cache
  #expect(f.display.shown.isEmpty)
}

@Test @MainActor func aFailedFetchStillShowsWhatWasCachedEarlier() async {
  let f = Fixture()
  f.fetched = [msg("a"), msg("b")]
  let manager = f.manager()
  await manager.onForeground() // shows a, caches a and b
  f.display.shown.removeAll()

  f.fetchFails = true
  await manager.onForeground() // offline, but "b" is cached
  #expect(shownIds(f) == ["b"])
}

@Test @MainActor func messagesOutsideTheirDisplayWindowAreNotShown() async {
  let f = Fixture()
  let now = f.clock.now
  f.fetched = [
    msg("future", start: now.addingTimeInterval(60)),
    msg("expired", end: now.addingTimeInterval(-60)),
    msg("open", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60)),
  ]
  await f.manager().onForeground()

  #expect(shownIds(f) == ["open"])
}

@Test @MainActor func aPausedManagerShowsNothingUntilResumed() async {
  let f = Fixture()
  f.fetched = [msg("a")]
  let manager = f.manager()
  await manager.setPaused(true)

  await manager.onForeground()
  #expect(f.display.shown.isEmpty)

  await manager.setPaused(false)
  await manager.onHostReady()
  #expect(shownIds(f) == ["a"])
}

@Test @MainActor func aMessageWaitsForAWindowInsteadOfBeingLost() async {
  let f = Fixture()
  f.fetched = [msg("a")]
  f.display.available = false
  let manager = f.manager()
  await manager.addListener(f.listener)

  await manager.onForeground()
  await manager.onHostReady()
  #expect(f.display.shown.isEmpty)
  #expect(f.listener.events.isEmpty) // nothing was drawn, so nothing is announced

  f.display.available = true
  await manager.onHostReady()
  #expect(shownIds(f) == ["a"])
  #expect(f.listener.events == ["willDisplay:a"])
}

@Test @MainActor func aPresenterReceivesTheMessageHandleAndTriggersInsteadOfTheDefaultLayout() async {
  let f = Fixture()
  f.fetched = [msg("a")]
  let manager = f.manager()
  await manager.addTrigger(key: "screen", value: "checkout")
  let received = PresenterCapture()
  await manager.setPresenter { message, handle, triggers in
    received.record(message, handle, triggers)
  }

  await manager.onForeground()

  #expect(received.messages.map(\.id) == ["a"])
  #expect(received.triggers == ["screen": "checkout"])
  #expect(f.display.shown.isEmpty) // the default layout must not draw when a presenter is set
}

@MainActor
private final class PresenterCapture {
  var messages: [InAppMessage] = []
  var handles: [any InAppMessageHandle] = []
  var triggers: [String: String] = [:]
  func record(_ message: InAppMessage, _ handle: any InAppMessageHandle, _ triggers: [String: String]) {
    messages.append(message)
    handles.append(handle)
    self.triggers = triggers
  }
}

@Test @MainActor func theHandleReportsImpressionAndClickThroughTheAckSink() async {
  let f = Fixture()
  f.fetched = [msg("a")]
  let manager = f.manager()
  let capture = PresenterCapture()
  await manager.setPresenter { capture.record($0, $1, $2) }
  await manager.onForeground()
  let handle = capture.handles[0]

  handle.impression()
  handle.impression() // a repeat is ignored
  handle.clicked(buttonId: "open")
  await settle(handle)

  #expect(f.acks.events == ["delivered:delivery-a:token-a", "opened:delivery-a:token-a:open"])
}

@Test @MainActor func aClickOnAnUnknownButtonIsIgnored() async {
  let f = Fixture()
  f.fetched = [msg("a")]
  let manager = f.manager()
  let capture = PresenterCapture()
  await manager.setPresenter { capture.record($0, $1, $2) }
  await manager.onForeground()

  capture.handles[0].clicked(buttonId: "not-a-button")
  await settle(capture.handles[0])

  #expect(f.acks.events.isEmpty)
}

@Test @MainActor func aDismissalWithoutAClickIsAcknowledgedOnce() async {
  let f = Fixture()
  f.fetched = [msg("a")]
  let manager = f.manager()
  let capture = PresenterCapture()
  await manager.setPresenter { capture.record($0, $1, $2) }
  await manager.onForeground()
  let handle = capture.handles[0]

  handle.impression()
  handle.dismissed()
  handle.dismissed()
  await settle(handle)

  #expect(f.acks.events == ["delivered:delivery-a:token-a", "dismissed:delivery-a:token-a"])
}

@Test @MainActor func closingAfterAClickCompletesTheLifecycleButIsNotADismissalAck() async {
  let f = Fixture()
  f.fetched = [msg("a")]
  let manager = f.manager()
  await manager.addListener(f.listener)
  let capture = PresenterCapture()
  await manager.setPresenter { capture.record($0, $1, $2) }
  await manager.onForeground()
  let handle = capture.handles[0]

  handle.impression()
  handle.clicked(buttonId: "open")
  handle.dismissed() // the layout closing after the tap
  await settle(handle)

  #expect(f.acks.events == ["delivered:delivery-a:token-a", "opened:delivery-a:token-a:open"])
  #expect(f.listener.events.contains("willDismiss:a"))
  #expect(f.listener.events.contains("didDismiss:a"))
}

@Test @MainActor func aTestSendIsShownButNeverAcknowledged() async {
  let f = Fixture()
  f.fetched = [msg("t", test: true)]
  let manager = f.manager()
  await manager.addListener(f.listener)
  await manager.onForeground()
  let handle = f.display.lastHandle

  handle?.impression()
  handle?.clicked(buttonId: "open")
  handle?.dismissed()
  await settle(handle)

  #expect(shownIds(f) == ["t"])
  #expect(f.acks.events.isEmpty)
  #expect(f.listener.events.contains("didDisplay:t"))
}

@Test @MainActor func listenersSeeTheDisplayClickAndDismissLifecycleInOrderUntilRemoved() async {
  let f = Fixture()
  f.fetched = [msg("a"), msg("b")]
  let manager = f.manager()
  let token = await manager.addListener(f.listener)
  await manager.onForeground()
  let handle = f.display.lastHandle

  handle?.impression()
  handle?.clicked(buttonId: "open")
  handle?.dismissed()
  await settle(handle)

  #expect(f.listener.events == [
    "willDisplay:a", "didDisplay:a", "didClick:a:open:myapp://x", "willDismiss:a", "didDismiss:a",
  ])

  await manager.removeListener(token)
  await manager.onForeground() // shows "b", which the removed listener must not hear about
  #expect(f.listener.events.count == 5)
}

@Test @MainActor func triggersCanBeAddedRemovedAndCleared() async {
  let f = Fixture()
  let manager = f.manager()
  await manager.addTrigger(key: "a", value: "1")
  await manager.addTriggers(["b": "2", "c": "3"])
  #expect(await manager.triggers() == ["a": "1", "b": "2", "c": "3"])

  await manager.removeTrigger(key: "b")
  #expect(await manager.triggers() == ["a": "1", "c": "3"])

  await manager.clearTriggers()
  #expect(await manager.triggers().isEmpty)
}

@Test @MainActor func clearingLocalStateDropsTheCacheSoNothingShowsAfterAnOptOut() async {
  let f = Fixture()
  f.fetched = [msg("a"), msg("b")]
  let manager = f.manager()
  await manager.onForeground() // shows a, caches b
  f.display.shown.removeAll()

  await manager.clearLocalState()
  f.fetched = [] // the server returns nothing for an opted-out Contact
  await manager.onForeground()

  #expect(f.display.shown.isEmpty)
}

@Test @MainActor func aMessageShownInThisProcessIsNotOfferedAgainBeforeTheServerCatchesUp() async {
  let f = Fixture()
  f.fetched = [msg("a")]
  let manager = f.manager()
  await manager.onForeground()
  f.display.shown.removeAll()

  await manager.onForeground() // the server still lists "a": its impression ACK is not processed yet
  #expect(f.display.shown.isEmpty)
}

@Test @MainActor func aStaleCachedMessageIsNotShownBeforeThisForegroundsFetchReturns() async {
  let f = Fixture()
  // An earlier run left "stale" in the cache without showing it.
  let seed: [String: Any] = ["messages": [msg("stale").toCacheJSON()], "shown": [String]()]
  f.store.set("state:test", value: String(decoding: try! JSONSerialization.data(withJSONObject: seed), as: UTF8.self))
  let gate = Gate()
  f.gate = gate
  let manager = f.manager()

  let foreground = Task { await manager.onForeground() } // the fetch is in flight
  await gate.waitUntilEntered()
  await manager.onHostReady() // a window appears meanwhile
  #expect(f.display.shown.isEmpty) // the stale cache must wait for the fetch

  f.fetched = [msg("fresh")] // the server no longer lists "stale"
  gate.open()
  await foreground.value

  #expect(shownIds(f) == ["fresh"])
}

@Test @MainActor func aFetchInFlightCannotBringBackMessagesAfterAnOptOut() async {
  let f = Fixture()
  let gate = Gate()
  f.gate = gate
  f.fetched = [msg("a")]
  let manager = f.manager()

  let foreground = Task { await manager.onForeground() }
  await gate.waitUntilEntered()
  await manager.clearLocalState() // the Contact opts out while the fetch runs
  gate.open()
  await foreground.value

  #expect(f.display.shown.isEmpty) // a pre-opt-out response must be dropped
}

@Test @MainActor func resetForgetsTheCacheAndWhatWasShown() async {
  let f = Fixture()
  f.fetched = [msg("a")]
  let manager = f.manager()
  await manager.onForeground()
  #expect(shownIds(f) == ["a"])
  f.display.shown.removeAll()

  await manager.reset() // e.g. logout: a different user may now be on this install
  await manager.onForeground()

  #expect(shownIds(f) == ["a"])
}

@Test @MainActor func aMessageTornDownBySomethingOtherThanTheUserIsShownAgain() async {
  let f = Fixture()
  f.fetched = [msg("a")]
  let manager = f.manager()
  await manager.onForeground()
  #expect(shownIds(f) == ["a"])

  (f.display.lastHandle as? InAppInterruptible)?.interrupted() // e.g. its window went away
  await settle(f.display.lastHandle)
  await manager.onHostReady()

  #expect(shownIds(f) == ["a", "a"])
}

@Test func theCacheKeyIsScopedToTheAppAndBackend() {
  let production = inAppStateKey(apiBaseURL: URL(string: "https://api.comraid.io/")!, appId: "cr_app_prod")
  #expect(production == inAppStateKey(apiBaseURL: URL(string: "https://api.comraid.io")!, appId: "cr_app_prod"))
  #expect(production != inAppStateKey(apiBaseURL: URL(string: "https://api.comraid.io")!, appId: "cr_app_other"))
  #expect(production != inAppStateKey(apiBaseURL: URL(string: "https://staging.comraid.io")!, appId: "cr_app_prod"))
}

@Test @MainActor func aNewerForegroundSupersedesAnOlderFetchStillInFlight() async {
  let f = Fixture()
  let gate = Gate()
  f.gate = gate
  f.gateFirstFetchOnly = true
  f.fetched = [msg("stale")]
  let manager = f.manager()

  let first = Task { await manager.onForeground() } // slow: held open
  await gate.waitUntilEntered()
  f.fetched = [msg("fresh")]
  await manager.onForeground() // the user came back: this newer foreground owns the result
  #expect(shownIds(f) == ["fresh"])

  gate.open()
  await first.value // the older fetch finishes late with the stale list

  #expect(shownIds(f) == ["fresh"]) // it must neither replace the cache nor show a second message
}
