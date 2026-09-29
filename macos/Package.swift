// swift-tools-version:5.9
// The macOS app: a native window around the same page ./followspot serves.
// Build the .app with macos/build.sh; `swift build` alone only makes the binary.
import PackageDescription

let package = Package(
  name: "Followspot",
  platforms: [.macOS(.v14)],
  targets: [
    // Tests aren't a SwiftPM target: Swift Testing's macros (like SwiftUI's)
    // need Xcode. macos/test.sh compiles them with the app's non-UI sources.
    .executableTarget(name: "Followspot", path: "Sources/Followspot")
  ]
)
