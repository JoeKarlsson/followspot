import Foundation

// The web root whisper-server serves. It's a folder of symlinks: one per file
// in the bundled public/, plus current.md pointing at the open script. This is
// the launcher's public/current.md trick moved somewhere writable; the page's
// 2 s poll of current.md then picks up edits with no changes to the page.
enum Staging {
  static func prepare() throws {
    guard let source = Paths.publicDir else {
      throw NSError(
        domain: "Followspot", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The prompter page (public/) is missing from the app."])
    }
    let fm = FileManager.default
    for item in (try? fm.contentsOfDirectory(atPath: Paths.www.path)) ?? [] {
      try fm.removeItem(at: Paths.www.appendingPathComponent(item))
    }
    for item in try fm.contentsOfDirectory(atPath: source.path) where item != "current.md" {
      try fm.createSymbolicLink(
        at: Paths.www.appendingPathComponent(item), withDestinationURL: source.appendingPathComponent(item))
    }
    if let script = currentScript { try link(script) }
  }

  // The last script opened, if it still exists.
  static var currentScript: URL? {
    guard let path = UserDefaults.standard.string(forKey: "script"),
      FileManager.default.fileExists(atPath: path)
    else { return nil }
    return URL(fileURLWithPath: path)
  }

  static func setScript(_ url: URL) throws {
    try link(url)
    UserDefaults.standard.set(url.path, forKey: "script")
    var recent = recentScripts.filter { $0 != url }
    recent.insert(url, at: 0)
    UserDefaults.standard.set(recent.prefix(10).map(\.path), forKey: "recentScripts")
  }

  static var recentScripts: [URL] {
    (UserDefaults.standard.stringArray(forKey: "recentScripts") ?? [])
      .filter { FileManager.default.fileExists(atPath: $0) }
      .map { URL(fileURLWithPath: $0) }
  }

  static func clearRecent() {
    UserDefaults.standard.removeObject(forKey: "recentScripts")
  }

  private static func link(_ script: URL) throws {
    let dest = Paths.www.appendingPathComponent("current.md")
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: script.standardizedFileURL)
  }
}
