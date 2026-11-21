import AppKit
import CanvasCore

/// The left sidebar: the document's name, a Design / Tokens toggle, and the chosen list.
@MainActor
final class SidebarViewController: NSViewController {
    var onFocusArtboard: ((String) -> Void)? {
        get { design.onFocusArtboard }
        set { design.onFocusArtboard = newValue }
    }

    private let document: CanvasDocument
    private let design: DesignListController
    private let tokens: TokensListController
    private let toggle = NSSegmentedControl(labels: ["Design", "Tokens"], trackingMode: .selectOne, target: nil, action: nil)
    private let content = NSView()

    init(document: CanvasDocument) {
        self.document = document
        design = DesignListController(document: document)
        tokens = TokensListController(document: document)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        [design, tokens].forEach(addChild)
        view = layOut()
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.selectedSegment = 0
        show(design)
    }

    func showSelection(_ ids: [String]) {
        design.showSelection(ids)
    }

    @objc private func toggled() {
        show(toggle.selectedSegment == 0 ? design : tokens)
    }

    private func show(_ list: NSViewController) {
        content.subviews.forEach { $0.removeFromSuperview() }
        content.addFilling(list.view)
    }

    private func layOut() -> NSView {
        let root = FillView(Theme.panel)
        let name = Theme.label(document.name, size: 13, weight: .semibold)
        toggle.controlSize = .small
        toggle.segmentDistribution = .fillEqually
        let separator = FillView.separator(vertical: false)
        for view in [name, toggle, separator, content] {
            root.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            name.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.inset),
            name.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Theme.inset),
            toggle.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 10),
            toggle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.inset),
            toggle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Theme.inset),
            separator.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: separator.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }
}
