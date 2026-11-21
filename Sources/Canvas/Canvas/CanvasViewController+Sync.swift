import AppKit
import CanvasCore

/// Keeps the canvas in step with the document: reloads edited boards, hot-patches components and
/// tokens into live pages, and follows the manifest (boards added, removed, moved, resized, page switches).
/// Everything a snapshot could see is queued on the page synchronously, so an edit followed at once
/// by `snapshotPNG` shows the edit.
extension CanvasViewController {
    func documentDidChange(_ change: DocumentChange) {
        switch change {
        case .manifest: syncToManifest()
        case .artboard(let id): artboardDidChange(id)
        case .component: componentsDidChange()
        case .tokens: tokensDidChange()
        case .asset: assetsDidChange()
        }
    }

    /// Shows the current page's boards as the manifest has them. Only real differences cost
    /// anything, so the canvas's own saves (a title drag) don't reload pages.
    func syncToManifest() {
        guard let document else { return }
        let old = shownManifest
        shownManifest = document.manifest
        if old == nil { snapshots?.prune(keeping: Set(document.manifest.artboards.map(\.id))) }
        let boards = document.artboards()
        dropBoards(notIn: Set(boards.map(\.id)))
        canvasView.boards = boards.map(CanvasBoard.init)
        refreshSnapshots(of: updateLivePages(of: boards, since: old))
        if let old, old.currentPage != document.manifest.currentPage { canvasView.zoomToFit(animated: false) }
        updateVisibility()
        refreshHoverBar()
    }

    /// Reloads a live page without a blank flash: its current look goes onto the snapshot layer (when
    /// anyone can see it), sharp at the current zoom, and the web view stays hidden until the new page
    /// has loaded. Queued on the page, so snapshots wait for the new page.
    func reload(_ live: LiveBoard) {
        let id = live.artboardID
        live.change { [weak self] in
            guard let self else { return }
            if isWindowVisible, let size = canvasView.board(id)?.rect.size, let png = await live.currentLook(nativeSize: size) {
                await showSnapshot(png, on: id, sharpAt: canvasView.layoutScale)
            }
            canvasView.boardView(id)?.hidePage(of: live)
            live.load()
            await live.waitUntilLoaded()
        }
    }

    // MARK: - Changes

    /// Reloads resized pages and switches modes in place; returns the boards whose rendering changed
    /// (including ones the canvas hasn't shown yet).
    private func updateLivePages(of boards: [Artboard], since old: Manifest?) -> [String] {
        guard let document else { return [] }
        let previous = Dictionary((old?.artboards ?? []).map { ($0.id, $0) }) { first, _ in first }
        var changed: [String] = []
        for board in boards {
            guard let old, let before = previous[board.id], snapshotKeys[board.id] != nil else {
                changed.append(board.id)
                continue
            }
            let resized = before.width != board.width || before.height != board.height
            let modeChanged = before.effectiveMode(in: old) != board.effectiveMode(in: document.manifest)
            guard resized || modeChanged else { continue }
            changed.append(board.id)
            updateLivePage(board, resized: resized)
        }
        return changed
    }

    /// A resized board reloads (its page size is baked in); a new mode is switched in place.
    private func updateLivePage(_ board: Artboard, resized: Bool) {
        guard let document, let live = liveBoards[board.id] else { return }
        if resized {
            reload(live)
        } else {
            hotPatch(live, "Canvas.setMode(mode)", arguments: ["mode": board.effectiveMode(in: document.manifest)])
        }
    }

    private func artboardDidChange(_ id: String) {
        reloadPage(of: id)
        refreshSnapshots(of: [id])
    }

    /// Asset bytes aren't part of the snapshot key, so every board reloads and is snapshotted again,
    /// once per run-loop turn however many files changed.
    private func assetsDidChange() {
        guard !assetRefreshPending else { return }
        assetRefreshPending = true
        Task { [weak self] in self?.refreshAfterAssetChanges() }
    }

    private func refreshAfterAssetChanges() {
        assetRefreshPending = false
        let ids = canvasView.boards.map(\.id)
        for id in ids {
            reloadPage(of: id)
            snapshots?.invalidate(artboardID: id)
            snapshotKeys[id] = nil
        }
        refreshSnapshots(of: ids)
    }

    /// Patches a ready page in place. One still loading may have fetched the old document, so it
    /// reloads instead.
    private func hotPatch(_ live: LiveBoard, _ script: String, arguments: [String: Any]) {
        guard live.isReady else { return reloadPage(of: live.artboardID) }
        live.patch(script, arguments: arguments)
    }

    /// A live page reloads in place; a paused one is dropped and loads fresh when it is next live.
    private func reloadPage(of id: String) {
        if pool.live.contains(id), let live = liveBoards[id] {
            reload(live)
        } else {
            pool.remove(id)
            release(id)
        }
    }

    private func componentsDidChange() {
        guard let document else { return }
        for live in liveBoards.values {
            hotPatch(live, "Canvas.defineComponents(map)", arguments: ["map": document.allComponents()])
        }
        refreshSnapshots(of: canvasView.boards.map(\.id))
    }

    private func tokensDidChange() {
        guard let document else { return }
        let css = TokenCompiler.css(for: document.tokens)
        for live in liveBoards.values {
            guard let board = try? document.artboard(id: live.artboardID) else { continue }
            hotPatch(live, "Canvas.setTokens(css); Canvas.setMode(mode)", arguments: ["css": css, "mode": board.effectiveMode(in: document.manifest)])
        }
        refreshSnapshots(of: canvasView.boards.map(\.id))
        refreshHoverBar()
    }

    /// Forgets boards that left the page (deleted or on another page); deleted ones also lose their
    /// snapshots and console messages.
    private func dropBoards(notIn ids: Set<String>) {
        guard let document else { return }
        let gone = Set(liveBoards.keys).union(snapshotKeys.keys).subtracting(ids)
        for id in gone {
            pool.remove(id)
            release(id)
            snapshotKeys[id] = nil
            userPaused.remove(id)
            crashedBoards.remove(id)
            if (try? document.artboard(id: id)) == nil {
                snapshots?.invalidate(artboardID: id)
                consoleLog.remove(artboardID: id)
            }
        }
        if let inspectedID, !ids.contains(inspectedID) { stopInspecting() }
        let kept = selection.artboardIDs.filter(ids.contains)
        if kept != selection.artboardIDs { select(kept) }
    }
}

extension CanvasBoard {
    init(_ artboard: Artboard) {
        self.init(id: artboard.id, name: artboard.name, rect: CGRect(x: artboard.x, y: artboard.y, width: artboard.width, height: artboard.height))
    }
}
