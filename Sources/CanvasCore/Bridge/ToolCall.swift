import Foundation

/// One tool invocation: its arguments, typed accessors for them, and the app state tools share.
@MainActor
struct ToolCall {
    let arguments: [String: JSONValue]
    let controller: any CanvasController

    // MARK: - Document and page

    /// The active document; fails with a hint when none is open.
    func document() throws -> CanvasDocument {
        guard let document = controller.activeDocument else { throw ToolError(noDocumentMessage()) }
        return document
    }

    /// The page named by the optional `page` argument (an id or a name), or the current page.
    func page(in document: CanvasDocument) throws -> Page {
        guard let reference = try optionalString("page") else { return document.currentPage }
        return try Self.findPage(reference, in: document)
    }

    /// The page named by the required `page` argument.
    func requiredPage(in document: CanvasDocument) throws -> Page {
        try Self.findPage(string("page"), in: document)
    }

    /// The artboard named by the `id` argument, which must exist in the active document.
    func artboard() throws -> Artboard {
        try document().artboard(id: string("id"))
    }

    /// The artboard named by the `id` argument if one is given.
    func optionalArtboard() throws -> Artboard? {
        try optionalString("id") == nil ? nil : artboard()
    }

    private static func findPage(_ reference: String, in document: CanvasDocument) throws -> Page {
        let pages = document.manifest.pages
        if let page = pages.first(where: { $0.id == reference })
            ?? pages.first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame }) {
            return page
        }
        let known = pages.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
        throw ToolError("No page \"\(reference)\". Pages: \(known).")
    }

    private func noDocumentMessage() -> String {
        var message = "No document is open in Canvas. Use open_document or create_document first."
        let recent = controller.recentDocuments.map(\.path)
        if !recent.isEmpty { message += " Recent documents:\n" + recent.joined(separator: "\n") }
        return message
    }

    // MARK: - Arguments

    func string(_ key: String) throws -> String {
        try required(key, optionalString(key))
    }

    func optionalString(_ key: String) throws -> String? {
        try optional(key, as: "a string") { $0.string }
    }

    /// Absent → nil, JSON null → `.some(nil)`, a string → that string.
    func nullableString(_ key: String) throws -> String?? {
        guard let value = arguments[key] else { return nil }
        return value == .null ? .some(nil) : .some(try optionalString(key))
    }

    func number(_ key: String) throws -> Double {
        try required(key, optionalNumber(key))
    }

    func optionalNumber(_ key: String) throws -> Double? {
        try optional(key, as: "a number") { $0.number }
    }

    func optionalInteger(_ key: String) throws -> Int? {
        try optional(key, as: "an integer") { $0.int }
    }

    func optionalStrings(_ key: String) throws -> [String]? {
        try optional(key, as: "an array of strings") { value in
            value.array.flatMap { items in
                let strings = items.compactMap(\.string)
                return strings.count == items.count ? strings : nil
            }
        }
    }

    func optionalObject(_ key: String) throws -> [String: JSONValue]? {
        try optional(key, as: "an object") { $0.object }
    }

    /// An absolute file path from the `path` argument; `~` is expanded.
    func absolutePath() throws -> URL {
        let path = (try string("path") as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw ToolError("\"path\" must be an absolute path, not \"\(path)\".") }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func optional<Value>(_ key: String, as kind: String, _ extract: (JSONValue) -> Value?) throws -> Value? {
        guard let value = arguments[key], value != .null else { return nil }
        guard let typed = extract(value) else { throw ToolError("\"\(key)\" must be \(kind).") }
        return typed
    }

    private func required<Value>(_ key: String, _ value: Value?) throws -> Value {
        guard let value else { throw ToolError("Missing required argument \"\(key)\".") }
        return value
    }
}
