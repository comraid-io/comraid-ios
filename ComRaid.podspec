Pod::Spec.new do |spec|
  spec.name = "ComRaid"
  spec.version = "0.1.0"
  spec.summary = "Native Apple SDK for ComRaid notifications, identity, and delivery ACKs."
  spec.homepage = "https://github.com/comraid-io/comraid-ios"
  spec.license = { type: "MIT", file: "LICENSE" }
  spec.author = { "ComRaid" => "engineering@comraid.io" }
  spec.source = { git: "https://github.com/comraid-io/comraid-ios.git", tag: spec.version.to_s }
  spec.ios.deployment_target = "15.0"
  spec.swift_version = "6.0"
  spec.source_files = "Sources/ComRaid/**/*.swift"
  spec.frameworks = "Foundation", "UserNotifications"
end
