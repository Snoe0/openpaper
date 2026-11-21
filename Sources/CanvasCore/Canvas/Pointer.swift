import Foundation

/// A short, pasteable reference to something in the open document, which the user copies from the
/// canvas and an agent resolves with `get_element`:
///
/// - `canvas:<artboard id>`: an artboard.
/// - `canvas:<artboard id> > <selector>`: the element the CSS selector matches on that artboard's page.
///
/// Artboard ids are slugs (lowercase letters, digits and dashes), so the first `>` always ends the id and
/// everything after it is the selector, whatever it contains. Other kinds of target are meant to read
/// `canvas:<kind>/<id>` (e.g. `canvas:note/<id>`): slugs never contain a `/`, so they can't collide with an
/// artboard that happens to be called "note". This build knows no such kinds and rejects them.
public enum CanvasPointer: Equatable, Sendable, CustomStringConvertible {
    case board(String)
    case element(board: String, selector: String)

    static let scheme = "canvas:"
    static let selectorSeparator: Character = ">"
    static let kindSeparator: Character = "/"

    public init(parsing text: String) throws(PointerError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.scheme) else { throw .notAPointer(trimmed) }
        let rest = trimmed.dropFirst(Self.scheme.count)
        let (target, selector) = Self.split(rest)
        let boardID = try Self.boardID(from: target)
        guard let selector else {
            self = .board(boardID)
            return
        }
        guard !selector.isEmpty else { throw .emptySelector }
        self = .element(board: boardID, selector: selector)
    }

    public var boardID: String {
        switch self {
        case .board(let id), .element(let id, _): id
        }
    }

    public var description: String {
        switch self {
        case .board(let id): "\(Self.scheme)\(id)"
        case .element(let id, let selector): "\(Self.scheme)\(id) \(Self.selectorSeparator) \(selector)"
        }
    }

    /// The target before the first `>`, and the selector after it (nil without a `>`), both trimmed.
    private static func split(_ rest: Substring) -> (target: String, selector: String?) {
        let parts = rest.split(separator: selectorSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        let trim = { (part: Substring) in part.trimmingCharacters(in: .whitespaces) }
        return (trim(parts[0]), parts.count > 1 ? trim(parts[1]) : nil)
    }

    /// `target` as an artboard id; a `kind/id` target names a kind this build doesn't know.
    private static func boardID(from target: String) throws(PointerError) -> String {
        if let slash = target.firstIndex(of: kindSeparator) { throw .unknownKind(String(target[..<slash])) }
        guard Slug.isValid(target) else { throw .invalidBoardID(target) }
        return target
    }
}

public enum PointerError: Error, Equatable {
    case notAPointer(String)
    case invalidBoardID(String)
    case unknownKind(String)
    case emptySelector
}

extension PointerError: LocalizedError {
    private static let format = "Pointers look like canvas:<artboard id> or canvas:<artboard id> > <CSS selector>."

    public var errorDescription: String? {
        switch self {
        case .notAPointer(let text): "\"\(text)\" isn't a Canvas pointer. \(Self.format)"
        case .invalidBoardID(let id): "\"\(id)\" isn't an artboard id (lowercase letters, digits and dashes). \(Self.format)"
        case .unknownKind(let kind): "This version of Canvas doesn't know \"\(kind)/\" pointers. \(Self.format)"
        case .emptySelector: "The pointer has a \">\" but no selector after it. \(Self.format)"
        }
    }
}
