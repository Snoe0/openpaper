import AppKit

/// The thin bar across the top of the window: the Dashboard tab, then one tab per open document.
/// It sits in the (transparent) title bar, right of the window buttons.
@MainActor
final class TabBarView: NSView {
    static let height: CGFloat = 30
    /// Room for the close, minimise and zoom buttons.
    private static let windowButtonsWidth: CGFloat = 78

    struct Item: Equatable {
        /// nil for the Dashboard.
        var id: String?
        var title: String
        var isSelected: Bool
    }

    var onSelect: ((String?) -> Void)?
    var onClose: ((String) -> Void)?

    private let stack = Theme.row([], spacing: 2)
    private var shown: [Item] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.windowButtonsWidth),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ items: [Item]) {
        guard items != shown else { return }
        shown = items
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items { stack.addArrangedSubview(makeTab(item)) }
    }

    private func makeTab(_ item: Item) -> TabItemView {
        let tab = TabItemView(item: item)
        tab.onSelect = { [weak self] in self?.onSelect?(item.id) }
        if let id = item.id { tab.onClose = { [weak self] in self?.onClose?(id) } }
        return tab
    }
}

/// One tab: a title (or the Dashboard icon) and, for documents, a close button shown on hover
/// or while selected.
@MainActor
final class TabItemView: NSView {
    private static let maxWidth: CGFloat = 200

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)? {
        didSet { refresh() }
    }

    private let item: TabBarView.Item
    private let closeButton = Theme.iconButton("xmark", tooltip: "Close Tab", size: 8, target: nil, action: nil)
    private var isHovered = false {
        didSet { refresh() }
    }

    init(item: TabBarView.Item) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        toolTip = item.title
        layOut(content: makeContent())
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The tab takes every click but its close button's, so a click on its title selects it
    /// instead of dragging the window (it sits in the title bar).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit == nil || hit === closeButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    private var showsClose: Bool {
        onClose != nil && (item.isSelected || isHovered)
    }

    private func makeContent() -> NSView {
        guard item.id != nil else {
            let icon = NSImageView(image: NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Dashboard") ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            icon.contentTintColor = item.isSelected ? Theme.text : Theme.secondaryText
            return icon
        }
        let title = Theme.label(item.title, color: item.isSelected ? Theme.text : Theme.secondaryText)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        return Theme.row([title, closeButton], spacing: 6)
    }

    private func layOut(content: NSView) {
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func refresh() {
        layer?.backgroundColor = (item.isSelected ? Theme.selection : isHovered ? Theme.hover : .clear).cgColor
        // Faded rather than hidden, so the tab keeps its width.
        closeButton.alphaValue = showsClose ? 1 : 0
        closeButton.isEnabled = showsClose
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
