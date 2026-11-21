import AppKit
import CanvasCore

/// One document tab: the sidebar, the tool rail, the canvas and the right panel, kept in step
/// with each other through the canvas's callbacks.
@MainActor
final class DocumentTabViewController: NSViewController {
    let document: CanvasDocument
    let canvas: CanvasViewController
    private let sidebar: SidebarViewController
    private let rail = ToolRailView()
    private let inspector: InspectorViewController
    private let sidebarSeparator = FillView.separator(vertical: true)
    /// The rail sits right of the sidebar, or at the left edge while the sidebar is hidden.
    private var railAfterSidebar: NSLayoutConstraint!
    private var railAtEdge: NSLayoutConstraint!

    /// `canvas` must show a document.
    init(canvas: CanvasViewController, agent: AgentConnection) {
        guard let document = canvas.document else { preconditionFailure("a document tab needs a canvas with a document") }
        self.document = document
        self.canvas = canvas
        sidebar = SidebarViewController(document: document)
        inspector = InspectorViewController(document: document, agent: agent)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        [sidebar, canvas, inspector].forEach(addChild)
        view = makeLayout()
        connectCanvas()
        connectPanels()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        inspector.showZoom(canvas.zoom)
    }

    /// Hides the sidebar by sliding the rail to the left edge; the sidebar keeps its own layout,
    /// so showing it again restores it as it was.
    func setSidebarHidden(_ hidden: Bool) {
        loadViewIfNeeded()
        sidebar.view.isHidden = hidden
        sidebarSeparator.isHidden = hidden
        // Release the old position before taking the new one, so the two never conflict.
        let (off, on) = hidden ? (railAfterSidebar!, railAtEdge!) : (railAtEdge!, railAfterSidebar!)
        off.isActive = false
        on.isActive = true
    }

    // MARK: - Layout

    /// Sidebar | rail | canvas | right panel, separated by hairlines, each full height.
    private func makeLayout() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 860))
        let columns: [NSView] = [
            sidebar.view, sidebarSeparator, rail, FillView.separator(vertical: true),
            canvas.view, FillView.separator(vertical: true), inspector.view,
        ]
        for column in columns {
            root.addSubview(column)
            column.translatesAutoresizingMaskIntoConstraints = false
            column.topAnchor.constraint(equalTo: root.topAnchor).isActive = true
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor).isActive = true
        }
        for (left, right) in zip(columns, columns.dropFirst()) where right !== rail {
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor).isActive = true
        }
        railAfterSidebar = rail.leadingAnchor.constraint(equalTo: sidebarSeparator.trailingAnchor)
        railAtEdge = rail.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        NSLayoutConstraint.activate([
            sidebar.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.view.widthAnchor.constraint(equalToConstant: Theme.panelWidth),
            rail.widthAnchor.constraint(equalToConstant: Theme.railWidth),
            inspector.view.widthAnchor.constraint(equalToConstant: Theme.panelWidth),
            inspector.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            railAfterSidebar,
        ])
        return root
    }

    // MARK: - Wiring

    private func connectCanvas() {
        canvas.onZoomChange = { [weak self] zoom in self?.inspector.showZoom(zoom) }
        canvas.onSelectionChange = { [weak self] selection in self?.selectionDidChange(selection) }
        canvas.onToolChange = { [weak self] tool in self?.rail.show(tool) }
    }

    private func connectPanels() {
        rail.show(canvas.tool)
        rail.onSelect = { [weak canvas] tool in canvas?.setTool(tool) }
        sidebar.onFocusArtboard = { [weak canvas] id in canvas?.focus(artboardID: id) }
        inspector.onZoomIn = { [weak canvas] in canvas?.zoomIn() }
        inspector.onZoomOut = { [weak canvas] in canvas?.zoomOut() }
        inspector.onZoomToFit = { [weak canvas] in canvas?.zoomToFit() }
    }

    private func selectionDidChange(_ selection: CanvasSelection) {
        sidebar.showSelection(selection.artboardIDs)
        inspector.showSelection(selection)
    }
}

extension CanvasViewController {
    func zoomIn() { setZoom(ZoomSteps.zoomedIn(from: zoom)) }
    func zoomOut() { setZoom(ZoomSteps.zoomedOut(from: zoom)) }
}
