import Foundation

// Checks GitHub Releases for a newer version, at most once a day (Settings >
// General turns it off). It only reads the public release list: nothing
// about you or your scripts is sent, and audio never leaves the Mac.
enum Updates {
  static let latestURL = URL(string: "https://api.github.com/repos/JoeKarlsson/followspot/releases/latest")!
  static let releasesPage = URL(string: "https://github.com/JoeKarlsson/followspot/releases")!

  struct Release {
    let version: String
    let page: URL
  }

  static var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  // "v0.2.0" > "0.1.0". Numeric per component, so 0.10 > 0.9. A pre-release
  // suffix ("-beta.1") is ignored; only published releases reach us anyway.
  static func isNewer(_ tag: String, than current: String) -> Bool {
    func parts(_ version: String) -> [Int] {
      var v = version.trimmingCharacters(in: .whitespaces)
      if v.lowercased().hasPrefix("v") { v.removeFirst() }
      let core = v.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
      return core.split(separator: ".").map { Int($0) ?? 0 }
    }
    let a = parts(tag)
    let b = parts(current)
    for i in 0..<max(a.count, b.count) {
      let x = i < a.count ? a[i] : 0
      let y = i < b.count ? b[i] : 0
      if x != y { return x > y }
    }
    return false
  }

  static func release(from json: Data) -> Release? {
    guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let tag = obj["tag_name"] as? String,
      obj["draft"] as? Bool != true, obj["prerelease"] as? Bool != true
    else { return nil }
    let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
    return Release(version: tag, page: page)
  }

  // The newest release if it's newer than this build. `force` skips the
  // once-a-day limit (Check for Updates…). nil on any error: offline is fine.
  static func check(force: Bool) async -> Release? {
    let defaults = UserDefaults.standard
    let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
    guard force || Date().timeIntervalSince(last) > 24 * 60 * 60 else { return nil }
    var request = URLRequest(url: latestURL)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 10
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    defaults.set(Date(), forKey: "lastUpdateCheck")
    guard let release = release(from: data), isNewer(release.version, than: currentVersion) else { return nil }
    return release
  }
}
