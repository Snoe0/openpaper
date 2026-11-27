import AppKit
import CanvasCore

/// The main window and the commands behind the menus, tool rail and Dashboard buttons, which reach
/// it through the responder chain (it is the window's delegate).
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let workspace: Workspace
    private let main: MainViewController
    private let presentation = PresentationController()
    private var isSidebarHidden = false

    init(workspace: Workspace, agent: AgentConnection) {
        self.workspace = workspace
        main = MainViewController(workspace: workspace, agent: agent)
        super.init(window: Self.makeWindow())
        window?.delegate = self
        window?.contentViewController = main
        window?.setContentSize(NSSize(width: 1400, height: 900))
        window?.center()
        workspace.onChange = { [weak self] in self?.workspaceDidChange() }
        workspaceDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func workspaceDidChange() {
        workspace.activeTab?.setSidebarHidden(isSidebarHidden)
        main.refresh()
        window?.title = workspace.activeDocument?.name ?? "Canvas"
        #if DEBUG
        if let window { DevHooks.pointRemote(at: workspace.activeCanvas, in: window) }
        #endif
    }

    // MARK: - File

    @objc func newDocument(_ sender: Any?) {
        guard let window else { return }
        DocumentPanels.chooseNewDocumentLocation(in: window) { [weak self] url in self?.create(url) }
    }

    @objc func openDocument(_ sender: Any?) {
        guard let window else { return }
        DocumentPanels.chooseDocumentToOpen(in: window) { [weak self] url in self?.open(url) }
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        (sender.representedObject as? URL).map(open)
    }

    @objc func closeTab(_ sender: Any?) {
        workspace.activeTab.map(workspace.close)
    }

    func open(_ url: URL) {
        attempt("Couldn't open the document") { try workspace.openDocument(at: url) }
    }

    private func create(_ url: URL) {
        attempt("Couldn't create the document") { try workspace.createDocument(at: url) }
    }

    // MARK: - View

    @objc func zoomIn(_ sender: Any?) { workspace.activeCanvas?.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { workspace.activeCanvas?.zoomOut() }
    @objc func actualSize(_ sender: Any?) { workspace.activeCanvas?.setZoom(1) }
    @objc func zoomToFit(_ sender: Any?) { workspace.activeCanvas?.zoomToFit() }
    @objc func zoomToSelection(_ sender: Any?) { workspace.activeCanvas?.zoomToSelection() }

    @objc func toggleSidebar(_ sender: Any?) {
        isSidebarHidden.toggle()
        workspace.activeTab?.setSidebarHidden(isSidebarHidden)
    }

    /// Presents the selected board, or the current page's first board.
    @objc func presentArtboard(_ sender: Any?) {
        guard let target = presentationTarget() else { return NSSound.beep() }
        presentation.present(artboard: target.board, in: target.document, from: window)
    }

    private func presentationTarget() -> (board: Artboard, document: CanvasDocument)? {
        guard let tab = workspace.activeTab,
              let board = tab.document.presentationTarget(selectedIDs: tab.canvas.selection.artboardIDs) else { return nil }
        return (board, tab.document)
    }

    // MARK: - Menus

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasTab = workspace.activeTab != nil
        switch item.action {
        case #selector(closeTab), #selector(zoomIn), #selector(zoomOut), #selector(actualSize),
             #selector(zoomToFit), #selector(zoomToSelection):
            return hasTab
        case #selector(toggleSidebar):
            item.title = isSidebarHidden ? "Show Sidebar" : "Hide Sidebar"
            return hasTab
        case #selector(presentArtboard):
            return !presentation.isPresenting && presentationTarget() != nil
        default:
            return true
        }
    }

    /// Fills File ▸ Open Recent as it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in workspace.recentDocuments {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(openRecent), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "No Recent Documents", action: nil, keyEquivalent: "").isEnabled = false
        }
    }

    // MARK: - Helpers

    private func attempt(_ failure: String, _ action: () throws -> Void) {
        do {
            try action()
        } catch {
            window?.showError(error, title: failure)
        }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Canvas"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.canvas
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        return window
    }
}
