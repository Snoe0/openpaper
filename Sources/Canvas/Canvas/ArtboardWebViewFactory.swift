import AppKit
import CanvasCore
import WebKit

/// Builds the web views that render artboards: pages come from the document over `canvas://`,
/// and runtime messages go to a weakly held handler (the content controller retains its handlers).
/// Every page gets its own non-persistent storage, so `localStorage` can't make a live page and its
/// snapshots diverge, and the light (aqua) appearance, so `prefers-color-scheme` and form controls
/// look like a default browser whatever the app's dark chrome; designs switch looks with token modes.
@MainActor
enum ArtboardWebViewFactory {
    static let messageHandlerName = "canvas"

    static func makeWebView(schemeHandler: DocumentSchemeHandler) -> ArtboardWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: CanvasURL.scheme)
        configuration.websiteDataStore = .nonPersistent()
        let webView = ArtboardWebView(frame: .zero, configuration: configuration)
        webView.appearance = NSAppearance(named: .aqua)
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    /// Sends the page's `webkit.messageHandlers.canvas` messages to `handler`, held weakly.
    static func deliverMessages(of webView: WKWebView, to handler: any WKScriptMessageHandler) {
        webView.configuration.userContentController.add(WeakMessageHandler(handler), name: messageHandlerName)
    }
}

/// A web view that ignores the pointer unless `acceptsMouse` is on (inspect mode), so the canvas owns
/// clicks and drags. Clicks never reach it through hit-testing; this also stops hover tracking.
final class ArtboardWebView: WKWebView {
    var acceptsMouse = false
    /// Canvas boards set this: a right-click or control-click on a page taking the pointer (inspect mode)
    /// opens the canvas's pointer menu instead of WebKit's context menu.
    var onContextClick: ((NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        guard let onContextClick else { return super.rightMouseDown(with: event) }
        onContextClick(event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let onContextClick, event.modifierFlags.contains(.control) else { return super.mouseDown(with: event) }
        onContextClick(event)
    }

    override func mouseMoved(with event: NSEvent) {
        if acceptsMouse { super.mouseMoved(with: event) }
    }

    override func mouseEntered(with event: NSEvent) {
        if acceptsMouse { super.mouseEntered(with: event) }
    }

    override func mouseExited(with event: NSEvent) {
        if acceptsMouse { super.mouseExited(with: event) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsMouse ? super.hitTest(point) : nil
    }
}

/// Forwards runtime messages without retaining the receiver.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
