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
  static let argsFile = support.appendingPathComponent("server.args")  // for macos/check-args.sh

  // The checkout a debug build (`swift run`) was built from, so it can use
  // the repo's public/, models/ and whisper-server without bundling. Release
  // builds (build.sh) never look outside the bundle and Application Support,
  // so the same .app works on any Mac.
  #if DEBUG
    static let repo: URL? = {
      let url = URL(fileURLWithPath: #filePath)  // macos/Sources/Followspot/Paths.swift
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let launcher = url.appendingPathComponent("followspot").path
      return FileManager.default.fileExists(atPath: launcher) ? url : nil
    }()
  #else
    static let repo: URL? = nil
  #endif

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

  // Bundled next to the app binary; the repo's build under `swift run`.
  static var whisperServer: URL? {
    let candidates = [
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/whisper-server"),
      repo?.appendingPathComponent("macos/.whisper/whisper-server"),
    ]
    return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  private static func subdirectory(_ name: String) -> URL {
    let url = support.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
