import Foundation
import Testing
@testable import ComRaid

@Test func enqueueFromPayloadPersistsDeliveredAck() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )

  let enqueued = await queue.enqueueFromPayload(
    kind: .delivered,
    data: [
      "cr_delivery_id": "d1",
      "cr_attribution_token": "t1",
    ]
  )

  #expect(enqueued)
  let raw = storage.get(queue.storageKey())!
  let items = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [[String: Any]]
  #expect(items.count == 1)
  #expect(items[0]["kind"] as? String == "delivered")
  #expect(items[0]["deliveryId"] as? String == "d1")
}

@Test func flushPostsDeliveredAndClearsQueueOnSuccess() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  transport.nextResponse = HttpResponse(
    statusCode: 200,
    body: Data(#"{"delivery_id":"d1","status":"delivered"}"#.utf8)
  )
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )
  _ = await queue.enqueueFromPayload(
    kind: .delivered,
    data: ["cr_delivery_id": "d1", "cr_attribution_token": "t1"]
  )

  await queue.flush()

  let request = try! #require(transport.requests.first)
  #expect(request.method == "POST")
  #expect(request.path == "/deliveries/d1/delivered")
  let body = try! JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
  #expect(body["attribution_token"] as? String == "t1")
  #expect(storage.get(queue.storageKey()) == "[]")
}

@Test func flushPostsOpenedWithOptionalActionId() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  transport.nextResponse = HttpResponse(statusCode: 200, body: Data("{}".utf8))
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )
  _ = await queue.enqueueFromPayload(
    kind: .opened,
    data: ["cr_delivery_id": "d2", "cr_attribution_token": "t2"],
    actionId: "accept"
  )

  await queue.flush()

  let request = try! #require(transport.requests.first)
  #expect(request.path == "/deliveries/d2/opened")
  let body = try! JSONSerialization.jsonObject(with: #require(request.body)) as! [String: Any]
  #expect(body["action_id"] as? String == "accept")
  #expect(body["attribution_token"] as? String == "t2")
}

@Test func flushRetriesOn503AndKeepsEvent() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  transport.nextResponse = HttpResponse(statusCode: 503, body: Data("nope".utf8))
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )
  _ = await queue.enqueueFromPayload(
    kind: .opened,
    data: ["cr_delivery_id": "d3", "cr_attribution_token": "t3"]
  )

  await queue.flush()

  #expect(transport.requests.count == 1)
  let remaining = try! JSONSerialization.jsonObject(with: Data(storage.get(queue.storageKey())!.utf8)) as! [[String: Any]]
  #expect(remaining.count == 1)
  #expect(remaining[0]["deliveryId"] as? String == "d3")
  #expect((remaining[0]["attempts"] as? NSNumber)?.intValue == 1)
}

@Test func flushHonorsRetryAfterSecondsOn429() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  let clock = MutableClock(1_000_000)
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { clock.now }
  )
  transport.nextResponse = HttpResponse(
    statusCode: 429,
    body: Data("rate".utf8),
    headers: ["Retry-After": "30"]
  )
  _ = await queue.enqueueFromPayload(
    kind: .delivered,
    data: ["cr_delivery_id": "d4", "cr_attribution_token": "t4"]
  )

  await queue.flush()

  let remaining = try! JSONSerialization.jsonObject(with: Data(storage.get(queue.storageKey())!.utf8)) as! [[String: Any]]
  #expect((remaining[0]["nextAttemptAt"] as? NSNumber)?.int64Value == 1_030_000)

  transport.clearRequests()
  transport.nextResponse = HttpResponse(statusCode: 200, body: Data("{}".utf8))
  clock.now = 1_020_000
  await queue.flush()
  #expect(transport.requests.isEmpty)

  clock.now = 1_030_000
  await queue.flush()
  #expect(transport.requests.count == 1)
  #expect(storage.get(queue.storageKey()) == "[]")
}

@Test func flushDropsTerminal404() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  transport.nextResponse = HttpResponse(statusCode: 404, body: Data("missing".utf8))
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )
  _ = await queue.enqueueFromPayload(
    kind: .delivered,
    data: ["cr_delivery_id": "d5", "cr_attribution_token": "t5"]
  )

  await queue.flush()

  #expect(storage.get(queue.storageKey()) == "[]")
}

@Test func enqueueFromPayloadReturnsFalseWithoutAttribution() async {
  let storage = InMemoryAckQueueStore()
  let transport = RecordingTransport()
  let queue = AckQueue(
    apiBaseURL: URL(string: "https://api.example.com")!,
    store: storage,
    transport: transport,
    clock: { 1_000_000 }
  )

  let ok = await queue.enqueueFromPayload(kind: .delivered, data: ["foo": "bar"])
  #expect(ok == false)
  #expect(storage.get(queue.storageKey()) == nil)
}

private final class MutableClock: @unchecked Sendable {
  var now: Int64
  init(_ now: Int64) { self.now = now }
}

private final class InMemoryAckQueueStore: AckQueueStore, @unchecked Sendable {
  private let lock = NSLock()
  private var map: [String: String] = [:]

  func get(_ key: String) -> String? {
    lock.withLock { map[key] }
  }

  func set(_ key: String, value: String) {
    lock.withLock { map[key] = value }
  }
}

private final class RecordingTransport: HttpTransport, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requests: [HttpRequest] = []
  var nextResponse: HttpResponse?

  func clearRequests() {
    lock.withLock { requests.removeAll() }
  }

  func execute(_ request: HttpRequest) async throws -> HttpResponse {
    lock.withLock {
      requests.append(request)
      guard let nextResponse else { fatalError("No response configured") }
      return nextResponse
    }
  }
}
