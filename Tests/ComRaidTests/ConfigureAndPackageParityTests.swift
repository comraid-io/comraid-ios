import Foundation
import Testing
@testable import ComRaid

@Test func configureThrowsOnBlankAppId() async {
  let comraid = ComRaid()
  await #expect(throws: ComRaidError.invalidConfiguration("appId is required (cr_app_…)")) {
    try await comraid.configure(
      .init(appId: "   ", apnsEnvironment: .sandbox)
    )
  }
}

@Test func packageSwiftDeclaresIOSOnly() throws {
  let manifest = try String(
    contentsOf: packageRoot().appendingPathComponent("Package.swift"),
    encoding: .utf8
  )
  #expect(manifest.contains(".iOS(.v15)"))
  #expect(!manifest.contains(".macOS"))
}

@Test func objcBridgeExposesTokenRefreshTimersAndPermissionOptions() throws {
  let bridge = try String(
    contentsOf: packageRoot().appendingPathComponent("Sources/ComRaid/ComRaidObjCBridge.swift"),
    encoding: .utf8
  )
  #expect(bridge.contains("func onPushTokenRefresh("))
  #expect(bridge.contains("ComRaid.shared.onPushTokenRefresh"))
  #expect(bridge.contains("func pauseTimer("))
  #expect(bridge.contains("func resumeTimer("))
  #expect(bridge.contains("func cancelTimer("))
  #expect(bridge.contains("func timers("))
  #expect(bridge.contains("ComRaid.shared.pauseTimer"))
  #expect(bridge.contains("ComRaid.shared.resumeTimer"))
  #expect(bridge.contains("ComRaid.shared.cancelTimer"))
  #expect(bridge.contains("ComRaid.shared.timers"))
  #expect(bridge.contains("requestNotificationPermission("))
  #expect(bridge.contains("options:"))
  #expect(bridge.contains("authorizationOptions("))
}

private func packageRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
