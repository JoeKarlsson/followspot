import Foundation

// Where the app keeps things. Everything writable lives in
// ~/Library/Application Support/Followspot, because the signed bundle is
// read-only.
enum Paths {
  static let support: URL = {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Followspot", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  static let models = subdirectory("models")
  static let www = subdirectory("www")
  static let log = support.appendingPathComponent("server.log")
  static let pidFile = support.appendingPathComponent("server.pid")

  // The checkout this binary was built from, if it's still there. Lets a dev
  // build reuse the repo's models/ and run straight from `swift run`.
  static let repo: URL? = {
    let url = URL(fileURLWithPath: #filePath)  // macos/Sources/Followspot/Paths.swift
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let launcher = url.appendingPathComponent("followspot").path
    return FileManager.default.fileExists(atPath: launcher) ? url : nil
  }()

  // The page. Bundled by build.sh; the repo's public/ under `swift run`.
  static var publicDir: URL? {
    let candidates = [
      Bundle.main.resourceURL?.appendingPathComponent("public"),
      repo?.appendingPathComponent("public"),
    ]
    return candidates.compactMap { $0 }.first {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path)
    }
  }

  // Bundled next to the app binary; Homebrew's as a fallback for `swift run`.
  static var whisperServer: URL? {
    let candidates = [
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/whisper-server"),
      repo?.appendingPathComponent("macos/.whisper/whisper-server"),
      URL(fileURLWithPath: "/opt/homebrew/bin/whisper-server"),
      URL(fileURLWithPath: "/usr/local/bin/whisper-server"),
    ]
    return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  private static func subdirectory(_ name: String) -> URL {
    let url = support.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
