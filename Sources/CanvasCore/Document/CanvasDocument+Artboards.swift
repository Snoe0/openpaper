import Foundation

extension CanvasDocument {
    /// Horizontal gap between a new artboard and the right-most one on its page.
    static let artboardGap: Double = 80

    /// Artboards on a page; nil means the current page.
    public func artboards(onPage pageID: String? = nil) -> [Artboard] {
        let page = pageID ?? currentPage.id
        return manifest.artboards.filter { $0.page == page }
    }

    public func artboard(id: String) throws -> Artboard {
        manifest.artboards[try manifest.artboardIndex(id)]
    }

    /// Adds an artboard; without `x`/`y` it goes right of the right-most artboard on its page, top-aligned with it.
    @discardableResult
    public func addArtboard(
        name: String, width: Double, height: Double, html: String,
        page: String? = nil, x: Double? = nil, y: Double? = nil
    ) throws -> Artboard {
        let pageID = page ?? currentPage.id
        _ = try manifest.pageIndex(pageID)
        try validateGeometry(x: x, y: y, width: width, height: height)
        let board = newArtboard(named: name, page: pageID, width: width, height: height, x: x, y: y, mode: nil)
        try insert(board, html: html)
        return board
    }

    public func html(ofArtboard id: String) throws -> String {
        try files.readText(artboard(id: id).file)
    }

    public func writeHTML(_ html: String, toArtboard id: String) throws {
        try files.write(html, to: artboard(id: id).file)
        notify(.artboard(id: id))
    }

    /// Replaces `old` with `new`; `old` must occur exactly once.
    public func editHTML(ofArtboard id: String, replacing old: String, with new: String) throws {
        let html = try html(ofArtboard: id)
        let matches = old.isEmpty ? [] : html.ranges(of: old)
        guard let match = matches.first else { throw DocumentError.editMatchNotFound }
        guard matches.count == 1 else { throw DocumentError.editMatchNotUnique(count: matches.count) }
        try writeHTML(html.replacingCharacters(in: match, with: new), toArtboard: id)
    }

    /// Changes only the given fields; pass `mode: .some(nil)` to clear the mode override.
    public func updateArtboard(
        id: String, name: String? = nil, x: Double? = nil, y: Double? = nil,
        width: Double? = nil, height: Double? = nil, mode: String?? = nil
    ) throws {
        try validateGeometry(x: x, y: y, width: width, height: height)
        if let mode { try validateMode(mode) }
        try updateManifest { manifest in
            let index = try manifest.artboardIndex(id)
            if let name { manifest.artboards[index].name = name }
            if let x { manifest.artboards[index].x = x }
            if let y { manifest.artboards[index].y = y }
            if let width { manifest.artboards[index].width = width }
            if let height { manifest.artboards[index].height = height }
            if let mode { manifest.artboards[index].mode = mode }
        }
    }

    public func deleteArtboard(id: String) throws {
        let board = try artboard(id: id)
        try updateManifest { $0.artboards.removeAll { $0.id == id } }
        try files.remove(board.file)
    }

    /// Copies an artboard as "<name> copy", placed like a new artboard on the same page.
    @discardableResult
    public func duplicateArtboard(id: String) throws -> Artboard {
        let original = try artboard(id: id)
        let copy = newArtboard(
            named: "\(original.name) copy", page: original.page,
            width: original.width, height: original.height, x: nil, y: nil, mode: original.mode
        )
        try insert(copy, html: html(ofArtboard: id))
        return copy
    }

    // MARK: - Helpers

    private func newArtboard(
        named name: String, page: String, width: Double, height: Double, x: Double?, y: Double?, mode: String?
    ) -> Artboard {
        let id = uniqueArtboardID(for: name)
        let origin = nextOrigin(onPage: page)
        return Artboard(
            id: id, page: page, name: name, file: DocumentPath.artboard(id),
            x: x ?? origin.x, y: y ?? origin.y, width: width, height: height, mode: mode
        )
    }

    /// Sizes must be finite and positive, positions finite.
    private func validateGeometry(x: Double?, y: Double?, width: Double?, height: Double?) throws {
        for (label, size) in [("width", width), ("height", height)] {
            if let size, !(size.isFinite && size > 0) {
                throw DocumentError.invalidValue("\(label) must be a finite number greater than 0, not \(size)")
            }
        }
        for (label, coordinate) in [("x", x), ("y", y)] {
            if let coordinate, !coordinate.isFinite {
                throw DocumentError.invalidValue("\(label) must be a finite number, not \(coordinate)")
            }
        }
    }

    /// An artboard mode override must be nil or one of the token modes.
    private func validateMode(_ mode: String?) throws {
        guard let mode, !tokens.modes.contains(mode) else { return }
        throw DocumentError.invalidValue("mode \"\(mode)\" is not one of the token modes \(tokens.modes)")
    }

    private func insert(_ board: Artboard, html: String) throws {
        try files.write(html, to: board.file)
        try updateManifest { $0.artboards.append(board) }
    }

    private func uniqueArtboardID(for name: String) -> String {
        let base = Slug.make(from: name) ?? "artboard"
        let taken = Set(manifest.artboards.map(\.id))
        guard taken.contains(base) else { return base }
        return (2...).lazy.map { "\(base)-\($0)" }.first { !taken.contains($0) }!
    }

    private func nextOrigin(onPage page: String) -> (x: Double, y: Double) {
        let rightMost = artboards(onPage: page).max { $0.x + $0.width < $1.x + $1.width }
        guard let rightMost else { return (0, 0) }
        return (rightMost.x + rightMost.width + Self.artboardGap, rightMost.y)
    }
}

extension Artboard {
    /// The id is a slug and the file is `artboards/<id>.html`, so the path can't leave the package.
    var hasCanonicalFile: Bool {
        Slug.isValid(id) && file == DocumentPath.artboard(id)
    }
}

extension CanvasDocument {
    /// Remembers the artboard files on disk, so outside deletes of files never read are still reported.
    func trackArtboardFiles() {
        for board in manifest.artboards { files.track(board.file) }
    }
}

enum Slug {
    /// "Pricing Page" → "pricing-page"; nil when nothing usable is left.
    static func make(from name: String) -> String? {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = folded.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return words.isEmpty ? nil : words.joined(separator: "-")
    }

    static func isValid(_ id: String) -> Bool {
        id.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil
    }
}
