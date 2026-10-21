Pod::Spec.new do |spec|
  # Compatibility alias. Prefer `pod 'ComRaid'`.
  spec.name = "Comraid"
  spec.version = "0.1.0"
  spec.summary = "Compatibility alias for the ComRaid Apple SDK (prefer pod 'ComRaid')."
  spec.homepage = "https://github.com/comraid-io/comraid-ios"
  spec.license = { type: "MIT", file: "LICENSE" }
  spec.author = { "ComRaid" => "engineering@comraid.io" }
  spec.source = { git: "https://github.com/comraid-io/comraid-ios.git", tag: spec.version.to_s }
  spec.ios.deployment_target = "15.0"
  spec.swift_version = "6.0"
  spec.source_files = "Sources/Comraid/**/*.swift"
  spec.frameworks = "Foundation", "UserNotifications"
  spec.deprecated_in_favor_of = "ComRaid"
end
