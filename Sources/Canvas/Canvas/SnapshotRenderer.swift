import AppKit
import CanvasCore
import WebKit

/// Renders artboards that have no live web view: loads the page once in a hidden window, takes a
/// PNG at native size, then releases the web view. A page that doesn't load or answer throws, so
/// nothing blank is cached. A page that crashes here is never reloaded.
@MainActor
final class SnapshotRenderer {
    private let schemeHandler: DocumentSchemeHandler
    private let window: NSWindow
    /// Time for the first frames (web fonts, entrance animations) after the page loads.
    private let settleTime: Duration = .milliseconds(250)

    init(schemeHandler: DocumentSchemeHandler) {
        self.schemeHandler = schemeHandler
        window = Self.hiddenWindow()
    }

    isolated deinit {
        window.close()
    }

    func render(_ board: Artboard) async throws -> Data {
        let size = CGSize(width: board.width, height: board.height)
        let page = LiveBoard(artboardID: board.id, schemeHandler: schemeHandler, receivesMessages: false)
        Self.keepRenderingWhileHidden(page.webView)
        window.contentView?.addSubview(page.webView)
        page.layout(size: size)
        defer { page.webView.removeFromSuperview() }
        page.load()
        guard await page.waitUntilLoaded() else { throw SnapshotError.loadFailed }
        try await Task.sleep(for: settleTime)
        return try await page.pngSnapshot(nativeSize: size)
    }

    /// A borderless window far off screen; web views only paint inside a window.
    private static func hiddenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 4000, height: 4000),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = FlippedView()
        window.orderFrontRegardless()
        return window
    }

    /// WebKit stops painting pages in occluded windows; this window is always "occluded" (WebKit SPI).
    private static func keepRenderingWhileHidden(_ webView: WKWebView) {
        guard webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) else { return }
        webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
