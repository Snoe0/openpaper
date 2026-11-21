import AppKit
import CanvasCore

/// What's selected: one board's name, size, page and mode (and the inspected element), a count
/// for several boards, or a hint for none. Follows renames and resizes as the document changes.
@MainActor
final class SelectionSection: PanelSection {
    private let document: CanvasDocument
    private let placeholder = Theme.label("No artboard selected", color: Theme.tertiaryText)
    private let name = InfoRow("Name")
    private let size = InfoRow("Size")
    private let page = InfoRow("Page")
    private let mode = InfoRow("Mode")
    private let element = InfoRow("Element")
    private var selection = CanvasSelection()
    private var subscription: ChangeSubscription?

    init(document: CanvasDocument) {
        self.document = document
        super.init(title: "Artboard")
        addContent(Theme.column([placeholder, name, size, page, mode, element], spacing: 6))
        subscription = document.onChange { [weak self] change in
            if change == .manifest { self?.refresh() }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ selection: CanvasSelection) {
        self.selection = selection
        refresh()
    }

    private func refresh() {
        let ids = selection.artboardIDs
        let info = ids.count == 1 ? document.info(ofArtboard: ids[0]) : nil
        placeholder.stringValue = ids.count > 1 ? "\(ids.count) artboards selected" : "No artboard selected"
        placeholder.isHidden = info != nil
        for row in [name, size, page, mode] { row.isHidden = info == nil }
        element.isHidden = info == nil || selection.element == nil
        guard let info else { return }
        name.show(info.name)
        size.show(info.size)
        page.show(info.page)
        mode.show(info.mode)
        element.show(selection.element?.selector ?? "")
    }
}
