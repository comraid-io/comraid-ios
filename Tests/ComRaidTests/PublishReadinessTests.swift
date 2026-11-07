import Foundation
import Testing

@Test func podspecAndPackageAgreeOnMinimumIOSVersion() throws {
  let root = packageRoot()
  let podspec = try String(
    contentsOf: root.appendingPathComponent("ComRaid.podspec"),
    encoding: .utf8
  )
  let manifest = try String(
    contentsOf: root.appendingPathComponent("Package.swift"),
    encoding: .utf8
  )
  #expect(podspec.contains("spec.ios.deployment_target = \"15.0\""))
  #expect(manifest.contains(".iOS(.v15)"))
  #expect(!manifest.contains(".macOS"))
  #expect(!podspec.contains("spec.osx"))
  #expect(!podspec.contains("spec.macos"))
}

@Test func podspecSourceTagMatchesVersionWithoutVPrefix() throws {
  let podspec = try String(
    contentsOf: packageRoot().appendingPathComponent("ComRaid.podspec"),
    encoding: .utf8
  )
  #expect(podspec.contains("spec.version = \"0.1.0\""))
  #expect(podspec.contains("tag: spec.version.to_s"))
  #expect(!podspec.contains("\"v#{"))
  #expect(!podspec.contains("\"v\" +"))
  #expect(!podspec.contains("\"v\\("))
}

@Test func readmeDocumentsReleaseTagScheme() throws {
  let readme = try String(
    contentsOf: packageRoot().appendingPathComponent("README.md"),
    encoding: .utf8
  )
  #expect(readme.contains("## Releasing"))
  #expect(readme.contains("`0.1.0`"))
  #expect(
    readme.contains("no `v` prefix") || readme.contains("without a `v` prefix"),
    "README must document tags without a v prefix"
  )
  #expect(readme.contains("ComRaid.podspec"))
  #expect(readme.contains("pod lib lint"))
}

private func packageRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
