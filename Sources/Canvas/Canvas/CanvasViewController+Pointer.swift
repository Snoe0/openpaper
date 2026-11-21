import AppKit
import CanvasCore
import WebKit

/// Pointers: right-clicking a board copies a pointer to it, or to the element under the cursor, and
/// `get_element` asks a board's page which element a pointer's selector matches.
extension CanvasViewController {
    /// How long a page may take to load or answer a question.
    nonisolated static let pageAnswerTimeout: Duration = .seconds(5)
    /// How long a right-click waits for the element under it; past that the menu offers the board only.
    static let menuLookupDeadline: Duration = .milliseconds(1500)

    /// On the page, the menu offers Copy pointer, Copy board pointer and Copy HTML for the element under the
    /// cursor; on the title, the page background, or a page that doesn't answer in time, only Copy board pointer.
    /// The board is kept live (so its page can be asked), and the element outlined, while the menu is open. A new
    /// right-click replaces one still waiting. `boardPoint` is in the board's CSS pixels.
    func canvasView(_ canvasView: CanvasView, didRequestMenuForBoard id: String, at boardPoint: CGPoint, onTitle: Bool) {
        pointing?.lookup?.cancel()
        let request = PointerRequest(boardID: id, point: boardPoint)
        pointing = request
        updateVisibility()
        request.lookup = Task { [weak self] in
            let element = onTitle ? nil : await self?.elementWithinDeadline(onBoard: id, at: boardPoint)
            guard !Task.isCancelled else {
                self?.finishPointing(request)
                return
            }
            self?.openPointerMenu(for: request, element: element)
        }
    }

    /// The first element `selector` matches on the board's page, nil when none does: asked of the live page when
    /// the board has one, so it matches what the user sees, else of the page loaded off screen.
    func element(onArtboard id: String, matching selector: String) async throws -> PageElement? {
        do {
            let page = try await pageToAsk(id)
            return try await element(on: page, "return Canvas.describe(selector)", ["selector": selector])
        } catch let error as SnapshotError {
            throw error == .timedOut ? PageQueryError.noAnswer(id) : PageQueryError.didNotLoad(id)
        } catch DocumentError.notFound {
            throw PageQueryError.boardGone(id)
        }
    }

    // MARK: - Menu

    private func elementWithinDeadline(onBoard id: String, at point: CGPoint) async -> PageElement? {
        (try? await withTimeout(Self.menuLookupDeadline) { [weak self] in await self?.element(onBoard: id, at: point) }) ?? nil
    }

    /// The element at `point` (board CSS pixels); nil on the page background, or when the page doesn't load or answer.
    private func element(onBoard id: String, at point: CGPoint) async -> PageElement? {
        guard let live = await loadedLivePage(of: id) else { return nil }
        return try? await element(on: live, "return Canvas.elementAt(x, y)", ["x": point.x, "y": point.y])
    }

    /// Opens the menu once the current task step is done (the menu runs its own event loop until it closes, which
    /// shouldn't happen inside a task), where the right-click landed on the board now; not if a newer right-click
    /// took over, the canvas left its window, or the board is gone. Then the outline goes and the board may stop
    /// being live.
    private func openPointerMenu(for request: PointerRequest, element: PageElement?) {
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pointing === request else { return }
                let canvasView = self.canvasView
                if canvasView.window != nil, let point = canvasView.screenPoint(onBoard: request.boardID, at: request.point) {
                    canvasView.outlinedElement = element.map { (request.boardID, $0.box.cgRect) }
                    self.pointerMenu(board: request.boardID, element: element).popUp(positioning: nil, at: point, in: canvasView)
                    canvasView.outlinedElement = nil
                }
                self.finishPointing(request)
            }
        }
    }

    private func finishPointing(_ request: PointerRequest) {
        guard pointing === request else { return }
        pointing = nil
        updateVisibility()
    }

    private func pointerMenu(board id: String, element: PageElement?) -> NSMenu {
        let menu = NSMenu()
        if let element {
            menu.addItem(MenuAction.item("Copy pointer") { Clipboard.copy(CanvasPointer.element(board: id, selector: element.selector).description) })
        }
        menu.addItem(MenuAction.item("Copy board pointer") { Clipboard.copy(CanvasPointer.board(id).description) })
        if let element {
            menu.addItem(MenuAction.item("Copy HTML") { Clipboard.copy(element.outerHTML) })
        }
        return menu
    }

    // MARK: - Asking a page

    /// The board's live page once its pending changes have landed and it has loaded, or nil if the board isn't
    /// live or its page doesn't load in time.
    private func loadedLivePage(of id: String) async -> LiveBoard? {
        guard pool.live.contains(id), let live = liveBoards[id] else { return nil }
        await live.waitForChanges()
        guard liveBoards[id] === live, await live.waitUntilLoaded(timeout: Self.pageAnswerTimeout) else { return nil }
        return live
    }

    private func pageToAsk(_ id: String) async throws -> LiveBoard {
        if let live = await loadedLivePage(of: id) { return live }
        return try await offscreenPage(of: id)
    }

    /// The board's page loaded in a web view of its own size that is never shown (nor in a window, so its
    /// requestAnimationFrame callbacks don't run).
    private func offscreenPage(of id: String) async throws -> LiveBoard {
        guard let document, let schemeHandler else { throw DocumentError.notFound(id) }
        let board = try document.artboard(id: id)
        let page = LiveBoard(artboardID: id, schemeHandler: schemeHandler, receivesMessages: false)
        page.layout(size: CGSize(width: board.width, height: board.height))
        page.load()
        guard await page.waitUntilLoaded(timeout: Self.pageAnswerTimeout) else { throw SnapshotError.loadFailed }
        return page
    }

    /// Runs a runtime query (`Canvas.elementAt`, `Canvas.describe`) on the page; nil when it finds no element.
    /// Throws if the page fails or doesn't answer in time.
    private func element(on page: LiveBoard, _ script: String, _ arguments: [String: Any]) async throws -> PageElement? {
        try await withTimeout(Self.pageAnswerTimeout) { [webView = page.webView] in
            try PageElement.decode(runtimeValue: try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page))
        }
    }
}

/// A right-click on a board: its menu is being prepared or is open, and the board stays live meanwhile.
@MainActor
final class PointerRequest {
    let boardID: String
    /// Where the right-click landed, in the board's CSS pixels.
    let point: CGPoint
    var lookup: Task<Void, Never>?

    init(boardID: String, point: CGPoint) {
        self.boardID = boardID
        self.point = point
    }
}

/// Why `get_element` couldn't ask a board's page.
enum PageQueryError: LocalizedError {
    case didNotLoad(String)
    case noAnswer(String)
    case boardGone(String)

    var errorDescription: String? {
        let seconds = CanvasViewController.pageAnswerTimeout.components.seconds
        return switch self {
        case .didNotLoad(let id): "Artboard \(id)'s page didn't load within \(seconds) s."
        case .noAnswer(let id): "Artboard \(id)'s page didn't answer within \(seconds) s."
        case .boardGone(let id): "Artboard \(id) no longer exists."
        }
    }
}

private extension ElementRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Where Copy puts text: the general pasteboard. In Debug builds `CANVAS_PASTEBOARD=<name>` uses a private named
/// pasteboard instead, so scripted runs (DevRemote) never touch the user's clipboard.
@MainActor
enum Clipboard {
    static var pasteboard: NSPasteboard {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["CANVAS_PASTEBOARD"], !name.isEmpty {
            return NSPasteboard(name: NSPasteboard.Name(name))
        }
        #endif
        return .general
    }

    static func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
