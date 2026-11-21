import AppKit
import WebKit

/// Shows one web view (its subview) fitted to its board. Below 100% the page isn't zoomed: zoom would
/// apply WebKit's 9 px minimum logical font size, growing any text drawn under 9 points and reflowing
/// the page. The page lays out at the board's size instead, and the host's bounds draw it shrunk.
/// (Scaling the web view's own bounds lays it out right but WebKit then paints only a corner of it.)
public final class PageHost: NSView {
    public override var isFlipped: Bool { true }

    /// Sizes the host to `fit`'s frame and lays `webView` out at `fit`'s bounds size and page zoom.
    public func fit(_ webView: WKWebView, to fit: PageFit) {
        frame.size = fit.frameSize
        // A frame change scales the bounds along with it, so the bounds are set after it, every time.
        setBoundsSize(fit.boundsSize)
        webView.frame = CGRect(origin: .zero, size: fit.boundsSize)
        if webView.pageZoom != fit.pageZoom { webView.pageZoom = fit.pageZoom }
    }

    /// Presentation: the largest whole-point fit that shows the whole board inside `area` (in the
    /// superview's coordinates), however small or large the board, centred on whole points.
    public func fit(_ webView: WKWebView, boardSize: CGSize, centredIn area: CGRect) {
        fit(webView, to: PageFit(boardSize: boardSize, onScreen: PageFit.presentedSize(of: boardSize, in: area.size)))
        setFrameOrigin(CGPoint(x: (area.midX - frame.width / 2).rounded(), y: (area.midY - frame.height / 2).rounded()))
    }
}
