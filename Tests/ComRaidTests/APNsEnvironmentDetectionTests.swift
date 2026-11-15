import Foundation
import Testing
@testable import ComRaid

@Test func provisionDevelopmentMapsToSandbox() {
  let data = fakeProvisionData(apsEnvironment: "development")
  #expect(APNsEnvironmentDetector.apsEnvironmentValue(fromProvisionData: data) == "development")
  #expect(APNsEnvironmentDetector.detect(isSimulator: false, provisionData: data) == .sandbox)
}

@Test func provisionProductionMapsToProduction() {
  let data = fakeProvisionData(apsEnvironment: "production")
  #expect(APNsEnvironmentDetector.apsEnvironmentValue(fromProvisionData: data) == "production")
  #expect(APNsEnvironmentDetector.detect(isSimulator: false, provisionData: data) == .production)
}

@Test func simulatorDetectsSandboxEvenWithProductionProfile() {
  let data = fakeProvisionData(apsEnvironment: "production")
  #expect(APNsEnvironmentDetector.detect(isSimulator: true, provisionData: data) == .sandbox)
}

@Test func missingProvisionDetectsProduction() {
  #expect(APNsEnvironmentDetector.detect(isSimulator: false, provisionData: nil) == .production)
}

@Test func unparseableProvisionDetectsProduction() {
  let junk = Data("not a provisioning profile".utf8)
  #expect(APNsEnvironmentDetector.apsEnvironmentValue(fromProvisionData: junk) == nil)
  #expect(APNsEnvironmentDetector.detect(isSimulator: false, provisionData: junk) == .production)
}

@Test func configurationOverrideUsesExplicitEnvironment() {
  let sandbox = ComRaidConfiguration(appId: "cr_app_test", apnsEnvironment: .sandbox)
  let production = ComRaidConfiguration(appId: "cr_app_test", apnsEnvironment: .production)
  #expect(sandbox.apnsEnvironment == .sandbox)
  #expect(production.apnsEnvironment == .production)
}

@Test func configurationOmittingApnsEnvironmentUsesDetection() {
  let config = ComRaidConfiguration(appId: "cr_app_test")
  // Unit tests run on the iOS Simulator, where detection is always sandbox.
  #expect(config.apnsEnvironment == .sandbox)
}

@Test func objcBridgeRejectsUnknownApnsEnvironmentOverride() {
  let box = ErrorBox()
  ComRaidObjCBridge.shared.configure(
    appId: "cr_app_test",
    apiBaseURL: nil,
    apnsEnvironment: "staging",
    storageSuiteName: nil,
    displayForegroundNotifications: true
  ) { error in box.set(error) }
  #expect(box.get()?.code == 1004)
}

private final class ErrorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var error: NSError?
  func set(_ value: NSError?) { lock.withLock { error = value } }
  func get() -> NSError? { lock.withLock { error } }
}

private func fakeProvisionData(apsEnvironment: String) -> Data {
  // Real embedded.mobileprovision is CMS-wrapped; the detector scans for the plist.
  let plist = """
  noise-before
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>Entitlements</key>
    <dict>
      <key>aps-environment</key>
      <string>\(apsEnvironment)</string>
    </dict>
  </dict>
  </plist>
  trailing-noise
  """
  return Data(plist.utf8)
}
