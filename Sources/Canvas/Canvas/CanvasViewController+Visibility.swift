import AppKit
import CanvasCore

/// Which boards get a live web view, and the snapshots shown for all the others.
extension CanvasViewController {
    /// Gives web views to the boards that qualify now; the rest go through snapshot → pause → detach.
    func updateVisibility() {
        guard document != nil, hasPlacedViewport else { return }
        retryFailedRenders()
        let changes = pool.update(live: desiredLiveBoards())
        changes.pause.forEach(suspend)
        changes.evict.forEach(release)
        changes.resume.forEach(resume)
        changes.load.forEach(loadLive)
        pumpRenderQueue()
        refreshHoverBar()
    }

    /// The policy's choice, with the board whose pointer menu is open and the inspected board kept live
    /// whatever their size (they count toward the capacity and area budget). Boards whose page keeps crashing are left out.
    private func desiredLiveBoards() -> [String] {
        let frames = canvasView.boards.filter { !crashedBoards.contains($0.id) }.map { BoardFrame(id: $0.id, rect: $0.rect) }
        let kept = [pointedID, inspectedID].compactMap { $0 }
        return policy.liveBoards(frames, viewport: canvasView.viewport, screenSize: canvasView.bounds.size, keeping: kept)
    }

    /// Failed off-screen renders get another go, except for boards whose page keeps crashing: those
    /// wait for a content change (`refreshSnapshots`), or every settle would crash a page again.
    private func retryFailedRenders() {
        failedRenders.formIntersection(crashedBoards)
    }

    // MARK: - Pool transitions

    /// Once pending changes land, keeps the page's look as its snapshot (if it has a content key),
    /// then pauses and detaches it.
    private func suspend(_ id: String) {
        guard let live = liveBoards[id] else { return }
        let key = snapshotKeys[id]
        let token = UUID()
        live.suspension = (token, Task { [weak self] in
            await live.waitForChanges()
            if let key { await self?.keepLook(of: live, as: key) }
            self?.finishSuspending(live, token: token)
        })
    }

    /// Stores the page's current look under `key` (if that is still its content key). Skipped while
    /// the window is covered, where WebKit may not answer.
    private func keepLook(of live: LiveBoard, as key: SnapshotKey) async {
        guard isWindowVisible, let size = canvasView.board(live.artboardID)?.rect.size,
              let png = await live.currentLook(nativeSize: size) else { return }
        storeSnapshot(png, for: key)
    }

    /// Pauses and detaches the page, unless a newer suspension owns it or the board became live again.
    private func finishSuspending(_ live: LiveBoard, token: UUID) {
        guard live.suspension?.id == token else { return }
        live.suspension = nil
        guard !pool.live.contains(live.artboardID) || liveBoards[live.artboardID] !== live else { return }
        live.evaluate("Canvas.pause()")
        detach(live)
    }

    /// Drops the board's web view; one still being snapshotted is detached when that finishes.
    func release(_ id: String) {
        guard let live = liveBoards.removeValue(forKey: id) else { return }
        if live.suspension == nil { detach(live) }
    }

    private func resume(_ id: String) {
        guard let live = liveBoards[id] else { return loadLive(id) }
        attach(live)
        if !userPaused.contains(id) { live.evaluate("Canvas.resume()") }
    }

    private func loadLive(_ id: String) {
        guard let schemeHandler, canvasView.board(id) != nil else { return }
        let live = LiveBoard(artboardID: id, schemeHandler: schemeHandler)
        live.onMessage = { [weak self] board, body in self?.handleMessage(body, from: board) }
        live.onLoad = { [weak self] board in self?.canvasView.boardView(board.artboardID)?.revealLoadedPage() }
        live.onCrash = { [weak self] board in self?.pageCrashed(board) }
        live.webView.onContextClick = { [weak self] event in self?.canvasView.rightMouseDown(with: event) }
        liveBoards[id] = live
        attach(live)
        live.load()
    }

    /// A live page comes back a couple of times, then stays a snapshot (rendered off screen if it
    /// has none yet) until its content changes; a paused one is dropped.
    private func pageCrashed(_ live: LiveBoard) {
        let id = live.artboardID
        guard liveBoards[id] === live else { return }
        if pool.live.contains(id), crashRetries.shouldRetry(id, at: ProcessInfo.processInfo.systemUptime) {
            return reload(live)
        }
        if pool.live.contains(id) { crashedBoards.insert(id) }
        pool.remove(id)
        release(id)
        pumpRenderQueue()
    }

    private func attach(_ live: LiveBoard) {
        guard let board = canvasView.board(live.artboardID) else { return }
        canvasView.boardView(live.artboardID)?.attach(live, size: board.rect.size)
    }

    private func detach(_ live: LiveBoard) {
        live.webView.removeFromSuperview()
        canvasView.boardView(live.artboardID)?.forget(live)
    }

    // MARK: - Snapshots

    /// Recomputes the snapshot keys of `ids`. A board whose content changed shows its cached snapshot
    /// if there is one, gets another chance if its page kept crashing, and otherwise waits for a render.
    func refreshSnapshots(of ids: [String]) {
        guard let document, let snapshots else { return }
        var revived = false
        for id in ids {
            guard let board = try? document.artboard(id: id), let html = try? ArtboardPage.html(for: board, in: document) else { continue }
            let key = SnapshotKey(artboardID: id, contentHash: SnapshotKey.contentHash(of: html))
            guard snapshotKeys[id] != key else { continue }
            snapshotKeys[id] = key
            revived = crashedBoards.remove(id) != nil || revived
            crashRetries.reset(id)
            failedRenders.remove(id)
            if let png = snapshots.snapshot(for: key) {
                Task { await showSnapshot(png, on: id) }
            } else {
                snapshots.invalidate(artboardID: id)
            }
        }
        if revived { updateVisibility() }
        pumpRenderQueue()
    }

    /// Shows a snapshot, decoded only as large as it is drawn: by default as large as a board shown
    /// as a snapshot ever needs (below the live threshold), or sharp at a larger `scale` (a live
    /// board's look while it reloads). The full-size PNG stays on disk. Returns once it is shown.
    func showSnapshot(_ png: Data, on id: String, sharpAt scale: CGFloat = 0) async {
        guard let size = canvasView.board(id)?.rect.size, let boardView = canvasView.boardView(id) else { return }
        let pixels = Int((max(size.width, size.height) * max(policy.minLiveScale, scale) * view.screenScale).rounded(.up))
        await boardView.showSnapshot(png, maxPixelSize: max(pixels, 1))
    }

    /// Caches and shows `png`, unless the board's content changed since it was taken.
    private func storeSnapshot(_ png: Data, for key: SnapshotKey) {
        guard snapshotKeys[key.artboardID] == key else { return }
        snapshots?.store(png, for: key)
        Task { await showSnapshot(png, on: key.artboardID) }
    }

    /// Renders boards that have no snapshot, one at a time, nearest the viewport centre first.
    /// A failed render caches nothing and is retried after the next viewport change (see `retryFailedRenders`).
    func pumpRenderQueue() {
        guard hasPlacedViewport, !isRendering, let renderer, let document,
              let id = nextBoardToRender(), let board = try? document.artboard(id: id), let key = snapshotKeys[id] else { return }
        isRendering = true
        Task { [weak self] in
            let png = try? await renderer.render(board)
            guard let self else { return }
            isRendering = false
            if let png { storeSnapshot(png, for: key) } else { failedRenders.insert(id) }
            pumpRenderQueue()
        }
    }

    private func nextBoardToRender() -> String? {
        let waiting = canvasView.boards.filter { needsRender($0.id) }.map { BoardFrame(id: $0.id, rect: $0.rect) }
        return VisibilityPolicy.nearestFirst(waiting, to: canvasView.visibleCentre).first
    }

    private func needsRender(_ id: String) -> Bool {
        guard let key = snapshotKeys[id], !pool.live.contains(id), !failedRenders.contains(id) else { return false }
        return snapshots?.contains(key) == false
    }
}
