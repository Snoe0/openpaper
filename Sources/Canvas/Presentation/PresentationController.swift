import AppKit
import CanvasCore

/// Shows one artboard fullscreen, live and interactive, on a black backdrop. Esc or ⌘. exits.
///
/// Fullscreen is a borderless window over the whole screen at just above the menu bar's level, with
/// the menu bar and Dock hidden while the app is active. Unlike native fullscreen it needs no new
/// Space or animation, never touches the document window, works when that window is itself in
/// native fullscreen, and comes and goes instantly.
@MainActor
final class PresentationController {
    /// True while an artboard is on screen.
    private(set) var isPresenting = false

    /// Called after the presentation closes (Esc or `dismiss()`).
    var onDismiss: (() -> Void)?

    private var window: PresentationWindow?
    private var page: PresentedPage?
    private weak var returnWindow: NSWindow?
    private var savedPresentationOptions: NSApplication.PresentationOptions?
    private var eventMonitors: [Any] = []
    private var observers: [any NSObjectProtocol] = []
    private let cursorHider = IdleCursorHider()
    private let repeatSwallower = KeyRepeatSwallower()

    init() {}

    /// Released mid-presentation: still give the app back its menu bar, Dock, cursor and events.
    isolated deinit {
        tearDown()
    }

    /// Fullscreens `artboard` from `document`, fit to the screen of `window` (or the main screen).
    /// While presenting, it replaces the board on show.
    func present(artboard: Artboard, in document: CanvasDocument, from window: NSWindow? = nil) {
        guard let screen = window?.screen ?? Self.fallbackScreen else { return }
        if !isPresenting { enterPresentation(returningTo: window ?? NSApp.keyWindow) }
        showWindow(on: screen)
        show(PresentedPage(artboard: artboard, document: document))
    }

    /// Closes the presentation if one is showing.
    func dismiss() {
        guard isPresenting else { return }
        tearDown()
        onDismiss?()
    }

    private static var fallbackScreen: NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: - Entering

    private func enterPresentation(returningTo window: NSWindow?) {
        isPresenting = true
        returnWindow = window
        hideMenuBarAndDock()
        startWatchingEvents()
        cursorHider.pointerMoved()
    }

    private func showWindow(on screen: NSScreen) {
        let window = self.window ?? makeWindow(on: screen)
        window.cover(screen)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(on screen: NSScreen) -> PresentationWindow {
        let window = PresentationWindow(screen: screen)
        self.window = window
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.takeKeyBackSoon() }
        })
        return window
    }

    private func show(_ newPage: PresentedPage) {
        closePage()
        page = newPage
        newPage.onResize = { [weak self] page in self?.fit(page) }
        newPage.onRemoved = { [weak self] _ in self?.dismiss() }
        fit(newPage)
        newPage.load()
    }

    private func fit(_ page: PresentedPage) {
        guard page === self.page else { return }
        window?.stage.show(page.live, boardSize: page.boardSize)
    }

    // MARK: - Leaving

    /// Everything `dismiss()` undoes, short of telling anyone: safe to run twice.
    private func tearDown() {
        isPresenting = false
        stopWatchingEvents()
        cursorHider.stop()
        closePage()
        closeWindow()
        restorePresentationOptions()
        if let returnWindow, returnWindow.isVisible { returnWindow.makeKeyAndOrderFront(nil) }
        returnWindow = nil
    }

    private func closePage() {
        page?.close()
        page = nil
        window?.stage.removePage()
    }

    private func closeWindow() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    // MARK: - Menu bar and Dock

    /// Skipped when the app is in native fullscreen (AppKit owns the options then); the window's
    /// level covers the menu bar and Dock anyway.
    private func hideMenuBarAndDock() {
        guard savedPresentationOptions == nil, !NSApp.presentationOptions.contains(.fullScreen) else { return }
        savedPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }

    private func restorePresentationOptions() {
        guard let saved = savedPresentationOptions else { return }
        savedPresentationOptions = nil
        NSApp.presentationOptions = saved
    }

    // MARK: - Events

    /// Esc and ⌘. exit (seen before the page, so a page can't swallow them), pointer moves reset the
    /// cursor's idle countdown, and a screen change refits the window.
    private func startWatchingEvents() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let exited = MainActor.assumeIsolated { self?.exitIfExitKey(event) ?? false }
            return exited ? nil : event
        }
        let moves = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.cursorHider.pointerMoved() }
            return event
        }
        eventMonitors = [keys, moves].compactMap { $0 }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        })
    }

    private func stopWatchingEvents() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// Returns whether `event` ended the presentation, so the monitor swallows it; other keys go to
    /// the page. Works whatever window is key, and the key's auto-repeats are swallowed too, so they
    /// don't reach the document window.
    private func exitIfExitKey(_ event: NSEvent) -> Bool {
        guard isPresenting, window?.isVisible == true, Self.isExitKey(event) else { return false }
        repeatSwallower.swallowRepeats(ofKey: event.keyCode)
        dismiss()
        return true
    }

    private static func isExitKey(_ event: NSEvent) -> Bool {
        let escape: UInt16 = 53
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return event.keyCode == escape || (modifiers == .command && event.charactersIgnoringModifiers == ".")
    }

    /// Keeps keys (Delete, arrows) going to the presentation rather than a document window while
    /// presenting; never steals from a modal alert or another app. Deferred, so AppKit finishes the
    /// key change first. Limitation: with several displays, a document window on another screen
    /// can't take typing while a presentation is up.
    private func takeKeyBackSoon() {
        Task { [weak self] in self?.takeKeyBack() }
    }

    private func takeKeyBack() {
        guard isPresenting, NSApp.isActive, NSApp.modalWindow == nil,
              let window, window.isVisible, !window.isKeyWindow else { return }
        window.makeKey()
    }

    private func screensDidChange() {
        guard let window, let screen = window.screen ?? Self.fallbackScreen else { return }
        window.cover(screen)
    }
}
