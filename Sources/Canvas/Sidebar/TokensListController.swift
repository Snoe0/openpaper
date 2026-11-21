import AppKit
import CanvasCore

/// The Tokens side of the sidebar: the document-wide mode switch, and each token's value in that
/// mode, editable in place. Tokens can be added and deleted. Follows the document as it changes.
@MainActor
final class TokensListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let document: CanvasDocument
    private var names: [String] = []
    private var table: NSTableView!
    private let modePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let header = SidebarHeaderCell()
    private var subscription: ChangeSubscription?
    /// Each value field being edited, with the mode it took focus in; reloads wait while any is.
    /// Keyed by field, so tabbing from one value to the next can't mix up their modes.
    private var editingModes: [ObjectIdentifier: String] = [:]

    private var mode: String { document.manifest.mode }

    init(document: CanvasDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let (table, scroll) = SidebarTable.make(owner: self)
        table.selectionHighlightStyle = .none
        table.menu = NSMenu()
        table.menu?.delegate = self
        self.table = table
        view = layOut(scroll)
        modePopUp.target = self
        modePopUp.action = #selector(modeChosen)
        header.show("Tokens", addTooltip: "Add Token") { [weak self] in self?.addToken() }
        subscription = document.onChange { [weak self] change in self?.documentDidChange(change) }
        reload()
    }

    // MARK: - Updating

    private func documentDidChange(_ change: DocumentChange) {
        switch change {
        case .tokens, .manifest: reload()
        case .artboard, .component, .asset: break
        }
    }

    private func reload() {
        guard editingModes.isEmpty else { return }
        names = document.tokens.sortedNames
        table.reloadData()
        showModes()
    }

    private func showModes() {
        modePopUp.removeAllItems()
        modePopUp.addItems(withTitles: document.tokens.modes)
        modePopUp.selectItem(withTitle: mode)
        modePopUp.isEnabled = document.tokens.modes.count > 1
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        names.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = SidebarTable.cell(tableView, "token", make: TokenCell.init)
        cell.show(
            name: names[row], value: document.tokens.value(of: names[row], mode: mode) ?? "",
            onBegin: { [weak self] field in self?.beginEditing(field) },
            onCommit: { [weak self] field, name, edited, shown in self?.commit(edited, of: name, shown: shown, from: field) }
        )
        return cell
    }

    // MARK: - Editing

    @objc private func modeChosen() {
        guard let chosen = modePopUp.titleOfSelectedItem, chosen != mode else { return }
        attempt { try document.setMode(chosen) }
    }

    private func beginEditing(_ field: ObjectIdentifier) {
        editingModes[field] = mode
    }

    /// Saves the value in the mode it was edited in, even if the mode changed meanwhile, and only if
    /// the text changed from what the field showed and the token still exists. The reload waits a
    /// turn: on Tab the next field may already be editing, and reloading now would drop its edit.
    private func commit(_ edited: String, of name: String, shown: String, from field: ObjectIdentifier) {
        let editedMode = editingModes[field] ?? mode
        if let value = document.tokens.committedValue(of: name, edited: edited, shownWhenEditingBegan: shown, mode: editedMode) {
            // Still marked as editing, so the save's own change notification doesn't reload mid-Tab.
            attempt { try document.setTokens([name: value]) }
        }
        editingModes[field] = nil
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    private func addToken() {
        guard let window = view.window else { return }
        let form = TokenForm()
        let alert = NSAlert()
        alert.messageText = "Add Token"
        alert.informativeText = "A new token starts with this value in every mode. To vary it, switch modes and edit the value."
        alert.accessoryView = form
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = form.nameField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            attempt {
                let name = try TokenName.validated(form.nameField.stringValue, existing: document.tokens.sortedNames)
                try document.setTokens([name: .single(form.valueField.stringValue)])
            }
        }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard names.indices.contains(table.clickedRow) else { return }
        let name = names[table.clickedRow]
        menu.addItem(MenuAction.item("Delete Token") { [weak self] in self?.attempt { try self?.document.removeToken(name) } })
    }

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            view.window?.showError(error, title: "Couldn't change the tokens")
        }
    }

    // MARK: - Layout

    private func layOut(_ list: NSView) -> NSView {
        modePopUp.controlSize = .small
        modePopUp.font = .systemFont(ofSize: Theme.smallSize)
        let modeRow = Theme.row([Theme.label("Mode", color: Theme.secondaryText), NSView(), modePopUp])
        let root = NSView()
        for view in [modeRow, header, list] {
            root.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            modeRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            modeRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.inset),
            modeRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Theme.inset),
            header.topAnchor.constraint(equalTo: modeRow.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),
            list.topAnchor.constraint(equalTo: header.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }
}

/// A token row: its name, and its value in the current mode as an in-place editable field.
/// The cell knows its token, so an edit lands on the right one even if rows moved meanwhile.
private final class TokenCell: NSTableCellView {
    private let name = Theme.label("", size: Theme.smallSize, color: Theme.secondaryText)
    private let value = TokenValueField(string: "")
    private var token = ""

    init() {
        super.init(frame: .zero)
        value.isBordered = false
        value.drawsBackground = false
        value.focusRingType = .none
        value.font = .monospacedSystemFont(ofSize: Theme.smallSize, weight: .regular)
        value.textColor = Theme.text
        value.lineBreakMode = .byTruncatingTail
        value.cell?.isScrollable = true
        for view in [name, value] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.inset),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.42),
            value.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.inset),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(
        name text: String, value current: String,
        onBegin: @escaping (_ field: ObjectIdentifier) -> Void,
        onCommit: @escaping (_ field: ObjectIdentifier, _ name: String, _ edited: String, _ shown: String) -> Void
    ) {
        token = text
        name.stringValue = text
        name.toolTip = text
        value.stringValue = current
        value.toolTip = current
        let field = ObjectIdentifier(value)
        value.onBegin = { onBegin(field) }
        value.onEnd = { [weak self] edited, shown in
            guard let self else { return }
            onCommit(field, token, edited, shown)
        }
    }
}

/// A value field that reports when it takes focus and, when editing ends, its text along with the
/// text it showed when it took focus.
private final class TokenValueField: NSTextField {
    var onBegin: (() -> Void)?
    var onEnd: ((_ edited: String, _ shown: String) -> Void)?
    private var shownWhenFocused = ""

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            shownWhenFocused = stringValue
            onBegin?()
        }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onEnd?(stringValue, shownWhenFocused)
    }
}

/// The Add Token sheet's name and value fields.
private final class TokenForm: NSStackView {
    let nameField = NSTextField(string: "")
    let valueField = NSTextField(string: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        orientation = .vertical
        spacing = 8
        nameField.placeholderString = "Name, e.g. color.brand"
        valueField.placeholderString = "Value, e.g. #ff5a1f"
        for field in [nameField, valueField] {
            addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
