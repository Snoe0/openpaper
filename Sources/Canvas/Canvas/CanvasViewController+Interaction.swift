import AppKit
import CanvasCore

/// Clicks, moves, inspect mode, the hover bar, and messages from the pages' runtime.
extension CanvasViewController: CanvasViewDelegate {
    func canvasView(_ canvasView: CanvasView, didClickBoard id: String?, extendingSelection: Bool) {
        if inspectedID != nil, id != inspectedID { stopInspecting() }
        guard let id else { return select([]) }
        if tool == .inspect {
            select([id])
            return startInspecting(id)
        }
        guard extendingSelection else { return select([id]) }
        let ids = selection.artboardIDs
        select(ids.contains(id) ? ids.filter { $0 != id } : ids + [id])
    }

    /// Double-click inspects the board and switches to the inspect tool, so a tool rail stays truthful.
    func canvasView(_ canvasView: CanvasView, didDoubleClickBoard id: String) {
        select([id])
        setTool(.inspect)
    }

    func canvasView(_ canvasView: CanvasView, didMoveBoard id: String, to origin: CGPoint) {
        do {
            try document?.updateArtboard(id: id, x: origin.x, y: origin.y)
        } catch {
            syncToManifest()
        }
    }

    func canvasViewDidChangeZoom(_ canvasView: CanvasView) {
        onZoomChange?(zoom)
    }

    func canvasViewDidSettle(_ canvasView: CanvasView) {
        updateVisibility()
    }

    func canvasViewDidChangeHoverTarget(_ canvasView: CanvasView) {
        refreshHoverBar()
    }

    func canvasViewDidPressEscape(_ canvasView: CanvasView) {
        leaveInspectMode()
    }

    // MARK: - Inspect mode

    /// Lets the board's page take the pointer and highlight elements; it stays live while inspected.
    func startInspecting(_ id: String) {
        guard inspectedID != id else { return }
        stopInspecting()
        inspectedID = id
        updateVisibility()
        if let live = liveBoards[id], live.isReady { turnOnInspect(live) }
    }

    /// Esc or the page's own exit: stop inspecting and go back to the select tool.
    func leaveInspectMode() {
        guard inspectedID != nil || tool == .inspect else { return }
        setTool(.select)
    }

    func stopInspecting() {
        guard let id = inspectedID else { return }
        inspectedID = nil
        if let live = liveBoards[id] {
            live.evaluate("Canvas.inspect(false)")
            live.webView.acceptsMouse = false
        }
        view.window?.makeFirstResponder(canvasView)
        updateVisibility()
    }

    private func turnOnInspect(_ live: LiveBoard) {
        live.webView.acceptsMouse = true
        live.evaluate("Canvas.inspect(true)")
        view.window?.makeFirstResponder(live.webView)
    }

    // MARK: - Runtime messages

    func handleMessage(_ body: [String: Any], from live: LiveBoard) {
        switch body["type"] as? String {
        case "ready": pageBecameReady(live)
        case "console": recordConsole(body, from: live.artboardID)
        case "select" where inspectedID == live.artboardID: selectElement(Self.element(from: body, in: live.artboardID))
        case "inspectExit" where inspectedID == live.artboardID: leaveInspectMode()
        default: break
        }
    }

    /// A freshly loaded page starts playing: pause it if the user paused it or it is no longer live.
    private func pageBecameReady(_ live: LiveBoard) {
        let id = live.artboardID
        if userPaused.contains(id) || !pool.live.contains(id) { live.evaluate("Canvas.pause()") }
        if inspectedID == id { turnOnInspect(live) }
    }

    private func recordConsole(_ body: [String: Any], from id: String) {
        consoleLog.append(ConsoleEntry(
            artboardID: id, level: body["level"] as? String ?? "log", message: body["message"] as? String ?? "", timestamp: Date()
        ))
    }

    private static func element(from body: [String: Any], in id: String) -> SelectedElement {
        let rect = body["rect"] as? [String: Any] ?? [:]
        let number = { (key: String) in (rect[key] as? NSNumber)?.doubleValue ?? 0 }
        return SelectedElement(
            artboardID: id,
            selector: body["selector"] as? String ?? "",
            outerHTML: body["outerHTML"] as? String ?? "",
            rect: ElementRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
        )
    }

    // MARK: - Hover bar

    func connectHoverBar() {
        let bar = canvasView.hoverBar
        bar.onTogglePlay = { [weak self] in self?.togglePlay() }
        bar.onRestart = { [weak self] in self?.restart() }
        bar.onCycleMode = { [weak self] in self?.cycleMode() }
    }

    func refreshHoverBar() {
        guard let id = canvasView.hoverTargetID, let document, let board = try? document.artboard(id: id) else { return }
        let mode = document.tokens.modes.count > 1 ? board.effectiveMode(in: document.manifest) : nil
        canvasView.hoverBar.show(isPaused: userPaused.contains(id), mode: mode, canRestart: pool.live.contains(id))
        canvasView.placeHoverBar()
    }

    private func togglePlay() {
        guard let id = canvasView.hoverTargetID else { return }
        let isLive = pool.live.contains(id)
        if userPaused.remove(id) != nil {
            if isLive { liveBoards[id]?.evaluate("Canvas.resume()") }
        } else {
            userPaused.insert(id)
            if isLive { liveBoards[id]?.evaluate("Canvas.pause()") }
        }
        refreshHoverBar()
    }

    /// Replays the board's animations, or reloads it if its runtime isn't up.
    private func restart() {
        guard let id = canvasView.hoverTargetID, pool.live.contains(id), let live = liveBoards[id] else { return }
        if live.isReady { live.evaluate("Canvas.restart()") } else { reload(live) }
    }

    /// Saves the next token mode on the board; the manifest sync switches the live page to it.
    private func cycleMode() {
        guard let id = canvasView.hoverTargetID, let document, let board = try? document.artboard(id: id) else { return }
        let modes = document.tokens.modes
        guard modes.count > 1 else { return }
        let current = modes.firstIndex(of: board.effectiveMode(in: document.manifest)) ?? -1
        try? document.updateArtboard(id: id, mode: .some(modes[(current + 1) % modes.count]))
        refreshHoverBar()
    }
}
