import AppKit

/// The slim vertical rail of canvas tools, plus Present. Shows the canvas's tool and reports picks.
@MainActor
final class ToolRailView: FillView {
    var onSelect: ((CanvasTool) -> Void)?

    private static let tools: [(CanvasTool, symbol: String, name: String)] = [
        (.select, "cursorarrow", "Select"),
        (.hand, "hand.raised", "Hand — or hold Space"),
        (.inspect, "scope", "Inspect elements — or double-click a board"),
    ]

    private var buttons: [CanvasTool: RailButton] = [:]

    init() {
        super.init(Theme.panel)
        let toolButtons = Self.tools.map { tool, symbol, name in
            let button = RailButton(symbol: symbol, tooltip: name) { [weak self] in self?.onSelect?(tool) }
            buttons[tool] = button
            return button as NSView
        }
        let present = RailButton(symbol: "play", tooltip: "Present (⌘↩)", action: nil)
        present.action = #selector(MainWindowController.presentArtboard(_:))
        present.target = nil
        let stack = Theme.column(toolButtons + [FillView.separator(vertical: false), present], spacing: 4)
        stack.alignment = .centerX
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.arrangedSubviews[Self.tools.count].widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ tool: CanvasTool) {
        for (candidate, button) in buttons { button.isActive = candidate == tool }
    }
}

/// A 28pt square icon button with a soft fill while active.
@MainActor
private final class RailButton: NSButton {
    var isActive = false {
        didSet { refresh() }
    }

    private var onClick: (() -> Void)?

    init(symbol: String, tooltip: String, action onClick: (() -> Void)?) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        isBordered = false
        toolTip = tooltip
        wantsLayer = true
        layer?.cornerRadius = 6
        if onClick != nil {
            target = self
            action = #selector(clicked)
        }
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clicked() {
        onClick?()
    }

    private func refresh() {
        layer?.backgroundColor = (isActive ? Theme.selection : .clear).cgColor
        contentTintColor = isActive ? Theme.text : Theme.secondaryText
    }
}
