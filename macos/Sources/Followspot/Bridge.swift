import WebKit

// How the app and the page talk.
//
// App -> page: a small user script joins the page's BroadcastChannel (the
// same protocol the control window uses, see public/remote.js), so the app
// can send actions and settings without the page knowing about it.
//
// Page -> app: `webkit.messageHandlers.followspot.postMessage({type, ...})`,
// which resolves with a reply. public/native.js wraps it; in a browser it's
// absent and the app-only features stay hidden.
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
  typealias Handler = (_ type: String, _ body: [String: Any]) throws -> Any?
  private let handler: Handler

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  // Relays listening on/off (for keeping the display awake) and exposes
  // followspotApp.send(message) to native code.
  static let userScript = WKUserScript(
    source: """
      (() => {
        const channel = new BroadcastChannel("followspot");
        let listening = null;
        channel.addEventListener("message", ({ data }) => {
          if (data?.type !== "state" || data.listening === listening) return;
          listening = data.listening;
          window.webkit.messageHandlers.followspot
            .postMessage({ type: "listening", on: listening })
            .catch(() => {});
        });
        window.followspotApp = { send: (message) => channel.postMessage(message) };
      })();
      """,
    injectionTime: .atDocumentEnd, forMainFrameOnly: true)

  func install(in controller: WKUserContentController) {
    controller.addUserScript(Self.userScript)
    controller.addScriptMessageHandler(self, contentWorld: .page, name: "followspot")
  }

  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping (Any?, String?) -> Void
  ) {
    // Only our own page on the local server gets the bridge.
    guard message.frameInfo.securityOrigin.host == "127.0.0.1",
      let body = message.body as? [String: Any], let type = body["type"] as? String
    else { return replyHandler(nil, "Not allowed") }
    do {
      replyHandler(try handler(type, body) ?? NSNull(), nil)
    } catch {
      replyHandler(nil, error.localizedDescription)
    }
  }
}
