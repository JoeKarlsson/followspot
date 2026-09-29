// swift-tools-version:5.9
// The macOS app: a native window around the same page ./followspot serves.
// Build the .app with macos/build.sh; `swift build` alone only makes the binary.
import PackageDescription

let package = Package(
  name: "Followspot",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "Followspot", path: "Sources/Followspot")
  ]
)
