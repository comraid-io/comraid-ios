Pod::Spec.new do |spec|
  spec.name = "Comraid"
  spec.version = "0.1.0"
  spec.summary = "Native Apple SDK for Comraide notifications and timers."
  spec.homepage = "https://github.com/comraide/comraid-ios"
  spec.license = { type: "MIT", file: "LICENSE" }
  spec.author = { "Comraide" => "engineering@comraide.com" }
  spec.source = { git: "https://github.com/comraide/comraid-ios.git", tag: spec.version.to_s }
  spec.ios.deployment_target = "15.0"
  spec.swift_version = "6.0"
  spec.source_files = "Sources/Comraid/**/*.swift"
  spec.frameworks = "Foundation", "UserNotifications"
end
