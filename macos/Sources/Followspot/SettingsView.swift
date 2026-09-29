import SwiftUI

struct Device: Hashable {
  let id: String
  let label: String
}

// Mic and camera settings belong to the page (its localStorage), so this
// reads them from the prompter and writes back through its control channel,
// the same way the control window does. The page validates every value.
final class DevicesModel: ObservableObject {
  @Published var mics: [Device] = []
  @Published var cams: [Device] = []
  @Published var mic = ""
  @Published var cam = ""
  @Published var camera = false
  @Published var cameraOpacity = 25.0
  @Published var mirror = false
  @Published var connected = false
  @Published var labelsHidden = false

  var send: (([String: Any]) -> Void)?
  var fetch: (() async -> [String: Any]?)?

  @MainActor func refresh() async {
    guard let result = await fetch?() else {
      connected = false
      return
    }
    connected = true
    let devices = (result["devices"] as? [[String: Any]] ?? []).map {
      (kind: $0["kind"] as? String ?? "", id: $0["id"] as? String ?? "", label: $0["label"] as? String ?? "")
    }
    labelsHidden = devices.contains { $0.label.isEmpty }
    mics = devices.filter { $0.kind == "audioinput" && !$0.id.isEmpty }.map {
      Device(id: $0.id, label: $0.label.isEmpty ? "Microphone \($0.id.prefix(6))" : $0.label)
    }
    cams = devices.filter { $0.kind == "videoinput" && !$0.id.isEmpty }.map {
      Device(id: $0.id, label: $0.label.isEmpty ? "Camera \($0.id.prefix(6))" : $0.label)
    }
    let json = (result["settings"] as? String ?? "{}").data(using: .utf8) ?? Data()
    let saved = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
    mic = saved["mic"] as? String ?? ""
    cam = saved["cam"] as? String ?? ""
    camera = saved["camera"] as? Bool ?? false
    cameraOpacity = saved["cameraOpacity"] as? Double ?? 25
    mirror = saved["mirror"] as? Bool ?? false
  }

  func set(_ key: String, _ value: Any) {
    send?(["type": "set", "key": key, "value": value])
  }

  func binding<T>(_ path: ReferenceWritableKeyPath<DevicesModel, T>, key: String) -> Binding<T> {
    Binding(
      get: { self[keyPath: path] },
      set: {
        self[keyPath: path] = $0
        self.set(key, $0)
      })
  }
}

// Actions the Settings window needs from the app.
struct SettingsActions {
  let chooseModel: (URL) -> Void
  let downloadModel: () -> Void
  let addModelFile: () -> Void
  let chooseScriptsFolder: () -> Void
  let restartServer: () -> Void
  let showLog: () -> Void
}

struct SettingsView: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var devices: DevicesModel
  @ObservedObject var models: ModelList
  let actions: SettingsActions

  var body: some View {
    TabView {
      general.tabItem { Label("General", systemImage: "gearshape") }
      devicesTab.tabItem { Label("Devices", systemImage: "mic") }
      speech.tabItem { Label("Speech", systemImage: "waveform") }
      advanced.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
    }
    // A grouped Form scrolls, so it has no height of its own: without a fixed
    // size the window shrinks to just the tab bar.
    .frame(width: 560, height: 500)
    .padding(.vertical, 8)
  }

  private var general: some View {
    Form {
      Section("Recording") {
        Toggle("Keep the display awake while listening", isOn: $settings.keepAwake)
        Toggle("Hide Followspot's windows from screen recordings", isOn: $settings.hideFromCapture)
        Text("Some recorders ignore this; check once with yours.").font(.caption).foregroundStyle(.secondary)
        Toggle("Keep the prompter above other windows", isOn: $settings.floatOnTop)
      }
      Section("Keyboard") {
        Toggle("Global shortcuts, even when another app is in front", isOn: $settings.globalHotkeys)
        Text(HotKeys.bindings.map { "\($0.label) \(Self.describe($0.action))" }.joined(separator: " · "))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Updates") {
        Toggle("Check GitHub for a new version once a day", isOn: $settings.checkForUpdates)
      }
      Section("Scripts") {
        LabeledContent("Folder") {
          HStack {
            Text(settings.scriptsFolder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            Button("Choose…", action: actions.chooseScriptsFolder)
          }
        }
        Text("The control window lists, creates and saves scripts here. ⌘O still opens a script from anywhere.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var devicesTab: some View {
    Form {
      if !devices.connected {
        Text("The prompter isn't running yet, so devices can't be listed.").foregroundStyle(.secondary)
      }
      Section("Microphone") {
        Picker("Input", selection: devices.binding(\.mic, key: "mic")) {
          Text("System default").tag("")
          ForEach(devices.mics, id: \.id) { Text($0.label).tag($0.id) }
        }
      }
      Section("Camera") {
        Toggle("Show the camera behind the script", isOn: devices.binding(\.camera, key: "camera"))
        Picker("Camera", selection: devices.binding(\.cam, key: "cam")) {
          Text("System default").tag("")
          ForEach(devices.cams, id: \.id) { Text($0.label).tag($0.id) }
        }
        LabeledContent("Opacity") {
          Slider(value: devices.binding(\.cameraOpacity, key: "cameraOpacity"), in: 5...80, step: 1)
        }
        Toggle("Mirror (flip horizontally)", isOn: devices.binding(\.mirror, key: "mirror"))
      }
      if devices.labelsHidden {
        Text("Device names appear after you've listened or turned the camera on once.")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Refresh") { Task { await devices.refresh() } }
      }
    }
    .formStyle(.grouped)
    .task { await devices.refresh() }
  }

  private var speech: some View {
    Form {
      Section("Model") {
        Picker(
          "Whisper model",
          selection: Binding(get: { models.current ?? "" }, set: { path in
            if let url = models.installed.first(where: { $0.path == path }) { actions.chooseModel(url) }
          })
        ) {
          ForEach(models.installed, id: \.path) { Text(Models.label(for: $0)).tag($0.path) }
        }
        HStack {
          Button("Download a Model…", action: actions.downloadModel)
          Button("Add a Model File…", action: actions.addModelFile)
        }
      }
      Section("Accuracy and speed") {
        Toggle("Voice activity detection", isOn: $settings.vad)
          .disabled(Models.vad == nil)
        Text(
          Models.vad == nil
            ? "Download it with Download a Model… to stop Whisper inventing words in pauses."
            : "Skips silence and room noise, so pauses don't produce made-up words."
        )
        .font(.caption).foregroundStyle(.secondary)
        Toggle("Fast mode for medium and large models", isOn: $settings.fastMode)
        Text("Transcribes a 10 s window instead of Whisper's padded 30 s: about 3x faster on large-v3-turbo.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var advanced: some View {
    Form {
      Section("Server") {
        TextField("Port", value: $settings.port, format: .number.grouping(.never))
        Text("Changing the port resets the prompter's saved settings in the app (they're stored per port).")
          .font(.caption).foregroundStyle(.secondary)
        TextField("Extra whisper-server flags", text: $settings.extraArgs, prompt: Text("e.g. --no-gpu"))
        Text("Same as the flags after -- for ./followspot.").font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Show Server Log", action: actions.showLog)
          Spacer()
          Button("Apply and Restart Server", action: actions.restartServer)
        }
      }
    }
    .formStyle(.grouped)
  }

  static func describe(_ action: String) -> String {
    [
      "listen": "listen", "wordNext": "next word", "wordPrev": "previous word",
      "paraNext": "next paragraph", "paraPrev": "previous paragraph", "restart": "restart",
    ][action] ?? action
  }
}

// The installed models, refreshed when the Settings window opens or a
// download finishes.
final class ModelList: ObservableObject {
  @Published var installed: [URL] = []
  @Published var current: String?

  func refresh() {
    installed = Models.installed
    current = Models.current?.path
  }
}
