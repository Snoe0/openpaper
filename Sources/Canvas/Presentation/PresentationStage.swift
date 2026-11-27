import AppKit
import CanvasCore

/// The black backdrop that shows one live page scaled uniformly to fit, centred and letterboxed.
/// The page lays out at the board's own CSS size in a `PageHost`, as on the canvas, so media queries
/// and text sizes are the artboard's whatever the screen.
final class PresentationStage: NSView {
    private var page: LiveBoard?
    private let pageHost = PageHost()
    private var boardSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(pageHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ page: LiveBoard, boardSize: CGSize) {
        if self.page !== page {
            self.page?.webView.removeFromSuperview()
            pageHost.addSubview(page.webView)
            self.page = page
        }
        self.boardSize = boardSize
        fitPage()
    }

    func removePage() {
        page?.webView.removeFromSuperview()
        page = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitPage()
    }

    private func fitPage() {
        guard let page, boardSize.width > 0, boardSize.height > 0, !bounds.isEmpty else { return }
        pageHost.fit(page.webView, boardSize: boardSize, centredIn: bounds)
    }
}
