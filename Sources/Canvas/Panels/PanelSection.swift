import AppKit

/// A titled panel section with standard padding around its content.
@MainActor
class PanelSection: NSView {
    private let column: NSStackView

    init(title: String) {
        column = Theme.column([Theme.sectionTitle(title)], spacing: 10)
        super.init(frame: .zero)
        addSubview(column)
        column.pin(to: self, insets: NSEdgeInsets(top: 14, left: Theme.inset, bottom: 16, right: Theme.inset))
    }

    /// Adds a block below the title, as wide as the section.
    func addContent(_ content: NSView) {
        column.addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A "Key  value" line, keys in a fixed column.
@MainActor
final class InfoRow: NSStackView {
    private let value = Theme.label("")

    init(_ key: String) {
        super.init(frame: .zero)
        let keyLabel = Theme.label(key, color: Theme.secondaryText)
        keyLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.isSelectable = true
        [keyLabel, value].forEach(addArrangedSubview)
        orientation = .horizontal
        alignment = .firstBaseline
        spacing = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String, color: NSColor = Theme.text) {
        value.stringValue = text
        value.textColor = color
        value.toolTip = text
    }
}
