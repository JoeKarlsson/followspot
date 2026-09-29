import Foundation

// The scripts folder (Settings > General; ~/Documents/Followspot by default).
// The control window lists, creates, and saves scripts here through the page
// bridge. The page never supplies a path to write to: saves go to the open
// script, and new scripts are created by name inside this folder.
enum Scripts {
  static var folder: URL { AppSettings.shared.scriptsURL }

  static func list() -> [URL] {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return items
      .filter { ["md", "txt"].contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
  }

  // Mirrors scriptFileName() in public/native.js, which the page checks first.
  static func fileName(_ input: String) -> String? {
    var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !name.hasPrefix("."), name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\\")) == nil
    else { return nil }
    if !["md", "txt"].contains((name as NSString).pathExtension.lowercased()) { name += ".md" }
    return name
  }

  static func create(name: String, text: String) throws -> URL {
    guard let file = fileName(name) else { throw error("“\(name)” isn't a usable file name.") }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(file)
    if FileManager.default.fileExists(atPath: url.path) { throw error("\(file) already exists.") }
    try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    return url
  }

  enum SaveResult { case saved, conflict }

  // Refuses (conflict) if the file no longer holds `base`, the text the edits
  // started from: someone changed it in another editor meanwhile. `force`
  // overwrites anyway, after the page has asked.
  static func save(_ text: String, to url: URL, base: String?, force: Bool) throws -> SaveResult {
    if !force, let base, let disk = try? String(contentsOf: url, encoding: .utf8), disk != base {
      return .conflict
    }
    try Data(text.utf8).write(to: url, options: .atomic)
    return .saved
  }

  // Replies to the page (see Bridge.swift). Paths are spelled out with
  // path(percentEncoded:) on purpose: in an untyped dictionary, `url.path`
  // can resolve to that method instead of the property, and WebKit then drops
  // the whole reply.
  static func saveReply(_ result: SaveResult, _ url: URL) -> [String: Any] {
    result == .conflict ? ["conflict": true] : ["saved": url.path(percentEncoded: false)]
  }

  static func listReply(current: URL?) -> [String: Any] {
    let current = current?.standardizedFileURL
    var scripts: [[String: String]] = list().map {
      ["name": $0.lastPathComponent, "path": $0.path(percentEncoded: false)]
    }
    // A script opened from elsewhere (⌘O) still shows, so it can be edited.
    if let current, !scripts.contains(where: { $0["path"] == current.path(percentEncoded: false) }) {
      scripts.insert(["name": current.lastPathComponent, "path": current.path(percentEncoded: false)], at: 0)
    }
    return [
      "folder": folder.path(percentEncoded: false),
      "folderName": folder.lastPathComponent,
      "current": current.map { $0.path(percentEncoded: false) } ?? NSNull(),
      "scripts": scripts,
    ]
  }

  // Paths the page may ask to open: ones it was shown, or the open one.
  static func isOpenable(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    let known = list() + Staging.recentScripts + [Staging.currentScript].compactMap { $0 }
    return known.contains { $0.standardizedFileURL.path == path }
  }

  static func error(_ message: String) -> NSError {
    NSError(domain: "Followspot", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
