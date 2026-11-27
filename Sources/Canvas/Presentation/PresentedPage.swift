import AppKit
import CanvasCore

/// The one live, interactive page a presentation shows. It stays hidden until the runtime is ready,
/// then restarts its animations so the show starts from the first frame. Edits to the board, its
/// tokens, components or assets reload it (the page bakes in tokens, components and mode), at most
/// once per run-loop turn.
@MainActor
final class PresentedPage {
    let live: LiveBoard
    /// The board as currently shown; its size can change with the manifest.
    private(set) var artboard: Artboard
    /// The board was resized; the stage needs to fit it again.
    var onResize: ((PresentedPage) -> Void)?
    /// The board was deleted from the document.
    var onRemoved: ((PresentedPage) -> Void)?

    private weak var document: CanvasDocument?
    private var subscription: ChangeSubscription?
    private var shownLook: Look
    private var reloadPending = false
    private var crashRetries = CrashRetryLimit()

    var boardSize: CGSize { CGSize(width: artboard.width, height: artboard.height) }

    init(artboard: Artboard, document: CanvasDocument) {
        let current = (try? document.artboard(id: artboard.id)) ?? artboard
        self.artboard = current
        self.document = document
        shownLook = Look(current, in: document.manifest)
        live = LiveBoard(artboardID: current.id, schemeHandler: DocumentSchemeHandler(document: document))
        live.webView.acceptsMouse = true
        live.webView.isHidden = true
        live.onMessage = { [weak self] _, body in self?.handleMessage(body) }
        live.onLoad = { [weak self] _ in self?.reveal() }
        live.onCrash = { [weak self] _ in self?.recoverFromCrash() }
        subscription = document.onChange { [weak self] change in self?.documentDidChange(change) }
    }

    func load() {
        live.load()
    }

    /// Tears the page down: no more document changes, runtime messages or loading.
    func close() {
        subscription?.cancel()
        subscription = nil
        live.onMessage = nil
        live.onLoad = nil
        live.onCrash = nil
        let webView = live.webView
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ArtboardWebViewFactory.messageHandlerName)
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
    }

    // MARK: - Page

    private func handleMessage(_ body: [String: Any]) {
        guard body["type"] as? String == "ready" else { return }
        reveal()
        live.evaluate("Canvas.restart()")
    }

    /// Shows the page and gives it the keyboard. Also on load, so a page whose runtime never
    /// announces itself still shows.
    private func reveal() {
        let webView = live.webView
        guard webView.isHidden else { return }
        webView.isHidden = false
        webView.window?.makeFirstResponder(webView)
    }

    /// A page that keeps crashing gives way to the black backdrop.
    private func recoverFromCrash() {
        guard crashRetries.shouldRetry(artboard.id, at: ProcessInfo.processInfo.systemUptime) else {
            live.webView.isHidden = true
            return
        }
        load()
    }

    // MARK: - Document changes

    private func documentDidChange(_ change: DocumentChange) {
        switch change {
        case .manifest: manifestDidChange()
        case .artboard(let id) where id == artboard.id: reloadSoon()
        case .artboard: break
        case .tokens, .component, .asset: reloadSoon()
        }
    }

    /// Follows the board's size and mode; a deleted board ends the presentation.
    private func manifestDidChange() {
        guard let document, let board = try? document.artboard(id: artboard.id) else {
            onRemoved?(self)
            return
        }
        let look = Look(board, in: document.manifest)
        artboard = board
        guard look != shownLook else { return }
        let resized = look.size != shownLook.size
        shownLook = look
        if resized { onResize?(self) }
        reloadSoon()
    }

    private func reloadSoon() {
        guard !reloadPending else { return }
        reloadPending = true
        Task { [weak self] in self?.reloadIfOpen() }
    }

    private func reloadIfOpen() {
        reloadPending = false
        guard subscription != nil else { return }
        crashRetries.reset(artboard.id)
        load()
    }
}

/// What a page bakes in from the manifest: its CSS size and token mode.
private struct Look: Equatable {
    var size: CGSize
    var mode: String

    init(_ board: Artboard, in manifest: Manifest) {
        size = CGSize(width: board.width, height: board.height)
        mode = board.effectiveMode(in: manifest)
    }
}
