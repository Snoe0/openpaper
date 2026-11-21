import Foundation

extension CanvasDocument {
    public var currentPage: Page {
        manifest.pages.first { $0.id == manifest.currentPage } ?? manifest.pages[0]
    }

    @discardableResult
    public func addPage(name: String) throws -> Page {
        let page = Page(id: nextPageID(), name: name)
        try updateManifest { $0.pages.append(page) }
        return page
    }

    public func renamePage(id: String, to name: String) throws {
        try updateManifest { manifest in
            manifest.pages[try manifest.pageIndex(id)].name = name
        }
    }

    /// Deletes the page with its artboards and their files.
    /// The boards to remove are taken from the manifest as reloaded for the change, so a board an
    /// outside edit moved off the page keeps its file.
    public func deletePage(id: String) throws {
        var orphans: [Artboard] = []
        try updateManifest { manifest in
            _ = try manifest.pageIndex(id)
            guard manifest.pages.count > 1 else { throw DocumentError.lastPage }
            orphans = manifest.artboards.filter { $0.page == id }
            manifest.pages.removeAll { $0.id == id }
            manifest.artboards.removeAll { $0.page == id }
            if manifest.currentPage == id { manifest.currentPage = manifest.pages[0].id }
        }
        for board in orphans { try files.remove(board.file) }
    }

    public func switchPage(id: String) throws {
        try updateManifest { manifest in
            _ = try manifest.pageIndex(id)
            manifest.currentPage = id
        }
    }

    private func nextPageID() -> String {
        let taken = Set(manifest.pages.map(\.id))
        return (1...).lazy.map { "p\($0)" }.first { !taken.contains($0) }!
    }
}

extension Manifest {
    func pageIndex(_ id: String) throws -> Int {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { throw DocumentError.notFound(id) }
        return index
    }

    func artboardIndex(_ id: String) throws -> Int {
        guard let index = artboards.firstIndex(where: { $0.id == id }) else { throw DocumentError.notFound(id) }
        return index
    }
}
