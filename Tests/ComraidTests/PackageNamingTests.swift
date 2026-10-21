import Foundation
import Testing

@Test func legacyComraidPodspecRemains() throws {
  let root = packageRoot()
  let podspec = root.appendingPathComponent("Comraid.podspec")
  #expect(FileManager.default.fileExists(atPath: podspec.path))
  let contents = try String(contentsOf: podspec, encoding: .utf8)
  #expect(contents.contains("spec.name = \"Comraid\""))
}

@Test func comRaidPodspecExistsBesideLegacy() throws {
  let root = packageRoot()
  // Distinct path: APFS is case-insensitive, so ComRaid.podspec cannot sit beside Comraid.podspec.
  let podspec = root.appendingPathComponent("aliases/ComRaid.podspec")
  #expect(FileManager.default.fileExists(atPath: podspec.path))
  let contents = try String(contentsOf: podspec, encoding: .utf8)
  #expect(contents.contains("spec.name = \"ComRaid\""))
  #expect(contents.contains("../Sources/Comraid/**/*.swift"))
}

private func packageRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ComraidTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // package root
}
