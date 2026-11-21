import AppKit
import CanvasCore

/// The window's content: the tab bar on top, and below it the Dashboard or the showing document tab.
@MainActor
final class MainViewController: NSViewController {
    private let workspace: Workspace
    private let dashboard: DashboardViewController
    private let tabBar = TabBarView()
    private let content = NSView()
    private var shown: NSViewController?

    init(workspace: Workspace, agent: AgentConnection) {
        self.workspace = workspace
        dashboard = DashboardViewController(workspace: workspace, agent: agent)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = FillView(Theme.canvas)
        root.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        layOut(in: root)
        view = root
        tabBar.onSelect = { [weak self] id in self?.selectTab(id) }
        tabBar.onClose = { [weak self] id in self?.closeTab(id) }
        refresh()
    }

    /// Shows the workspace as it is now: its tabs, and the showing tab's content.
    func refresh() {
        let active = workspace.activeTab
        tabBar.show(tabItems(active: active))
        show(active ?? dashboard)
        if let active { view.window?.makeFirstResponder(active.canvas.canvasView) }
        dashboard.refresh()
    }

    private func tabItems(active: DocumentTabViewController?) -> [TabBarView.Item] {
        [TabBarView.Item(id: nil, title: "Dashboard", isSelected: active == nil)]
            + workspace.tabs.map { TabBarView.Item(id: tabID($0), title: $0.document.name, isSelected: $0 === active) }
    }

    private func show(_ controller: NSViewController) {
        guard controller !== shown else { return }
        shown?.view.removeFromSuperview()
        shown?.removeFromParent()
        addChild(controller)
        content.addFilling(controller.view)
        shown = controller
    }

    private func selectTab(_ id: String?) {
        workspace.show(id.flatMap(tab))
    }

    private func closeTab(_ id: String) {
        tab(id).map(workspace.close)
    }

    private func tab(_ id: String) -> DocumentTabViewController? {
        workspace.tabs.first { tabID($0) == id }
    }

    private func tabID(_ tab: DocumentTabViewController) -> String {
        DocumentLocation.key(for: tab.document.url)
    }

    private func layOut(in root: NSView) {
        let topBar = FillView(Theme.topBar)
        let separator = FillView.separator(vertical: false)
        topBar.addFilling(tabBar)
        for view in [topBar, separator, content] {
            root.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            separator.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            content.topAnchor.constraint(equalTo: separator.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }
}
