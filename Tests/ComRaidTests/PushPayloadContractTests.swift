import Foundation
import Testing
@testable import ComRaid

/// Contract path: committed vendored copy at repo `contracts/push-payload/` (ADR 0017).
private enum PushPayloadContractFixtures {
  static var root: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // Tests/ComRaidTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // repo root
      .appendingPathComponent("contracts/push-payload", isDirectory: true)
  }

  static var contractURL: URL {
    root.appendingPathComponent("contract.json")
  }

  static var goldensDirectory: URL {
    root.appendingPathComponent("goldens", isDirectory: true)
  }
}

@Test func reservedKeySetEqualsContractKeyNames() throws {
  let data = try Data(contentsOf: PushPayloadContractFixtures.contractURL)
  let contract = try JSONDecoder().decode(PushPayloadContractFile.self, from: data)
  let contractNames = Set(contract.keys.map(\.name))
  #expect(PushPayload.reservedKeys == contractNames)
  #expect(contractNames.count == 16)
}

/// Seam: `PushPayload.fromUserInfo` → `RemoteMessageMapper.toEvent`.
/// Each golden's `pushPayload` must parse to its `expectedEvent` (FCM-only fields null as goldens specify).
@Test func goldenPushPayloadsParseToExpectedEvents() throws {
  let files = try FileManager.default.contentsOfDirectory(
    at: PushPayloadContractFixtures.goldensDirectory,
    includingPropertiesForKeys: nil
  )
  .filter { $0.pathExtension == "json" }
  .sorted { $0.lastPathComponent < $1.lastPathComponent }

  #expect(files.count == 10)

  for file in files {
    let data = try Data(contentsOf: file)
    let root = try JSONSerialization.jsonObject(with: data)
    guard let root = root as? [String: Any],
          let pushPayload = root["pushPayload"] as? [String: Any],
          let expectedObject = root["expectedEvent"] else {
      Issue.record("Golden \(file.lastPathComponent) missing pushPayload or expectedEvent")
      continue
    }
    let expectedData = try JSONSerialization.data(withJSONObject: expectedObject)
    let expected = try JSONDecoder().decode(GoldenExpectedEvent.self, from: expectedData)
    let actual = parseGoldenPushPayload(pushPayload)
    assertEvent(actual, equals: expected, golden: file.lastPathComponent)
  }
}

/// FCM goldens carry `data` + `android`; APNs goldens are the userInfo map (with `aps`).
private func parseGoldenPushPayload(_ pushPayload: [String: Any]) -> RemoteMessageEvent {
  let userInfo: [AnyHashable: Any]
  if let data = pushPayload["data"] as? [String: Any] {
    userInfo = data
  } else {
    userInfo = pushPayload
  }
  return RemoteMessageMapper.toEvent(PushPayload.fromUserInfo(userInfo))
}

private func assertEvent(
  _ actual: RemoteMessageEvent,
  equals expected: GoldenExpectedEvent,
  golden: String
) {
  #expect(actual.messageId == expected.messageId, "\(golden).messageId")
  #expect(actual.deliveryId == expected.deliveryId, "\(golden).deliveryId")
  #expect(actual.attributionToken == expected.attributionToken, "\(golden).attributionToken")
  #expect(actual.title == expected.title, "\(golden).title")
  #expect(actual.body == expected.body, "\(golden).body")
  #expect(actual.data == expected.data, "\(golden).data")
  #expect(actual.deepLink == expected.deepLink, "\(golden).deepLink")
  #expect(actual.actionId == expected.actionId, "\(golden).actionId")
  #expect(actual.imageUrl == expected.imageUrl, "\(golden).imageUrl")
  #expect(actual.subtitle == expected.subtitle, "\(golden).subtitle")
  #expect(actual.sound == expected.sound, "\(golden).sound")
  #expect(actual.badge == expected.badge, "\(golden).badge")
  #expect(actual.threadId == expected.threadId, "\(golden).threadId")
  #expect(actual.androidChannelId == expected.androidChannelId, "\(golden).androidChannelId")
  #expect(actual.priority == expected.priority, "\(golden).priority")

  let actualActions = actual.actions.map { GoldenExpectedAction(id: $0.id, text: $0.text, icon: $0.icon) }
  #expect(actualActions == expected.actions, "\(golden).actions")
}

private struct PushPayloadContractFile: Decodable {
  struct Key: Decodable {
    var name: String
  }

  var keys: [Key]
}

private struct GoldenExpectedEvent: Decodable {
  var messageId: String?
  var deliveryId: String?
  var attributionToken: String?
  var title: String?
  var body: String?
  var data: [String: String]
  var deepLink: String?
  var actions: [GoldenExpectedAction]
  var actionId: String?
  var imageUrl: String?
  var subtitle: String?
  var sound: String?
  var badge: Int?
  var threadId: String?
  var androidChannelId: String?
  var priority: String
}

private struct GoldenExpectedAction: Decodable, Equatable {
  var id: String
  var text: String
  var icon: String?
}
