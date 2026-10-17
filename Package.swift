// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Comraid",
  platforms: [
    .iOS(.v15),
    .macOS(.v13),
  ],
  products: [
    .library(name: "Comraid", targets: ["Comraid"]),
  ],
  targets: [
    .target(name: "Comraid"),
    .testTarget(name: "ComraidTests", dependencies: ["Comraid"]),
  ]
)
