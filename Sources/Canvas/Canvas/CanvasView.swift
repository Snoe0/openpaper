import AppKit
import CanvasCore

/// A board as the canvas shows it: where it sits (canvas points) and its title.
struct CanvasBoard: Equatable {
    var id: String
    var name: String
    var rect: CGRect
}

@MainActor
protocol CanvasViewDelegate: AnyObject {
    func canvasView(_ canvasView: CanvasView, didClickBoard id: String?, extendingSelection: Bool)
    func canvasView(_ canvasView: CanvasView, didDoubleClickBoard id: String)
    func canvasView(_ canvasView: CanvasView, didMoveBoard id: String, to origin: CGPoint)
    /// A right-click or control-click on a board, or on its title; `boardPoint` is in the board's CSS pixels.
    func canvasView(_ canvasView: CanvasView, didRequestMenuForBoard id: String, at boardPoint: CGPoint, onTitle: Bool)
    func canvasViewDidChangeZoom(_ canvasView: CanvasView)
    /// The viewport stopped moving and boards were laid out crisply at the new scale.
    func canvasViewDidSettle(_ canvasView: CanvasView)
    func canvasViewDidChangeHoverTarget(_ canvasView: CanvasView)
    func canvasViewDidPressEscape(_ canvasView: CanvasView)
}

/// The infinite canvas: holds the viewport, lays out artboard views, and shows titles, selection
/// and the hover bar. While the viewport moves it only changes the board layer's bounds; ~150 ms
/// after it stops, boards are laid out again at the new scale. Pointer and key input live in
/// `CanvasView+Input`.
@MainActor
final class CanvasView: NSView {
    static let background = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
    static let fitPadding: CGFloat = 64
    private static let settleDelay: Duration = .milliseconds(150)

    weak var delegate: CanvasViewDelegate?
    var tool: CanvasTool = .select { didSet { updateCursor() } }

    var boards: [CanvasBoard] = [] {
        didSet { boardsDidChange() }
    }
    var selectedIDs: [String] = [] {
        didSet { chromeDidChange() }
    }
    private(set) var viewport = Viewport()
    /// The scale board views are currently laid out at (differs from `viewport.scale` mid-gesture).
    var layoutScale: CGFloat { laidOutViewport.scale }
    /// The board under the pointer (including its title row and the hover bar).
    var hoveredID: String? {
        didSet { if hoveredID != oldValue { chromeDidChange() } }
    }
    /// An element outlined on a board (its box in the board's CSS pixels), while its pointer menu is open.
    var outlinedElement: (boardID: String, box: CGRect)? {
        didSet { chromeDidChange() }
    }
    /// The board the hover bar belongs to: the hovered one, else the first selected one.
    var hoverTargetID: String? { hoveredID ?? selectedIDs.first }

    let hoverBar = HoverBar()
    private(set) var boardViews: [String: ArtboardView] = [:]
    private let boardLayer = PassthroughView()
    private let overlay = CanvasOverlayView()
    /// The viewport the board views were last laid out for.
    private var laidOutViewport = Viewport()
    private var laidOutSize: CGSize = .zero
    private var settleTask: Task<Void, Never>?
    var animation: ViewportAnimation?
    private var animationLink: CADisplayLink?
    var drag: Drag?
    var spaceHeld = false { didSet { updateCursor() } }
    private var lastHoverTarget: String?

    enum Drag {
        case pan(last: CGPoint)
        case move(id: String, grab: CGPoint, startOrigin: CGPoint, moved: Bool)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
        // Views don't clip their subviews by default; boards, web views, titles and the hover bar stay inside.
        clipsToBounds = true
        boardLayer.wantsLayer = true
        addSubview(boardLayer)
        addSubview(overlay)
        hoverBar.isHidden = true
        addSubview(hoverBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        boardLayer.frame = bounds
        overlay.frame = bounds
        settle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimation() }
    }

    func boardView(_ id: String) -> ArtboardView? {
        boardViews[id]
    }

    func board(_ id: String) -> CanvasBoard? {
        boards.first { $0.id == id }
    }

    /// The board's on-screen rect in the current viewport, snapped to device pixels. Board views,
    /// outlines, hit-testing and the hover bar all use this one rect.
    func screenRect(ofBoard id: String) -> CGRect? {
        board(id).map { screenRect(of: $0.rect, in: viewport) }
    }

    /// A point given in a board's CSS pixels (canvas points from its top-left corner), on screen now.
    func screenPoint(onBoard id: String, at boardPoint: CGPoint) -> CGPoint? {
        board(id).map { viewport.screenPoint(fromCanvas: CGPoint(x: $0.rect.minX + boardPoint.x, y: $0.rect.minY + boardPoint.y)) }
    }

    /// The smallest rect around the given boards (all when nil), in canvas points.
    func boundsOfBoards(_ ids: [String]? = nil) -> CGRect? {
        Viewport.boundingRect(of: boards.filter { ids?.contains($0.id) ?? true }.map(\.rect))
    }

    /// The canvas point at the centre of the screen.
    var visibleCentre: CGPoint {
        viewport.canvasPoint(fromScreen: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// `rect` (canvas points) on screen in `viewport`, snapped like `screenRect(ofBoard:)`.
    func screenRect(of rect: CGRect, in viewport: Viewport) -> CGRect {
        backingAlignedRect(viewport.screenRect(fromCanvas: rect), options: .alignAllEdgesNearest)
    }

    // MARK: - Boards

    private func boardsDidChange() {
        let ids = Set(boards.map(\.id))
        for (id, view) in boardViews where !ids.contains(id) {
            view.removeFromSuperview()
            boardViews[id] = nil
        }
        for board in boards where boardViews[board.id] == nil {
            let view = ArtboardView(artboardID: board.id)
            boardViews[board.id] = view
            boardLayer.addSubview(view)
        }
        if hoveredID.map({ !ids.contains($0) }) == true { hoveredID = nil }
        layOutBoards(in: laidOutViewport)
        chromeDidChange()
    }

    /// Frames every board for `viewport` and fits live pages to them.
    private func layOutBoards(in viewport: Viewport) {
        for board in boards {
            boardViews[board.id]?.place(at: screenRect(of: board.rect, in: viewport), boardSize: board.rect.size)
        }
    }

    // MARK: - Viewport

    /// Moves the viewport cheaply (new board-layer bounds) and lays boards out properly once it stops.
    func setViewport(_ newViewport: Viewport) {
        let zoomChanged = newViewport.scale != viewport.scale
        viewport = newViewport
        boardLayer.bounds = viewport.layerBounds(laidOutFor: laidOutViewport, frameSize: boardLayer.frame.size)
        chromeDidChange()
        if zoomChanged { delegate?.canvasViewDidChangeZoom(self) }
        scheduleSettle()
    }

    func show(_ target: Viewport, animated: Bool) {
        stopAnimation()
        guard animated else { return setViewport(target) }
        animation = ViewportAnimation(from: viewport, to: target, screenSize: bounds.size)
        animationLink = displayLink(target: self, selector: #selector(stepAnimation))
        animationLink?.add(to: .main, forMode: .common)
    }

    func stopAnimation() {
        animation = nil
        animationLink?.invalidate()
        animationLink = nil
    }

    @objc private func stepAnimation() {
        guard let animation else { return stopAnimation() }
        let (frame, done) = animation.frame(at: .now)
        setViewport(frame)
        if done { stopAnimation() }
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    private func settle() {
        settleTask?.cancel()
        laidOutViewport = viewport
        boardLayer.bounds = CGRect(origin: .zero, size: boardLayer.frame.size)
        layOutBoards(in: viewport)
        delegate?.canvasViewDidSettle(self)
    }

    // MARK: - Zoom commands

    /// The viewport that shows all of `rect` with the standard padding.
    func fitting(_ rect: CGRect) -> Viewport {
        Viewport.fitting(rect, screenSize: bounds.size, padding: Self.fitPadding)
    }

    func zoomToFit(animated: Bool = true) {
        guard let all = boundsOfBoards() else { return }
        show(fitting(all), animated: animated)
    }

    func zoomToSelection() {
        guard let selected = boundsOfBoards(selectedIDs) else { return zoomToFit() }
        show(fitting(selected), animated: true)
    }

    /// Zooms to `scale` around the centre of the screen.
    func zoom(to scale: CGFloat, animated: Bool = true) {
        show(Viewport.centred(on: visibleCentre, scale: scale, screenSize: bounds.size), animated: animated)
    }

    // MARK: - Titles, outlines and the hover bar

    func chromeDidChange() {
        overlay.update(
            boards: boards.map { ($0, screenRect(of: $0.rect, in: viewport)) },
            selectedIDs: Set(selectedIDs), hoveredID: hoveredID, elementOutline: outlinedElementRect()
        )
        placeHoverBar()
        if hoverTargetID != lastHoverTarget {
            lastHoverTarget = hoverTargetID
            delegate?.canvasViewDidChangeHoverTarget(self)
        }
    }

    /// The outlined element on screen, clipped to its board.
    private func outlinedElementRect() -> CGRect? {
        guard let outlinedElement, let board = board(outlinedElement.boardID) else { return nil }
        let box = outlinedElement.box.offsetBy(dx: board.rect.minX, dy: board.rect.minY).intersection(board.rect)
        return box.isNull ? nil : screenRect(of: box, in: viewport)
    }

    /// Right-aligned in the strip above the target board.
    func placeHoverBar() {
        guard let id = hoverTargetID, let rect = screenRect(ofBoard: id) else {
            hoverBar.isHidden = true
            return
        }
        let size = hoverBar.fittingSize
        let middle = rect.minY - CanvasOverlayView.titleRowHeight / 2
        hoverBar.frame = backingAlignedRect(
            CGRect(x: rect.maxX - size.width, y: middle - size.height / 2, width: size.width, height: size.height),
            options: .alignAllEdgesNearest
        )
        hoverBar.isHidden = false
    }
}

/// A view that only passes hits on to its subviews, never claiming one itself.
final class PassthroughView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// An ease-out move between two viewports over a fixed time.
struct ViewportAnimation {
    let from: Viewport
    let to: Viewport
    let screenSize: CGSize
    let start = ContinuousClock.now
    let duration: Duration = .milliseconds(280)

    func frame(at now: ContinuousClock.Instant) -> (Viewport, done: Bool) {
        let progress = min(max((now - start) / duration, 0), 1)
        let eased = CGFloat(1 - pow(1 - progress, 3))
        return (Viewport.interpolated(from: from, to: to, progress: eased, screenSize: screenSize), progress >= 1)
    }
}
