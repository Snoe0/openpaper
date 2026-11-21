import AppKit
import CanvasCore

/// Shows the current page of a document as an infinite canvas of live artboards, and is the
/// canvas API for the app shell and the MCP bridge. With no document it shows a hint.
@MainActor
final class CanvasViewController: NSViewController {
    let document: CanvasDocument?
    let canvasView = CanvasView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))

    /// The selected boards and the element picked in inspect mode.
    private(set) var selection = CanvasSelection() {
        didSet { selectionDidChange(from: oldValue) }
    }
    private(set) var tool: CanvasTool = .select {
        didSet { toolDidChange(from: oldValue) }
    }
    /// The on-screen scale; 1 is 100%.
    var zoom: CGFloat { canvasView.viewport.scale }
    /// The first viewport: nil fits every board, a number zooms to it around the boards' centre.
    var initialZoom: CGFloat?

    var onZoomChange: ((CGFloat) -> Void)?
    var onSelectionChange: ((CanvasSelection) -> Void)?
    /// Also called when the canvas switches tools itself (back to select after leaving inspect mode).
    var onToolChange: ((CanvasTool) -> Void)?

    // State shared with the Visibility, Sync and Interaction extensions.
    let policy = VisibilityPolicy()
    var pool = LivePool(capacity: VisibilityPolicy().capacity)
    /// Every board that owns a web view: live ones and paused ones.
    var liveBoards: [String: LiveBoard] = [:]
    /// The board in inspect mode, if any.
    var inspectedID: String?
    /// The right-click whose pointer menu is being prepared or is open, if any.
    var pointing: PointerRequest?
    /// Its board, kept live.
    var pointedID: String? { pointing?.boardID }
    /// Boards the user paused with the hover bar.
    var userPaused: Set<String> = []
    var consoleLog = ConsoleLog()
    var snapshotKeys: [String: SnapshotKey] = [:]
    var isRendering = false
    /// Boards whose off-screen render failed; retried after the next viewport change, or after a
    /// content change for a board in `crashedBoards`.
    var failedRenders: Set<String> = []
    var crashRetries = CrashRetryLimit()
    /// Boards whose page kept crashing; they stay snapshots until their content changes.
    var crashedBoards: Set<String> = []
    var assetRefreshPending = false
    /// The manifest the canvas last synced to.
    var shownManifest: Manifest?
    let schemeHandler: DocumentSchemeHandler?
    let snapshots: SnapshotCache?
    let renderer: SnapshotRenderer?
    private var subscription: ChangeSubscription?
    /// Nothing goes live before the first viewport is placed, so no page loads only to be paused.
    private(set) var hasPlacedViewport = false

    init(document: CanvasDocument?) {
        self.document = document
        schemeHandler = document.map(DocumentSchemeHandler.init)
        snapshots = document.map { SnapshotCache(directory: SnapshotCache.directory(forDocument: $0.url)) }
        renderer = schemeHandler.map(SnapshotRenderer.init)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        canvasView.delegate = self
        view = canvasView
        connectHoverBar()
        if let document {
            subscription = document.onChange { [weak self] change in self?.documentDidChange(change) }
            syncToManifest()
        } else {
            showEmptyHint()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !hasPlacedViewport, canvasView.bounds.width > 0 else { return }
        hasPlacedViewport = true
        placeInitialViewport()
    }

    // MARK: - API

    func setTool(_ tool: CanvasTool) {
        self.tool = tool
        if tool == .inspect, let id = selection.artboardIDs.first {
            startInspecting(id)
        } else if tool != .inspect {
            stopInspecting()
        }
    }

    /// Animates the viewport to fit the board and selects it.
    func focus(artboardID: String) {
        guard let board = canvasView.board(artboardID) else { return }
        select([artboardID])
        canvasView.show(canvasView.fitting(board.rect), animated: true)
    }

    func zoomToFit() { canvasView.zoomToFit() }
    func zoomToSelection() { canvasView.zoomToSelection() }
    func setZoom(_ scale: CGFloat) { canvasView.zoom(to: scale) }

    /// One board's console messages, or every board's, oldest first (at most 500 per board).
    func consoleLogs(artboardID: String?) -> [ConsoleEntry] {
        consoleLog.entries(artboardID: artboardID)
    }

    /// A crisp PNG of the board, one pixel per CSS pixel (a huge board comes out scaled down, see
    /// `SnapshotSize`), showing the document as it is now: from the live page once its pending reloads
    /// and patches land, else the cached snapshot for the current content, else an off-screen render.
    func snapshotPNG(artboardID id: String) async throws -> Data {
        guard let document, let renderer else { throw DocumentError.notFound(id) }
        let board = try document.artboard(id: id)
        if let png = await liveSnapshot(of: id, size: CGSize(width: board.width, height: board.height)) { return png }
        if !pool.live.contains(id), let key = snapshotKeys[id], let png = snapshots?.snapshot(for: key) { return png }
        return try await renderer.render(board)
    }

    /// Nil when the board isn't live, the window is covered (WebKit may not answer), or the snapshot fails.
    private func liveSnapshot(of id: String, size: CGSize) async -> Data? {
        guard isWindowVisible, pool.live.contains(id), let live = liveBoards[id] else { return nil }
        await live.waitForChanges()
        guard liveBoards[id] === live, live.webView.superview != nil else { return nil }
        return await live.currentLook(nativeSize: size)
    }

    var isWindowVisible: Bool {
        view.window?.occlusionState.contains(.visible) == true
    }

    // MARK: - Selection

    func select(_ ids: [String]) {
        guard ids != selection.artboardIDs else { return }
        selection = CanvasSelection(artboardIDs: ids, element: nil)
    }

    func selectElement(_ element: SelectedElement) {
        selection = CanvasSelection(artboardIDs: [element.artboardID], element: element)
    }

    private func toolDidChange(from old: CanvasTool) {
        guard tool != old else { return }
        canvasView.tool = tool
        onToolChange?(tool)
    }

    private func selectionDidChange(from old: CanvasSelection) {
        guard selection != old else { return }
        canvasView.selectedIDs = selection.artboardIDs
        onSelectionChange?(selection)
    }

    // MARK: - Setup

    private func placeInitialViewport() {
        guard let initialZoom else { return canvasView.zoomToFit(animated: false) }
        let all = canvasView.boundsOfBoards() ?? .zero
        canvasView.show(Viewport.centred(on: CGPoint(x: all.midX, y: all.midY), scale: initialZoom, screenSize: canvasView.bounds.size), animated: false)
    }

    private func showEmptyHint() {
        let hint = NSTextField(labelWithString: "No document open.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 13)
        hint.translatesAutoresizingMaskIntoConstraints = false
        canvasView.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: canvasView.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: canvasView.centerYAnchor),
        ])
    }
}
