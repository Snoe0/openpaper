import AppKit
import CanvasCore
import ImageIO

/// One artboard on the canvas: its last snapshot, with the live web view on top while it has one, fitted
/// by a `PageHost`. Its frame is the board's on-screen rect; it only takes the pointer for a page being
/// inspected.
@MainActor
final class ArtboardView: NSView {
    let artboardID: String
    private(set) var liveBoard: LiveBoard?
    private let snapshotLayer = CALayer()
    private let pageHost = PageHost()
    /// Counts snapshots asked for, so a slow decode never replaces a newer snapshot.
    private var snapshotGeneration = 0

    init(artboardID: String) {
        self.artboardID = artboardID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.17, alpha: 1).cgColor
        // At 100% and up a live page can overhang its board by under a point (`PageFit` rounds its height up).
        layer?.masksToBounds = true
        snapshotLayer.contentsGravity = .resize
        snapshotLayer.minificationFilter = .trilinear
        snapshotLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(snapshotLayer)
        addSubview(pageHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        snapshotLayer.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let webView = liveBoard?.webView, webView.acceptsMouse else { return nil }
        return webView.hitTest(pageHost.convert(point, from: superview))
    }

    /// Puts the board at `frame` (already snapped to pixels) and fits a live page to it.
    func place(at frame: CGRect, boardSize: CGSize) {
        self.frame = frame
        fitPage(boardSize: boardSize)
    }

    /// Shows a snapshot, decoded off the main thread no larger than `maxPixelSize` on its longer side.
    /// Returns once it is shown, or a newer snapshot took its place.
    func showSnapshot(_ png: Data, maxPixelSize: Int) async {
        snapshotGeneration += 1
        let generation = snapshotGeneration
        let image = await Task.detached(priority: .userInitiated) { Self.thumbnail(of: png, maxPixelSize: maxPixelSize) }.value
        guard generation == snapshotGeneration, let image else { return }
        snapshotLayer.contents = image
    }

    private nonisolated static func thumbnail(of png: Data, maxPixelSize: Int) -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// Shows the board's web view, faded in once its page has loaded so a blank page never flashes.
    func attach(_ board: LiveBoard, size: CGSize) {
        liveBoard = board
        board.webView.alphaValue = board.isLoaded ? 1 : 0
        pageHost.addSubview(board.webView)
        fitPage(boardSize: size)
    }

    /// Stops treating `board` as this view's page (its web view is already removed).
    func forget(_ board: LiveBoard) {
        if liveBoard === board { liveBoard = nil }
    }

    /// Hides `board`'s page (while it reloads), leaving the snapshot in view.
    func hidePage(of board: LiveBoard) {
        if liveBoard === board { board.webView.alphaValue = 0 }
    }

    func revealLoadedPage() {
        liveBoard?.webView.alphaValue = 1
    }

    /// Fits the live page, if any, to this view as it is on screen, so it covers the snapshot exactly.
    private func fitPage(boardSize: CGSize) {
        guard let webView = liveBoard?.webView else { return }
        pageHost.fit(webView, to: PageFit(boardSize: boardSize, onScreen: bounds.size))
    }
}
