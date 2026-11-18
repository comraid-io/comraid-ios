import Foundation
import Testing

/// The README method reference must document every public Live activity method.
private func readme() throws -> String {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  return try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
}

@Test func theReadmeDocumentsEveryLiveActivityMethod() throws {
  let text = try readme()
  #expect(text.contains("### Live activities"))
  for heading in [
    "#### `trackActivity(_:id:type:)`",
    "#### `trackRunningActivities(of:type:id:)`",
    "#### `endActivity(id:)`",
    "#### `trackedActivities()`",
  ] {
    #expect(text.contains(heading), "README must document \(heading)")
  }
}

@Test func theReadmeSaysWhatLiveActivitiesNeed() throws {
  let text = try readme()
  #expect(text.contains("iOS 16.2"))
  #expect(text.contains("pushType: .token"))
  #expect(text.contains("NSSupportsLiveActivities"))
}
