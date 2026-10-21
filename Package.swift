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
    // Temporary product alias until ticket 04 contract.
    .library(name: "Comraid", targets: ["ComRaid"]),
  ],
  targets: [
    .target(name: "ComRaid"),
    .testTarget(name: "ComRaidTests", dependencies: ["ComRaid"]),
  ]
)
