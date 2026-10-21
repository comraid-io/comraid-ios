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

@Test func legacyComraidPodspecAliasIsRemoved() {
  let root = packageRoot()
  let podspec = root.appendingPathComponent("aliases/Comraid.podspec")
  #expect(!FileManager.default.fileExists(atPath: podspec.path))
  let aliasesDir = root.appendingPathComponent("aliases")
  #expect(!FileManager.default.fileExists(atPath: aliasesDir.path))
}

@Test func packageSwiftHasSingleComRaidProduct() throws {
  let root = packageRoot()
  let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
  #expect(manifest.contains("name: \"ComRaid\""))
  #expect(manifest.contains(".library(name: \"ComRaid\""))
  #expect(!manifest.contains(".library(name: \"Comraid\""))
}

@Test func publicTypeAliasesFileIsRemoved() {
  let aliases = packageRoot().appendingPathComponent("Sources/ComRaid/Aliases.swift")
  #expect(!FileManager.default.fileExists(atPath: aliases.path))
}

@Test func shippedSourcesContainNoComraideMisspelling() throws {
  let root = packageRoot()
  let needles = ["comraide", "Comraide", "com.comraide"]
  var offenders: [String] = []
  let fm = FileManager.default
  let enumerator = fm.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
  var files: [URL] = [
    root.appendingPathComponent("ComRaid.podspec"),
    root.appendingPathComponent("Package.swift"),
  ]
  while let url = enumerator.nextObject() as? URL {
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
      files.append(url)
    }
  }
  for file in files {
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    for needle in needles where text.contains(needle) {
      offenders.append("\(file.path):\(needle)")
    }
  }
  #expect(offenders.isEmpty, "shipped paths must not contain comraide misspellings: \(offenders)")
}

@Test func infoPlistStorageSuiteKeyIsComRaidOnly() throws {
  let bridge = try String(
    contentsOf: packageRoot().appendingPathComponent("Sources/ComRaid/ComRaidObjCBridge.swift"),
    encoding: .utf8
  )
  #expect(bridge.contains("ComRaidStorageSuiteName"))
  #expect(!bridge.contains("ComraidStorageSuiteName"))
}

private func packageRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ComRaidTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // package root
}
