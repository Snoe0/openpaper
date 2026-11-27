import AppKit
import CanvasCore

/// The open document tabs and which one is showing (nil shows the Dashboard), plus the recent
/// documents. App-lifetime; it is also the `CanvasController` the MCP bridge drives.
@MainActor
final class Workspace {
    /// Called after a tab opens, closes or becomes the showing one.
    var onChange: (() -> Void)?

    private var tabList = TabList<String>()
    private var tabsByKey: [String: DocumentTabViewController] = [:]
    private let recents = RecentDocuments()
    private let agent: AgentConnection

    init(agent: AgentConnection) {
        self.agent = agent
    }

    var tabs: [DocumentTabViewController] {
        tabList.ids.compactMap { tabsByKey[$0] }
    }

    var activeTab: DocumentTabViewController? {
        tabList.selected.flatMap { tabsByKey[$0] }
    }

    var activeCanvas: CanvasViewController? {
        activeTab?.canvas
    }

    /// Opens the document as a new tab, or shows its tab when it's already open.
    @discardableResult
    func openDocument(at url: URL) throws -> CanvasDocument {
        if let tab = tabsByKey[DocumentLocation.key(for: url)] {
            recents.add(url)
            show(tab)
            return tab.document
        }
        return addTab(for: CanvasViewController(document: try CanvasDocument.open(at: url)))
    }

    /// Creates a `Name.canvas` folder at `url` and shows it as a new tab.
    @discardableResult
    func createDocument(at url: URL) throws -> CanvasDocument {
        addTab(for: CanvasViewController(document: try CanvasDocument.create(at: url)))
    }

    /// Shows a canvas made elsewhere (the dev hooks) as a tab, without listing it in recents.
    func adopt(_ canvas: CanvasViewController) {
        guard canvas.document != nil else { return }
        addTab(for: canvas, remember: false)
    }

    /// Shows a tab, or the Dashboard for nil.
    func show(_ tab: DocumentTabViewController?) {
        tabList.select(tab.map(key))
        onChange?()
    }

    /// Closes the tab, releasing its canvas, web views and document watcher.
    func close(_ tab: DocumentTabViewController) {
        let key = key(of: tab)
        tabList.close(key)
        tabsByKey[key] = nil
        onChange?()
    }

    var recentDocuments: [URL] {
        recents.urls
    }

    @discardableResult
    private func addTab(for canvas: CanvasViewController, remember: Bool = true) -> CanvasDocument {
        let tab = DocumentTabViewController(canvas: canvas, agent: agent)
        let key = key(of: tab)
        tabsByKey[key] = tab
        if remember { recents.add(tab.document.url) }
        tabList.open(key)
        onChange?()
        return tab.document
    }

    private func key(of tab: DocumentTabViewController) -> String {
        DocumentLocation.key(for: tab.document.url)
    }
}

enum WorkspaceError: LocalizedError {
    case noDocument

    var errorDescription: String? {
        "No document is open in Canvas. Open or create one first."
    }
}
