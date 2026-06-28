// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "SwiftStanLibrary",
  platforms: [
    .macOS(.v14),
  ],
  products: [
    .library(name: "SwiftStan", targets: ["SwiftStan"]),
  ],
  targets: [
    .target(name: "SwiftStan"),
    .testTarget(
      name: "SwiftStanLibraryTests",
      dependencies: ["SwiftStan"],
      resources: [.copy("Resources")]
    ),
  ]
)
