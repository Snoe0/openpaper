import AppKit

/// The app chrome's quiet dark look: neutral greys, small system type, hairline separators.
@MainActor
enum Theme {
    static let canvas = CanvasView.background
    static let topBar = NSColor(srgbRed: 0x17 / 255, green: 0x17 / 255, blue: 0x17 / 255, alpha: 1)
    static let panel = NSColor(srgbRed: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255, alpha: 1)
    static let separator = NSColor(white: 1, alpha: 0.08)
    static let hover = NSColor(white: 1, alpha: 0.05)
    static let selection = NSColor(white: 1, alpha: 0.09)
    static let text = NSColor(white: 0.9, alpha: 1)
    static let secondaryText = NSColor(white: 0.55, alpha: 1)
    static let tertiaryText = NSColor(white: 0.38, alpha: 1)
    static let positive = NSColor(srgbRed: 0.40, green: 0.80, blue: 0.55, alpha: 1)
    static let negative = NSColor(srgbRed: 0.95, green: 0.45, blue: 0.40, alpha: 1)

    static let bodySize: CGFloat = 12
    static let smallSize: CGFloat = 11
    static let panelWidth: CGFloat = 240
    static let railWidth: CGFloat = 40
    static let inset: CGFloat = 12

    static func label(_ text: String, size: CGFloat = bodySize, weight: NSFont.Weight = .regular, color: NSColor = Theme.text) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        return label
    }

    /// A section heading, like "Pages" or "Agent".
    static func sectionTitle(_ text: String) -> NSTextField {
        label(text, size: smallSize, weight: .semibold, color: secondaryText)
    }

    /// A borderless SF Symbol button.
    static func iconButton(_ symbol: String, tooltip: String, size: CGFloat = 12, target: AnyObject?, action: Selector?) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        let button = NSButton(image: image ?? NSImage(), target: target, action: action)
        button.isBordered = false
        button.contentTintColor = secondaryText
        button.toolTip = tooltip
        return button
    }

    /// A small rounded push button for panel actions.
    static func button(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: smallSize)
        return button
    }

    /// A leading-aligned vertical stack.
    static func column(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func row(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }
}

/// A plain view filled with one colour.
class FillView: NSView {
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.cgColor
    }

    /// A 1pt hairline; `vertical` for one between columns.
    static func separator(vertical: Bool) -> FillView {
        let line = FillView(Theme.separator)
        line.translatesAutoresizingMaskIntoConstraints = false
        let thickness = vertical ? line.widthAnchor : line.heightAnchor
        thickness.constraint(equalToConstant: 1).isActive = true
        return line
    }
}

extension NSView {
    /// Pins the view to all edges of `superview`, inset by `insets`.
    func pin(to superview: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: superview.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: superview.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: superview.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: superview.bottomAnchor, constant: -insets.bottom),
        ])
    }

    /// Adds `subview` filling this view.
    func addFilling(_ subview: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        addSubview(subview)
        subview.pin(to: self, insets: insets)
    }
}

extension NSWindow {
    /// Shows an error as a sheet on this window.
    func showError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: self)
    }
}
