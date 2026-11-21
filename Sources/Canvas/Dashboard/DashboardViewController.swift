import AppKit
import CanvasCore

/// The Dashboard tab: New and Open, the recent documents, and the agent (MCP) status.
@MainActor
final class DashboardViewController: NSViewController {
    private static let columnWidth: CGFloat = 520

    private let workspace: Workspace
    private let agent: AgentConnection
    private let recentList = Theme.column([], spacing: 2)

    init(workspace: Workspace, agent: AgentConnection) {
        self.workspace = workspace
        self.agent = agent
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = FillView(Theme.canvas)
        let column = Theme.column([header(), recentSection(), agentSection()], spacing: 28)
        root.addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.widthAnchor.constraint(equalToConstant: Self.columnWidth),
            column.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 72),
        ])
        for section in column.arrangedSubviews {
            section.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        view = root
        refresh()
    }

    /// Lists the recent documents as they are now.
    func refresh() {
        guard isViewLoaded else { return }
        recentList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = workspace.recentDocuments
        if urls.isEmpty {
            recentList.addArrangedSubview(Theme.label("No recent documents. Create one, or open a .canvas folder.", color: Theme.tertiaryText))
        }
        for url in urls {
            let row = RecentRow(url: url) { [weak self] in self?.open(url) }
            recentList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentList.widthAnchor).isActive = true
        }
    }

    private func open(_ url: URL) {
        do {
            try workspace.openDocument(at: url)
        } catch {
            view.window?.showError(error, title: "Couldn't open the document")
        }
    }

    // MARK: - Sections

    private func header() -> NSView {
        let title = Theme.label("Canvas", size: 22, weight: .semibold)
        let new = Theme.button("New Document…", target: nil, action: #selector(MainWindowController.newDocument(_:)))
        let open = Theme.button("Open…", target: nil, action: #selector(MainWindowController.openDocument(_:)))
        return Theme.row([title, NSView(), new, open], spacing: 8)
    }

    private func recentSection() -> NSView {
        let section = Theme.column([Theme.sectionTitle("Recent"), recentList], spacing: 10)
        recentList.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func agentSection() -> NSView {
        let section = AgentSection(agent: agent)
        section.wantsLayer = true
        section.layer?.backgroundColor = Theme.panel.cgColor
        section.layer?.cornerRadius = 8
        return section
    }
}

/// A recent document: its name and folder, highlighted on hover; a click opens it.
@MainActor
private final class RecentRow: FillView {
    private let onOpen: () -> Void

    init(url: URL, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        super.init(.clear)
        wantsLayer = true
        layer?.cornerRadius = 6
        toolTip = url.path
        let name = Theme.label(url.deletingPathExtension().lastPathComponent, size: 13)
        let folder = Theme.label((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath, size: Theme.smallSize, color: Theme.secondaryText)
        folder.lineBreakMode = .byTruncatingMiddle
        let column = Theme.column([name, folder], spacing: 2)
        addSubview(column)
        column.pin(to: self, insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { color = Theme.hover }
    override func mouseExited(with event: NSEvent) { color = .clear }
    override func mouseDown(with event: NSEvent) { onOpen() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
