import AppKit
import CanvasCore

/// The right panel: zoom, the selected board, and the agent (MCP) status.
@MainActor
final class InspectorViewController: NSViewController {
    var onZoomIn: (() -> Void)? {
        get { zoom.onZoomIn }
        set { zoom.onZoomIn = newValue }
    }
    var onZoomOut: (() -> Void)? {
        get { zoom.onZoomOut }
        set { zoom.onZoomOut = newValue }
    }
    var onZoomToFit: (() -> Void)? {
        get { zoom.onFit }
        set { zoom.onFit = newValue }
    }

    private let zoom = ZoomSection()
    private let selection: SelectionSection
    private let agent: AgentSection

    init(document: CanvasDocument, agent: AgentConnection) {
        selection = SelectionSection(document: document)
        self.agent = AgentSection(agent: agent)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = FillView(Theme.panel)
        let sections: [NSView] = [zoom, FillView.separator(vertical: false), selection, FillView.separator(vertical: false), agent]
        var above = root.topAnchor
        for section in sections {
            root.addSubview(section)
            section.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                section.topAnchor.constraint(equalTo: above),
                section.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                section.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ])
            above = section.bottomAnchor
        }
        view = root
    }

    func showZoom(_ scale: CGFloat) {
        zoom.show(scale)
    }

    func showSelection(_ selected: CanvasSelection) {
        selection.show(selected)
    }
}
