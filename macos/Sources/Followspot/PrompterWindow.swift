import AppKit
import SwiftUI
import WebKit

// The prompter window: a status view while the model loads, then the page
// in a WKWebView. Also owns the control window the page opens.
final class PrompterWindow: NSObject, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
  let window: NSWindow
  let webView: WKWebView
  private var controlWindow: NSWindow?
  private var controlWebView: WKWebView?

  init(bridge: Bridge) {
    let config = WKWebViewConfiguration()
    bridge.install(in: config.userContentController)
    config.preferences.isElementFullscreenEnabled = true  // the page's F key
    // Keep listening and scrolling at full speed while another app (the
    // recorder) is frontmost or the window is covered. The default throttles
    // timers and animation frames in background windows.
    config.preferences.inactiveSchedulingPolicy = .none
    // The Control Window menu item clicks the page's button from native code,
    // which WebKit doesn't count as a user gesture.
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    config.mediaTypesRequiringUserActionForPlayback = []  // camera self-view
    webView = WKWebView(frame: .zero, configuration: config)
    webView.isInspectable = true  // Safari > Develop, for debugging the page
    window = Self.makeWindow(title: "Followspot", size: NSSize(width: 1200, height: 800), autosave: "Prompter")
    super.init()
    webView.uiDelegate = self
    webView.navigationDelegate = self
    window.delegate = self
  }

  var isShowingPage: Bool { window.contentView === webView }

  func showStatus(_ title: String, detail: String? = nil, busy: Bool = true, buttons: [StatusButton] = []) {
    window.contentView = NSHostingView(rootView: StatusView(title: title, detail: detail, busy: busy, buttons: buttons))
  }

  func load(_ url: URL) {
    window.contentView = webView
    window.makeFirstResponder(webView)
    webView.load(URLRequest(url: url))
  }

  func reload() {
    if isShowingPage { webView.reload() }
  }

  // Goes through the page's own button so the page decides what opens.
  func openControlWindow() {
    if let controlWindow { return controlWindow.makeKeyAndOrderFront(nil) }
    webView.evaluateJavaScript("document.getElementById('tb-controls').click()")
  }

  // Sends a control message on the page's BroadcastChannel (see Bridge).
  func send(_ message: [String: Any]) {
    guard isShowingPage, let data = try? JSONSerialization.data(withJSONObject: message),
      let json = String(data: data, encoding: .utf8)
    else { return }
    webView.evaluateJavaScript("window.followspotApp?.send(\(json))")
  }

  // The page's saved settings and the devices it can see, for Settings.
  // Device names only show once the page has used the mic or camera.
  func pageDevices() async -> [String: Any]? {
    guard isShowingPage else { return nil }
    let js = """
      const devices = await navigator.mediaDevices.enumerateDevices();
      let settings = {};
      try { settings = JSON.parse(localStorage.getItem("followspot.settings") || "{}"); } catch {}
      return {
        devices: devices.map((d) => ({ kind: d.kind, id: d.deviceId, label: d.label })),
        settings: JSON.stringify(settings),
      };
      """
    return try? await webView.callAsyncJavaScript(js, contentWorld: .page) as? [String: Any]
  }

  // Float on top, and whether screen recordings can see the windows.
  func applyWindowOptions(_ settings: AppSettings) {
    for win in [window, controlWindow].compactMap({ $0 }) {
      win.sharingType = settings.hideFromCapture ? .none : .readOnly
    }
    window.level = settings.floatOnTop ? .floating : .normal
  }

  var hasControlWindow: Bool { controlWebView != nil }

  // If the control window's editor has unsaved edits, asks Save / Cancel /
  // Don't Save. Calls done(true) when it's fine to go ahead.
  func confirmUnsavedEdits(_ done: @escaping (Bool) -> Void) {
    guard let editor = controlWebView else { return done(true) }
    editor.callAsyncJavaScript(
      "return window.followspotEditor ? window.followspotEditor.state() : null", in: nil, in: .page
    ) { result in
      guard let state = (try? result.get()) as? [String: Any], state["dirty"] as? Bool == true else {
        return done(true)
      }
      self.controlWindow?.makeKeyAndOrderFront(nil)
      let alert = NSAlert()
      alert.messageText = "Save your changes to \(state["name"] as? String ?? "the script")?"
      alert.informativeText = "The script you're editing in the control window has unsaved changes."
      alert.addButton(withTitle: "Save")
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Don't Save")
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        // The page's save may still need a name (a new script) or hit a
        // conflict; then it stays open and nothing goes ahead.
        editor.callAsyncJavaScript("return await window.followspotEditor.save()", in: nil, in: .page) {
          done((try? $0.get()) as? Bool == true)
        }
      case .alertSecondButtonReturn: done(false)
      default: done(true)
      }
    }
  }

  func presentSheet<V: View>(_ view: V) -> NSWindow {
    let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
    window.beginSheet(sheet)
    return sheet
  }

  // MARK: WKUIDelegate

  // Mic and camera for our own page only. macOS still asks the user once
  // (the Info.plist usage strings); this just stops WebKit asking every time.
  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    decisionHandler(origin.host == "127.0.0.1" ? .grant : .deny)
  }

  // window.open("control.html"). The new view must use the configuration
  // WebKit hands us: that keeps it in the same session, which is what lets
  // the page's BroadcastChannel reach it.
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let controlWindow {
      controlWindow.makeKeyAndOrderFront(nil)
      return nil
    }
    let popup = WKWebView(frame: .zero, configuration: configuration)
    popup.uiDelegate = self
    popup.navigationDelegate = self
    popup.isInspectable = true
    let win = Self.makeWindow(
      title: "Followspot Controls", size: NSSize(width: 1000, height: 800), autosave: "Controls")
    win.contentView = popup
    win.delegate = self
    win.sharingType = window.sharingType
    win.makeKeyAndOrderFront(nil)
    controlWindow = win
    controlWebView = popup
    return popup
  }

  // alert() and confirm(), e.g. "discard unsaved changes?" in the editor.
  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.runModal()
    completionHandler()
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    completionHandler(alert.runModal() == .alertFirstButtonReturn)
  }

  func webViewDidClose(_ webView: WKWebView) {
    if webView === controlWebView { controlWindow?.close() }
  }

  private var closeConfirmed = false

  // Closing the control window with unsaved edits asks first. Closing the
  // prompter quits (the control window can't do anything without it), and
  // quitting asks too (AppDelegate.applicationShouldTerminate).
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if sender === window {
      NSApp.terminate(nil)
      return false
    }
    guard sender === controlWindow, !closeConfirmed else { return true }
    confirmUnsavedEdits { [weak self] ok in
      guard ok, let self else { return }
      self.closeConfirmed = true
      sender.close()
      self.closeConfirmed = false
    }
    return false
  }

  func windowWillClose(_ notification: Notification) {
    if notification.object as? NSWindow === controlWindow {
      controlWindow = nil
      controlWebView = nil
    }
  }

  // MARK: WKNavigationDelegate

  // Links off the local server open in the default browser.
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme), url.host != "127.0.0.1" {
      NSWorkspace.shared.open(url)
      return decisionHandler(.cancel)
    }
    decisionHandler(.allow)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    webView.reload()
  }

  private static func makeWindow(title: String, size: NSSize, autosave: String) -> NSWindow {
    let win = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    win.title = title
    win.isReleasedWhenClosed = false
    win.backgroundColor = .black
    win.collectionBehavior.insert(.fullScreenPrimary)
    // Reopen where it was, so the prompter comes back on the prompter display.
    if !win.setFrameUsingName(autosave) { win.center() }
    win.setFrameAutosaveName(autosave)
    return win
  }
}
