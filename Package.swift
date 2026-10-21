// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ComRaid",
  platforms: [
    .iOS(.v15),
    .macOS(.v13),
  ],
  products: [
    .library(name: "ComRaid", targets: ["ComRaid"]),
  ],
  targets: [
    .target(name: "ComRaid"),
    .testTarget(name: "ComRaidTests", dependencies: ["ComRaid"]),
  ]
)
