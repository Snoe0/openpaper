import AppKit
import CanvasCore

/// The Design side of the sidebar: pages (switch, add, rename, delete), the current page's
/// artboards (click to select and focus), and components. Follows the document as it changes,
/// whoever changes it.
@MainActor
final class DesignListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    var onFocusArtboard: ((String) -> Void)?

    private let document: CanvasDocument
    private var rows: [DesignRow] = []
    private var selectedArtboards: [String] = []
    private var table: NSTableView!
    private var subscription: ChangeSubscription?
    /// The page being renamed; reloads wait until the rename ends.
    private var renamingPage: Page?

    init(document: CanvasDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let (table, scroll) = SidebarTable.make(owner: self)
        table.allowsMultipleSelection = false
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        table.menu = NSMenu()
        table.menu?.autoenablesItems = false
        table.menu?.delegate = self
        self.table = table
        view = scroll
        subscription = document.onChange { [weak self] change in self?.documentDidChange(change) }
        reload()
    }

    /// Highlights the boards selected on the canvas.
    func showSelection(_ ids: [String]) {
        selectedArtboards = ids
        applySelection()
    }

    // MARK: - Updating

    private func documentDidChange(_ change: DocumentChange) {
        switch change {
        case .manifest, .component: reload()
        case .artboard, .tokens, .asset: break
        }
    }

    private func reload() {
        guard renamingPage == nil else { return }
        rows = DesignRow.rows(for: document)
        table.reloadData()
        applySelection()
    }

    private func applySelection() {
        guard isViewLoaded else { return }
        let indexes = rows.indices.filter { if case .artboard(let board) = rows[$0] { selectedArtboards.contains(board.id) } else { false } }
        // Single selection: with several boards selected on the canvas, the first is highlighted.
        table.selectRowIndexes(IndexSet(indexes.prefix(1)), byExtendingSelection: false)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].isHeader ? 32 : SidebarTable.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .artboard = rows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let section):
            let cell = SidebarTable.cell(tableView, "header", make: SidebarHeaderCell.init)
            cell.show(section.rawValue, addTooltip: "Add Page", onAdd: section == .pages ? { [weak self] in self?.addPage() } : nil)
            return cell
        case .page(let page, let isCurrent):
            return item(page.name, symbol: "doc", emphasized: isCurrent, color: isCurrent ? Theme.text : Theme.secondaryText)
        case .artboard(let board):
            return item(board.name, symbol: "rectangle")
        case .component(let name):
            return item(name, symbol: "diamond")
        case .empty(let text):
            return item(text, symbol: nil, color: Theme.tertiaryText)
        }
    }

    private func item(_ text: String, symbol: String?, emphasized: Bool = false, color: NSColor = Theme.text) -> NSView {
        let cell = SidebarTable.cell(table, "item", make: SidebarItemCell.init)
        cell.show(text, symbol: symbol, emphasized: emphasized, color: color)
        return cell
    }

    // MARK: - Clicks

    @objc private func rowClicked() {
        guard rows.indices.contains(table.clickedRow) else { return }
        switch rows[table.clickedRow] {
        case .page(let page, let isCurrent) where !isCurrent: attempt { try document.switchPage(id: page.id) }
        case .artboard(let board): onFocusArtboard?(board.id)
        default: break
        }
    }

    @objc private func rowDoubleClicked() {
        beginRenaming(row: table.clickedRow)
    }

    // MARK: - Pages

    private func addPage() {
        attempt {
            let page = try document.addPage(name: nextPageName())
            try document.switchPage(id: page.id)
            beginRenaming(row: rows.firstIndex { if case .page(let shown, _) = $0 { shown.id == page.id } else { false } } ?? -1)
        }
    }

    private func nextPageName() -> String {
        let names = Set(document.manifest.pages.map(\.name))
        return ((document.manifest.pages.count + 1)...).lazy.map { "Page \($0)" }.first { !names.contains($0) }!
    }

    private func beginRenaming(row: Int) {
        guard rows.indices.contains(row), case .page(let page, _) = rows[row],
              let field = (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField else { return }
        renamingPage = page
        field.isEditable = true
        field.delegate = self
        view.window?.makeFirstResponder(field)
    }

    /// Esc cancels the rename and puts the old name back.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), let page = renamingPage else { return false }
        (control as? NSTextField)?.stringValue = page.name
        view.window?.makeFirstResponder(table)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let page = renamingPage else { return }
        renamingPage = nil
        field.isEditable = false
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != page.name { attempt { try document.renamePage(id: page.id, to: name) } }
        reload()
    }

    private func confirmDeleting(_ page: Page) {
        guard let window = view.window else { return }
        let count = document.artboards(onPage: page.id).count
        let alert = NSAlert()
        alert.messageText = "Delete “\(page.name)”?"
        alert.informativeText = count == 0 ? "The page is empty." : "Its \(count) artboard\(count == 1 ? "" : "s") and their files will be deleted."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.attempt { try self?.document.deletePage(id: page.id) }
        }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(table.clickedRow), case .page(let page, _) = rows[table.clickedRow] else { return }
        let row = table.clickedRow
        menu.addItem(MenuAction.item("Rename") { [weak self] in self?.beginRenaming(row: row) })
        let delete = MenuAction.item("Delete Page…") { [weak self] in self?.confirmDeleting(page) }
        delete.isEnabled = document.manifest.pages.count > 1
        menu.addItem(delete)
    }

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            view.window?.showError(error, title: "Couldn't change the page")
        }
    }
}
