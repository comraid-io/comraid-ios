import Foundation
import Testing

@Test func primaryComRaidPodspecExists() throws {
  let root = packageRoot()
  let podspec = root.appendingPathComponent("ComRaid.podspec")
  #expect(FileManager.default.fileExists(atPath: podspec.path))
  let contents = try String(contentsOf: podspec, encoding: .utf8)
  #expect(contents.contains("spec.name = \"ComRaid\""))
  #expect(contents.contains("Sources/ComRaid/**/*.swift"))
}

@Test func legacyComraidPodspecRemainsAsAlias() throws {
  let root = packageRoot()
  // Distinct path: APFS is case-insensitive, so Comraid.podspec cannot sit beside ComRaid.podspec.
  let podspec = root.appendingPathComponent("aliases/Comraid.podspec")
  #expect(FileManager.default.fileExists(atPath: podspec.path))
  let contents = try String(contentsOf: podspec, encoding: .utf8)
  #expect(contents.contains("spec.name = \"Comraid\""))
  #expect(contents.contains("../Sources/ComRaid/**/*.swift"))
}

@Test func packageSwiftPrimaryProductIsComRaid() throws {
  let root = packageRoot()
  let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
  #expect(manifest.contains("name: \"ComRaid\""))
  #expect(manifest.contains(".library(name: \"ComRaid\""))
  #expect(manifest.contains(".library(name: \"Comraid\""))
}

private func packageRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ComRaidTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // package root
}
