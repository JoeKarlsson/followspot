import Foundation

// App-level settings, stored in UserDefaults (so `defaults write` works too).
// The prompter's own settings (text size, mic, camera, ...) stay in the page's
// localStorage; the Devices tab edits those through the page.
final class AppSettings: ObservableObject {
  static let shared = AppSettings()
  static let changed = Notification.Name("FollowspotSettingsChanged")

  enum Key: String {
    case keepAwake, hideFromCapture, floatOnTop, globalHotkeys, fastMode, vad, scriptsFolder, port, extraArgs
    case checkForUpdates
  }

  private let defaults = UserDefaults.standard

  @Published var keepAwake: Bool { didSet { store(.keepAwake, keepAwake) } }
  @Published var hideFromCapture: Bool { didSet { store(.hideFromCapture, hideFromCapture) } }
  @Published var floatOnTop: Bool { didSet { store(.floatOnTop, floatOnTop) } }
  @Published var globalHotkeys: Bool { didSet { store(.globalHotkeys, globalHotkeys) } }
  // -ac 512 on medium/large models: Whisper pads every request to 30 s of
  // audio; 512 frames (~10 s) still covers the longest listen window. See
  // Server.isLarge for the measurements.
  @Published var fastMode: Bool { didSet { store(.fastMode, fastMode) } }
  @Published var vad: Bool { didSet { store(.vad, vad) } }
  @Published var checkForUpdates: Bool { didSet { store(.checkForUpdates, checkForUpdates) } }
  @Published var scriptsFolder: String { didSet { store(.scriptsFolder, scriptsFolder) } }
  // Port and extra flags only take effect on Apply, not per keystroke.
  @Published var port: Int
  @Published var extraArgs: String

  private init() {
    func bool(_ key: Key, _ fallback: Bool) -> Bool {
      UserDefaults.standard.object(forKey: key.rawValue) as? Bool ?? fallback
    }
    _keepAwake = Published(initialValue: bool(.keepAwake, true))
    _hideFromCapture = Published(initialValue: bool(.hideFromCapture, false))
    _floatOnTop = Published(initialValue: bool(.floatOnTop, false))
    _globalHotkeys = Published(initialValue: bool(.globalHotkeys, true))
    _fastMode = Published(initialValue: bool(.fastMode, true))
    _vad = Published(initialValue: bool(.vad, true))
    _checkForUpdates = Published(initialValue: bool(.checkForUpdates, true))
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    _scriptsFolder = Published(
      initialValue: UserDefaults.standard.string(forKey: Key.scriptsFolder.rawValue)
        ?? docs.appendingPathComponent("Followspot").path)
    _port = Published(initialValue: Server.port)
    _extraArgs = Published(initialValue: AppSettings.storedExtraArgs.joined(separator: " "))
  }

  var scriptsURL: URL { URL(fileURLWithPath: scriptsFolder, isDirectory: true) }

  // `defaults write <id> extraArgs -array -ac 512` stores 512 as a number,
  // so take any value, not just strings.
  static var storedExtraArgs: [String] {
    (UserDefaults.standard.array(forKey: Key.extraArgs.rawValue) ?? []).map { "\($0)" }
  }

  // Saves port and extra flags; true if either changed (the server restarts).
  func applyServerOptions() -> Bool {
    let args = extraArgs.split(whereSeparator: \.isWhitespace).map(String.init)
    let changed = port != Server.port || args != AppSettings.storedExtraArgs
    defaults.set(port, forKey: Key.port.rawValue)
    defaults.set(args, forKey: Key.extraArgs.rawValue)
    return changed
  }

  private func store(_ key: Key, _ value: Any) {
    defaults.set(value, forKey: key.rawValue)
    NotificationCenter.default.post(name: AppSettings.changed, object: key)
  }
}
