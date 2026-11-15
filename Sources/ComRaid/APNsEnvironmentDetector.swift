import Foundation

/// Resolves the APNs host label (sandbox vs production) from the app's
/// embedded provisioning profile. Config `apnsEnvironment` overrides this.
enum APNsEnvironmentDetector {
  /// Reads `aps-environment` from CMS-wrapped `embedded.mobileprovision` bytes.
  static func apsEnvironmentValue(fromProvisionData data: Data) -> String? {
    guard let plistData = extractPlistData(from: data),
          let root = try? PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
          ) as? [String: Any]
    else {
      return nil
    }
    if let entitlements = root["Entitlements"] as? [String: Any],
       let value = entitlements["aps-environment"] as? String {
      return value
    }
    return root["aps-environment"] as? String
  }

  /// Maps Apple's `aps-environment` entitlement to ComRaid's APNs label.
  static func environment(fromApsEnvironmentValue value: String) -> APNsEnvironment? {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "development":
      return .sandbox
    case "production":
      return .production
    default:
      return nil
    }
  }

  /// Detects sandbox vs production for registration.
  /// Simulator → sandbox; no/unparseable profile (App Store / TestFlight) → production.
  static func detect(isSimulator: Bool, provisionData: Data?) -> APNsEnvironment {
    if isSimulator {
      return .sandbox
    }
    guard let provisionData,
          let value = apsEnvironmentValue(fromProvisionData: provisionData),
          let environment = environment(fromApsEnvironmentValue: value)
    else {
      return .production
    }
    return environment
  }

  /// Live detection from the running app bundle.
  static func detect() -> APNsEnvironment {
    #if targetEnvironment(simulator)
    return detect(isSimulator: true, provisionData: nil)
    #else
    return detect(isSimulator: false, provisionData: loadEmbeddedProvision())
    #endif
  }

  private static func loadEmbeddedProvision() -> Data? {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
      return nil
    }
    return try? Data(contentsOf: url)
  }

  private static func extractPlistData(from data: Data) -> Data? {
    let xmlStart = Data("<?xml".utf8)
    let xmlEnd = Data("</plist>".utf8)
    guard let start = data.range(of: xmlStart),
          let end = data.range(of: xmlEnd, in: start.lowerBound..<data.endIndex)
    else {
      return nil
    }
    return data[start.lowerBound..<end.upperBound]
  }
}
