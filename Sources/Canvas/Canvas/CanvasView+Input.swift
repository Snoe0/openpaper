import AppKit
import CanvasCore

/// Pointer and keyboard: scroll or space-drag pans, pinch or ⌘-scroll zooms, clicks select,
/// title drags move boards, and ⇧1 / ⇧2 / ⇧0 / Esc.
extension CanvasView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: - Pointer

    override func scrollWheel(with event: NSEvent) {
        stopAnimation()
        let point = location(of: event)
        let lineScale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        if event.modifierFlags.contains(.command) {
            setViewport(viewport.zoomed(by: pow(1.01, event.scrollingDeltaY * lineScale), around: point))
        } else {
            setViewport(viewport.panned(by: CGSize(width: event.scrollingDeltaX * lineScale, height: event.scrollingDeltaY * lineScale)))
        }
    }

    override func magnify(with event: NSEvent) {
        stopAnimation()
        setViewport(viewport.zoomed(by: 1 + event.magnification, around: location(of: event)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stopAnimation()
        let point = location(of: event)
        if tool == .hand || spaceHeld {
            drag = .pan(last: point)
            return updateCursor()
        }
        let hit = boardHit(at: point)
        if event.clickCount == 2, let hit {
            delegate?.canvasView(self, didDoubleClickBoard: hit.id)
            return
        }
        delegate?.canvasView(self, didClickBoard: hit?.id, extendingSelection: event.modifierFlags.contains(.shift))
        if let hit, hit.onTitle, tool == .select, let board = board(hit.id) {
            drag = .move(id: hit.id, grab: viewport.canvasPoint(fromScreen: point), startOrigin: board.rect.origin, moved: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = location(of: event)
        switch drag {
        case .pan(let last):
            drag = .pan(last: point)
            setViewport(viewport.panned(by: CGSize(width: point.x - last.x, height: point.y - last.y)))
        case .move(let id, let grab, let startOrigin, _):
            let now = viewport.canvasPoint(fromScreen: point)
            moveBoard(id, to: CGPoint(x: (startOrigin.x + now.x - grab.x).rounded(), y: (startOrigin.y + now.y - grab.y).rounded()))
            drag = .move(id: id, grab: grab, startOrigin: startOrigin, moved: true)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .move(let id, _, _, true) = drag, let board = board(id) {
            delegate?.canvasView(self, didMoveBoard: id, to: board.rect.origin)
        }
        drag = nil
        updateCursor()
    }

    /// The hover bar can overhang its board (a narrow board, or the strip above it); while the
    /// pointer is on the bar, its board stays hovered.
    override func mouseMoved(with event: NSEvent) {
        let point = location(of: event)
        if !hoverBar.isHidden, hoverBar.frame.contains(point) { return }
        hoveredID = boardHit(at: point)?.id
    }

    override func mouseExited(with event: NSEvent) {
        hoveredID = nil
    }

    private func moveBoard(_ id: String, to origin: CGPoint) {
        guard let index = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[index].rect.origin = origin
    }

    // MARK: - Keys

    private enum Key {
        static let one: UInt16 = 18, two: UInt16 = 19, zero: UInt16 = 29, escape: UInt16 = 53, space: UInt16 = 49
    }

    override func keyDown(with event: NSEvent) {
        let shiftOnly = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.numericPad) == .shift
        switch event.keyCode {
        case Key.one where shiftOnly: zoomToFit()
        case Key.two where shiftOnly: zoomToSelection()
        case Key.zero where shiftOnly: zoom(to: 1)
        case Key.escape: delegate?.canvasViewDidPressEscape(self)
        case Key.space: spaceHeld = true
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == Key.space { spaceHeld = false } else { super.keyUp(with: event) }
    }

    override func resetCursorRects() {
        if tool == .hand || spaceHeld { addCursorRect(bounds, cursor: drag == nil ? .openHand : .closedHand) }
    }

    func updateCursor() {
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Hit testing

    /// The topmost board under `point` (screen), and whether the point is on its drawn title.
    private func boardHit(at point: CGPoint) -> (id: String, onTitle: Bool)? {
        for board in boards.reversed() {
            let rect = screenRect(of: board.rect, in: viewport)
            if rect.contains(point) { return (board.id, false) }
            if CanvasOverlayView.titleRow(above: rect)?.contains(point) == true { return (board.id, true) }
        }
        return nil
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}
