import Foundation
import Testing

/// Seam: the README documents every public In-app message method (the iOS counterpart of Android's
/// README method reference parity test).
@Test func readmeDocumentsEveryInAppMethod() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)

  let methods = [
    "setInAppMessagePresenter",
    "addInAppMessageListener",
    "removeInAppMessageListener",
    "addTrigger",
    "addTriggers",
    "removeTrigger",
    "clearTriggers",
    "getTriggers",
    "setInAppMessagesPaused",
    "isInAppMessagesPaused",
    "optOutInApp",
    "optInInApp",
  ]
  let missing = methods.filter { !readme.contains("#### `\($0)") }

  #expect(missing.isEmpty, "README must document each In-app method. Missing: \(missing)")
  #expect(readme.contains("### In-app messages"))
}
