import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let server = Server()
  private let settings = AppSettings.shared
  private var prompter: PrompterWindow!
  private let download = ModelDownload()
  private var sheet: NSWindow?
  private var launch = 0  // which server start a readiness check belongs to
  private let recentMenu = NSMenu(title: "Open Recent")
  private let modelMenu = NSMenu(title: "Model")
  private let hotKeys = HotKeys()
  private let devices = DevicesModel()
  private let modelList = ModelList()
  private var settingsWindow: NSWindow?
  private var listening = false
  private var awake: NSObjectProtocol?  // held while listening keeps the display on

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildMenus()
    let bridge = Bridge { [weak self] type, body in try self?.handleBridge(type, body) }
    prompter = PrompterWindow(bridge: bridge)
    prompter.applyWindowOptions(settings)
    devices.send = { [weak self] in self?.prompter.send($0) }
    devices.fetch = { [weak self] in await self?.prompter.pageDevices() }
    hotKeys.onAction = { [weak self] in self?.prompter.send(["type": "action", "name": $0]) }
    if settings.globalHotkeys { hotKeys.register() }
    NotificationCenter.default.addObserver(
      self, selector: #selector(settingChanged), name: AppSettings.changed, object: nil)
    prompter.showStatus("Starting…")
    prompter.window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    server.onExit = { [weak self] log in
      self?.showError("whisper-server stopped.", detail: log)
    }
    Server.killOrphan()
    do {
      try Staging.prepare()
    } catch {
      return showError(error.localizedDescription)
    }
    updateTitle()
    startServer()
  }

  func applicationWillTerminate(_ notification: Notification) {
    hotKeys.unregister()
    server.stop()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  // Finder's Open With, or a file dropped on the Dock icon. Can arrive
  // before launch finishes; Staging.prepare() then links it from defaults.
  func application(_ application: NSApplication, open urls: [URL]) {
    if let url = urls.first { openScript(url) }
  }

  // MARK: Server

  private func startServer() {
    guard let model = Models.current else {
      prompter.showStatus(
        "No Whisper model yet", busy: false,
        buttons: [StatusButton(label: "Download a Model…") { [weak self] in self?.showDownload() }])
      return showDownload()
    }
    launch += 1
    let thisLaunch = launch
    prompter.showStatus(
      "Loading \(Models.label(for: model))…", detail: "Larger models take a few seconds to load.")
    do {
      try server.start(model: model)
    } catch {
      return showError(error.localizedDescription)
    }
    Task { @MainActor in
      let ready = await server.waitUntilReady()
      guard thisLaunch == launch else { return }
      if ready {
        prompter.load(server.url)
      } else if server.isRunning {
        server.stop()
        showError("whisper-server didn't answer within 3 minutes.", detail: Server.logTail())
      }  // else it exited, and onExit already said so
    }
  }

  private func restartServer() {
    setListening(false)  // the page reloads, and so stops listening
    server.stop()
    startServer()
  }

  // MARK: Settings

  @objc private func settingChanged(_ note: Notification) {
    switch note.object as? AppSettings.Key {
    case .keepAwake: setListening(listening)
    case .hideFromCapture, .floatOnTop: prompter.applyWindowOptions(settings)
    case .globalHotkeys: settings.globalHotkeys ? hotKeys.register() : hotKeys.unregister()
    case .fastMode, .vad: restartServer()
    default: break
    }
  }

  // Holds off display sleep only while listening: a long take with no
  // keyboard or mouse input would otherwise dim and lock the screen.
  private func setListening(_ on: Bool) {
    listening = on
    if on && settings.keepAwake {
      if awake == nil {
        awake = ProcessInfo.processInfo.beginActivity(
          options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Followspot is listening")
      }
    } else if let activity = awake {
      ProcessInfo.processInfo.endActivity(activity)
      awake = nil
    }
  }

  @objc private func showSettings(_ sender: Any?) {
    modelList.refresh()
    if let settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      Task { await devices.refresh() }
      return
    }
    let view = SettingsView(
      settings: settings, devices: devices, models: modelList,
      actions: SettingsActions(
        chooseModel: { [weak self] url in self?.useModel(url) },
        downloadModel: { [weak self] in self?.showDownload() },
        addModelFile: { [weak self] in self?.addModelFile(nil) },
        chooseScriptsFolder: { [weak self] in self?.chooseScriptsFolder() },
        restartServer: { [weak self] in
          guard let self else { return }
          _ = self.settings.applyServerOptions()
          self.restartServer()
        },
        showLog: { NSWorkspace.shared.open(Paths.log) }))
    let win = NSWindow(contentViewController: NSHostingController(rootView: view))
    win.title = "Followspot Settings"
    win.styleMask = [.titled, .closable]
    win.isReleasedWhenClosed = false
    win.center()
    win.makeKeyAndOrderFront(nil)
    settingsWindow = win
  }

  private func chooseScriptsFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = settings.scriptsURL
    panel.prompt = "Use Folder"
    if panel.runModal() == .OK, let url = panel.url { settings.scriptsFolder = url.path }
  }

  // MARK: Page bridge (see Bridge.swift and public/native.js)

  private func handleBridge(_ type: String, _ body: [String: Any]) throws -> Any? {
    switch type {
    case "listening":
      setListening(body["on"] as? Bool ?? false)
      return nil
    case "scripts.list":
      return scriptList()
    case "scripts.open":
      let url = URL(fileURLWithPath: body["path"] as? String ?? "")
      guard Scripts.isOpenable(url) else { throw Scripts.error("That script isn't in the list.") }
      openScript(url)
      return nil
    case "scripts.save":
      guard let script = Staging.currentScript else {
        throw Scripts.error("This script isn't saved in a file yet. Save it as a new script.")
      }
      try Scripts.save(body["text"] as? String ?? "", to: script)
      return script.path
    case "scripts.create":
      let url = try Scripts.create(name: body["name"] as? String ?? "", text: body["text"] as? String ?? "")
      openScript(url)
      return url.path
    case "scripts.reveal":
      if let script = Staging.currentScript {
        NSWorkspace.shared.activateFileViewerSelecting([script])
      } else {
        NSWorkspace.shared.open(Scripts.folder)
      }
      return nil
    default:
      throw Scripts.error("Unknown request \(type)")
    }
  }

  private func scriptList() -> [String: Any] {
    let current = Staging.currentScript?.standardizedFileURL
    var scripts = Scripts.list().map { ["name": $0.lastPathComponent, "path": $0.path] }
    // A script opened from elsewhere (⌘O) still shows, so it can be edited.
    if let current, !scripts.contains(where: { $0["path"] == current.path }) {
      scripts.insert(["name": current.lastPathComponent, "path": current.path], at: 0)
    }
    return [
      "folder": Scripts.folder.path,
      "folderName": Scripts.folder.lastPathComponent,
      "current": current?.path ?? NSNull(),
      "scripts": scripts,
    ]
  }

  private func showError(_ title: String, detail: String? = nil) {
    prompter.showStatus(
      title, detail: detail, busy: false,
      buttons: [
        StatusButton(label: "Show Log") { NSWorkspace.shared.open(Paths.log) },
        StatusButton(label: "Try Again") { [weak self] in self?.restartServer() },
      ])
  }

  // MARK: Scripts

  private func openScript(_ url: URL) {
    do {
      try Staging.setScript(url)
      NSDocumentController.shared.noteNewRecentDocumentURL(url)
    } catch {
      let alert = NSAlert(error: error)
      alert.runModal()
      return
    }
    updateTitle()
    prompter?.reload()  // also forgets a file dropped on the page
  }

  private func updateTitle() {
    prompter?.window.subtitle = Staging.currentScript?.lastPathComponent ?? "Demo script"
  }

  @objc private func openDocument(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.init(filenameExtension: "md")!, .plainText]
    panel.message = "Choose a script (Markdown or plain text)"
    panel.beginSheetModal(for: prompter.window) { [weak self] response in
      if response == .OK, let url = panel.url { self?.openScript(url) }
    }
  }

  @objc private func openRecent(_ sender: NSMenuItem) {
    if let url = sender.representedObject as? URL { openScript(url) }
  }

  @objc private func clearRecent(_ sender: Any?) {
    Staging.clearRecent()
  }

  // MARK: Models

  private func showDownload() {
    guard sheet == nil else { return }
    let view = DownloadView(
      download: download,
      onDone: { [weak self] name in
        self?.closeSheet()
        if let url = Models.installed.first(where: { Models.label(for: $0) == name }) {
          UserDefaults.standard.set(url.path, forKey: "model")
        }
        self?.modelList.refresh()
        self?.restartServer()
      },
      onCancel: { [weak self] in self?.closeSheet() })
    sheet = prompter.presentSheet(view)
  }

  private func closeSheet() {
    if let sheet { prompter.window.endSheet(sheet) }
    sheet = nil
  }

  @objc private func downloadModel(_ sender: Any?) {
    showDownload()
  }

  @objc private func chooseModel(_ sender: NSMenuItem) {
    if let url = sender.representedObject as? URL { useModel(url) }
  }

  private func useModel(_ url: URL) {
    UserDefaults.standard.set(url.path, forKey: "model")
    modelList.refresh()
    restartServer()
  }

  @objc private func toggleVAD(_ sender: Any?) {
    settings.vad.toggle()  // restarts the server via settingChanged
  }

  // A model file from anywhere (another app's copy, a fine-tune): linked
  // into the models folder, not copied, so it doesn't take the space twice.
  @objc private func addModelFile(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.init(filenameExtension: "bin")!]
    panel.message = "Choose a whisper.cpp model (ggml-*.bin)"
    guard panel.runModal() == .OK, let src = panel.url else { return }
    var name = src.lastPathComponent
    if !name.hasPrefix("ggml-") { name = "ggml-" + name }
    let dest = Paths.models.appendingPathComponent(name)
    do {
      if !FileManager.default.fileExists(atPath: dest.path) {
        try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: src)
      }
      if !name.hasPrefix("ggml-silero-") { useModel(dest) } else { modelList.refresh() }
    } catch {
      NSAlert(error: error).runModal()
    }
  }

  // MARK: View

  @objc private func showControls(_ sender: Any?) {
    prompter.openControlWindow()
  }

  @objc private func reloadPage(_ sender: Any?) {
    prompter.reload()
  }

  @objc private func showLog(_ sender: Any?) {
    NSWorkspace.shared.open(Paths.log)
  }

  @objc private func showScriptsFolder(_ sender: Any?) {
    try? FileManager.default.createDirectory(at: Scripts.folder, withIntermediateDirectories: true)
    NSWorkspace.shared.open(Scripts.folder)
  }

  @objc private func showModelsFolder(_ sender: Any?) {
    NSWorkspace.shared.open(Paths.models)
  }

  @objc private func showReadme(_ sender: Any?) {
    NSWorkspace.shared.open(URL(string: "https://github.com/JoeKarlsson/followspot#readme")!)
  }

  // MARK: Menus

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    if menu === recentMenu {
      for url in Staging.recentScripts {
        let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.toolTip = url.path
      }
      if menu.items.isEmpty { menu.addItem(withTitle: "No Recent Scripts", action: nil, keyEquivalent: "") }
      menu.addItem(.separator())
      menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecent), keyEquivalent: "").target = self
    } else if menu === modelMenu {
      let current = Models.current?.standardizedFileURL
      for url in Models.installed {
        let item = menu.addItem(withTitle: Models.label(for: url), action: #selector(chooseModel), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.state = url.standardizedFileURL == current ? .on : .off
        item.toolTip = url.path
      }
      if menu.items.isEmpty { menu.addItem(withTitle: "No Models", action: nil, keyEquivalent: "") }
      menu.addItem(.separator())
      let vad = menu.addItem(
        withTitle: Models.vad == nil ? "Voice Activity Detection (not downloaded)" : "Voice Activity Detection",
        action: Models.vad == nil ? nil : #selector(toggleVAD), keyEquivalent: "")
      vad.target = self
      vad.state = Models.vad != nil && settings.vad ? .on : .off
      menu.addItem(withTitle: "Download Model…", action: #selector(downloadModel), keyEquivalent: "").target = self
      menu.addItem(withTitle: "Add Model File…", action: #selector(addModelFile), keyEquivalent: "").target = self
      menu.addItem(withTitle: "Show Models Folder", action: #selector(showModelsFolder), keyEquivalent: "")
        .target = self
    }
  }

  private func buildMenus() {
    let main = NSMenu()

    let appMenu = submenu(of: main, "Followspot")
    appMenu.addItem(
      withTitle: "About Followspot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide Followspot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(
      withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"
    ).keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(
      withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Followspot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let file = submenu(of: main, "File")
    file.addItem(withTitle: "Open Script…", action: #selector(openDocument), keyEquivalent: "o").target = self
    let recent = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
    recent.submenu = recentMenu
    recentMenu.delegate = self
    file.addItem(withTitle: "Show Scripts Folder", action: #selector(showScriptsFolder), keyEquivalent: "")
      .target = self
    file.addItem(.separator())
    file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

    // Needed for copy and paste in the page's settings fields.
    let edit = submenu(of: main, "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    // The prompter's own keys (Space, arrows, M, F, ...) work as in the
    // browser. keyAction() in remote.js ignores ⌘ combos, so these don't clash.
    let view = submenu(of: main, "View")
    view.addItem(withTitle: "Control Window", action: #selector(showControls), keyEquivalent: "k").target = self
    view.addItem(withTitle: "Reload Page", action: #selector(reloadPage), keyEquivalent: "r").target = self
    view.addItem(.separator())
    view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
      .keyEquivalentModifierMask = [.command, .control]

    let model = main.addItem(withTitle: "Model", action: nil, keyEquivalent: "")
    model.submenu = modelMenu
    modelMenu.delegate = self

    let window = submenu(of: main, "Window")
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    window.addItem(.separator())
    window.addItem(
      withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    NSApp.windowsMenu = window

    let help = submenu(of: main, "Help")
    help.addItem(withTitle: "Followspot README", action: #selector(showReadme), keyEquivalent: "").target = self
    help.addItem(withTitle: "Show Server Log", action: #selector(showLog), keyEquivalent: "").target = self
    NSApp.helpMenu = help

    NSApp.mainMenu = main
  }

  private func submenu(of menu: NSMenu, _ title: String) -> NSMenu {
    let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
    let sub = NSMenu(title: title)
    item.submenu = sub
    return sub
  }
}
