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

  override init() {
    let config = WKWebViewConfiguration()
    config.preferences.isElementFullscreenEnabled = true  // the page's F key
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
    win.makeKeyAndOrderFront(nil)
    controlWindow = win
    controlWebView = popup
    return popup
  }

  func webViewDidClose(_ webView: WKWebView) {
    if webView === controlWebView { controlWindow?.close() }
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
