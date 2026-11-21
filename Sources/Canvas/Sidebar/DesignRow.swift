import CanvasCore

/// One row of the sidebar's Design list: Pages, then the current page's Artboards, then Components.
enum DesignRow: Equatable {
    enum Section: String {
        case pages = "Pages"
        case artboards = "Artboards"
        case components = "Components"
    }

    case header(Section)
    case page(Page, isCurrent: Bool)
    case artboard(Artboard)
    case component(String)
    /// Stands in for an empty section.
    case empty(String)

    @MainActor
    static func rows(for document: CanvasDocument) -> [DesignRow] {
        let current = document.currentPage.id
        let pages = document.manifest.pages.map { DesignRow.page($0, isCurrent: $0.id == current) }
        let artboards = document.artboards().map(DesignRow.artboard)
        let components = document.componentNames.map(DesignRow.component)
        return [.header(.pages)] + pages
            + [.header(.artboards)] + (artboards.isEmpty ? [.empty("No artboards on this page")] : artboards)
            + [.header(.components)] + (components.isEmpty ? [.empty("No components")] : components)
    }

    var isHeader: Bool {
        if case .header = self { true } else { false }
    }
}
