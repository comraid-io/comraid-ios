import Darwin
import Foundation
#if canImport(UIKit)
import UIKit
#endif

typealias DeviceInfoProvider = @Sendable () -> DeviceProperties

enum SystemDeviceInfo {
  static func collect(sdkVersion: String = SdkVersion.value) -> DeviceProperties {
    let locale = Locale.current
    let languageCode: String?
    let regionCode: String?
    if #available(iOS 16, *) {
      languageCode = locale.language.languageCode?.identifier
      regionCode = locale.region?.identifier
    } else {
      languageCode = locale.languageCode
      regionCode = locale.regionCode
    }
    let localeTag = locale.identifier.replacingOccurrences(of: "_", with: "-")
    #if canImport(UIKit) && !os(watchOS)
    let model: String? = deviceModelIdentifier()
    let osVersion: String? = UIDevice.current.systemVersion
    let osName = UIDevice.current.systemName
    #else
    let model: String? = nil
    let osVersion: String? = nil
    let osName = "iOS"
    #endif
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    return DeviceProperties(
      appVersion: appVersion?.nilIfBlank,
      sdkVersion: sdkVersion,
      model: model?.nilIfBlank,
      os: osName.nilIfBlank,
      osVersion: osVersion?.nilIfBlank,
      locale: localeTag.nilIfBlank,
      timezone: TimeZone.current.identifier.nilIfBlank,
      language: languageCode?.nilIfBlank,
      country: regionCode?.nilIfBlank
    )
  }

  #if canImport(UIKit) && !os(watchOS)
  private static func deviceModelIdentifier() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafePointer(to: &info.machine) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
  }
  #endif
}

func mergeDeviceProperties(auto: DeviceProperties, override: DeviceProperties?) -> DeviceProperties {
  guard let override else { return auto }
  return DeviceProperties(
    appVersion: override.appVersion ?? auto.appVersion,
    sdkVersion: override.sdkVersion ?? auto.sdkVersion,
    model: override.model ?? auto.model,
    os: override.os ?? auto.os,
    osVersion: override.osVersion ?? auto.osVersion,
    locale: override.locale ?? auto.locale,
    timezone: override.timezone ?? auto.timezone,
    language: override.language ?? auto.language,
    country: override.country ?? auto.country,
    extras: auto.extras.merging(override.extras) { _, new in new }
  )
}

private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
