import AppKit

/// The quiet single-column list both sidebar modes use: no header, no grid, a soft selection.
@MainActor
enum SidebarTable {
    static let rowHeight: CGFloat = 24

    /// A table inside a borderless, transparent scroll view; returns both.
    static func make(owner: NSTableViewDelegate & NSTableViewDataSource) -> (NSTableView, NSScrollView) {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main")))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = rowHeight
        table.focusRingType = .none
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.delegate = owner
        table.dataSource = owner
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return (table, scroll)
    }

    /// A reusable cell of type `Cell` for `table`.
    static func cell<Cell: NSView>(_ table: NSTableView, _ identifier: String, make: () -> Cell) -> Cell {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let cell = table.makeView(withIdentifier: id, owner: nil) as? Cell { return cell }
        let cell = make()
        cell.identifier = id
        return cell
    }
}

/// Draws selection as a soft rounded fill instead of the accent colour.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 4, yRadius: 4).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A section heading row with an optional trailing "+" button.
final class SidebarHeaderCell: NSTableCellView {
    private let title = Theme.sectionTitle("")
    private let addButton = Theme.iconButton("plus", tooltip: "Add", size: 11, target: nil, action: nil)
    private var onAdd: (() -> Void)?

    init() {
        super.init(frame: .zero)
        addButton.target = self
        addButton.action = #selector(addClicked)
        for view in [title, addButton] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.inset),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.inset),
            addButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String, addTooltip: String? = nil, onAdd: (() -> Void)? = nil) {
        title.stringValue = text
        self.onAdd = onAdd
        addButton.isHidden = onAdd == nil
        addButton.toolTip = addTooltip
    }

    @objc private func addClicked() {
        onAdd?()
    }
}

/// An icon and a title; the title can be edited in place (page renames).
final class SidebarItemCell: NSTableCellView {
    private let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        let field = Theme.label("")
        field.drawsBackground = false
        field.focusRingType = .none
        textField = field
        icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        icon.contentTintColor = Theme.tertiaryText
        imageView = icon
        for view in [icon, field] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.inset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.inset),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String, symbol: String?, emphasized: Bool = false, color: NSColor = Theme.text) {
        textField?.stringValue = text
        textField?.font = .systemFont(ofSize: Theme.bodySize, weight: emphasized ? .medium : .regular)
        textField?.textColor = color
        textField?.isEditable = false
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }
}
