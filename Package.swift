// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ImmichMacOS",
  platforms: [
    .macOS(.v14),
  ],
  products: [
    .executable(name: "ImmichMacApp", targets: ["ImmichMacApp"]),
    .library(name: "ImmichAPI", targets: ["ImmichAPI"]),
    .library(name: "ImmichCore", targets: ["ImmichCore"]),
    .library(name: "ImmichPersistence", targets: ["ImmichPersistence"]),
    .library(name: "ImmichMedia", targets: ["ImmichMedia"]),
    .library(name: "ImmichSync", targets: ["ImmichSync"]),
  ],
  targets: [
    .target(name: "ImmichCore"),
    .target(
      name: "ImmichAPI",
      dependencies: ["ImmichCore"]
    ),
    .target(
      name: "ImmichPersistence",
      dependencies: ["ImmichCore"]
    ),
    .target(
      name: "ImmichMedia",
      dependencies: ["ImmichCore"]
    ),
    .target(
      name: "ImmichSync",
      dependencies: ["ImmichCore", "ImmichAPI"]
    ),
    .executableTarget(
      name: "ImmichMacApp",
      dependencies: ["ImmichCore", "ImmichAPI", "ImmichPersistence", "ImmichMedia", "ImmichSync"]
    ),
    .testTarget(
      name: "ImmichAPITests",
      dependencies: ["ImmichAPI", "ImmichCore"]
    ),
    .testTarget(
      name: "ImmichMacAppTests",
      dependencies: ["ImmichMacApp", "ImmichAPI", "ImmichCore"]
    ),
  ]
)
