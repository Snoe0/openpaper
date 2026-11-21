import AppKit

/// The black backdrop that shows one live page scaled uniformly to fit, centred and letterboxed.
/// The page lays out at the board's own CSS size (`PageFit` sets the frame and page zoom, as on the
/// canvas), so media queries see the artboard's width whatever the screen.
final class PresentationStage: NSView {
    private var page: LiveBoard?
    private var boardSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ page: LiveBoard, boardSize: CGSize) {
        if self.page !== page {
            self.page?.webView.removeFromSuperview()
            addSubview(page.webView)
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
        page.layout(size: boardSize, scale: fittingScale())
        page.webView.setFrameOrigin(centredOrigin(of: page.webView.frame.size))
    }

    /// The largest scale that shows the whole board on the stage, however small or large the board.
    private func fittingScale() -> CGFloat {
        min(bounds.width / boardSize.width, bounds.height / boardSize.height)
    }

    private func centredOrigin(of size: CGSize) -> CGPoint {
        CGPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded())
    }
}
