import Foundation

extension BridgeTools {
    static let defaultConsoleLimit = 50

    static let appTools: [BridgeTool] = [
        BridgeTool(
            name: "get_selection",
            description: "What the user has selected in Canvas: artboard ids, and the element picked in inspect mode.",
            inputSchema: Schema.object(),
            run: { call in try .json(call.controller.selection) }
        ),
        BridgeTool(
            name: "screenshot",
            description: "A PNG image of an artboard as Canvas currently renders it, one pixel per CSS pixel; a board over "
                + "\(Int(SnapshotSize.maxPixels / 1_048_576))M pixels comes back scaled down, keeping its aspect ratio.",
            inputSchema: Schema.object(["id": Schema.artboardID], required: ["id"]),
            run: { call in try await .png(call.controller.screenshot(artboardID: call.artboard().id)) }
        ),
        BridgeTool(
            name: "get_element",
            description: "Resolve a pointer the user copied from Canvas: for canvas:<artboard id> > <CSS selector>, the first "
                + "matching element's HTML (at most 20000 characters; \"truncated\" when cut), how many elements match, its box "
                + "(CSS pixels relative to the page's viewport, i.e. the board's top-left while unscrolled) and key computed "
                + "styles; for canvas:<artboard id>, the artboard.",
            inputSchema: Schema.object(
                ["pointer": Schema.string("The pointer as pasted, e.g. \"canvas:hero > section.pricing > a.cta\".")],
                required: ["pointer"]
            ),
            run: { call in try await resolve(CanvasPointer(parsing: call.string("pointer")), call) }
        ),
        BridgeTool(
            name: "get_console",
            description: "Recent console messages and errors from the artboards' pages, oldest first.",
            inputSchema: Schema.object([
                "id": Schema.string("Only this artboard's messages. Omit for all artboards."),
                "limit": Schema.integer("Most recent messages to return (default \(defaultConsoleLimit))."),
            ]),
            run: { call in
                _ = try call.document()
                let artboardID = try call.optionalArtboard()?.id
                let limit = try call.optionalInteger("limit") ?? defaultConsoleLimit
                return .text(consoleText(call.controller.consoleLogs(artboardID: artboardID).suffix(max(limit, 0))))
            }
        ),
        BridgeTool(
            name: "focus_artboard",
            description: "Scroll and zoom Canvas to show an artboard to the user.",
            inputSchema: Schema.object(["id": Schema.artboardID], required: ["id"]),
            run: { call in
                let id = try call.artboard().id
                call.controller.focus(artboardID: id)
                return .text("Focused artboard \(id).")
            }
        ),
    ]

    /// The artboard or element `pointer` names; a pointer whose target is gone fails, saying why.
    private static func resolve(_ pointer: CanvasPointer, _ call: ToolCall) async throws -> ToolResult {
        let document = try call.document()
        guard let board = try? document.artboard(id: pointer.boardID) else {
            throw ToolError(stale(pointer, "there is no artboard \"\(pointer.boardID)\" in the open document"))
        }
        guard case .element(_, let selector) = pointer else { return try .json(board) }
        guard let element = try await element(matching: selector, on: board, call) else {
            throw ToolError(stale(pointer, "no element on artboard \"\(board.id)\" matches \(selector)"))
        }
        return try .json(ElementReport(pointer: pointer.description, board: .init(id: board.id, name: board.name), element: element))
    }

    private static func element(matching selector: String, on board: Artboard, _ call: ToolCall) async throws -> PageElement? {
        do {
            return try await call.controller.element(onArtboard: board.id, matching: selector)
        } catch PageElementError.invalidSelector {
            throw ToolError("\(selector) isn't a valid CSS selector.")
        }
    }

    private static func stale(_ pointer: CanvasPointer, _ reason: String) -> String {
        "The pointer \(pointer) is stale: \(reason). Ask the user to copy it again, or look it up with read_artboard."
    }

    /// One `<time> [level] artboard: message` line per entry.
    private static func consoleText(_ entries: some Collection<ConsoleEntry>) -> String {
        guard !entries.isEmpty else { return "No console messages." }
        let time = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return entries
            .map { "\($0.timestamp.formatted(time)) [\($0.level)] \($0.artboardID): \($0.message)" }
            .joined(separator: "\n")
    }
}

/// What `get_element` returns for an element pointer.
private struct ElementReport: Encodable {
    struct Board: Encodable {
        let id: String
        let name: String
    }

    let pointer: String
    let board: Board
    let selector: String
    let outerHTML: String
    let box: ElementRect
    let styles: [String: String]
    let matches: Int?
    let truncated: Bool?

    init(pointer: String, board: Board, element: PageElement) {
        self.pointer = pointer
        self.board = board
        selector = element.selector
        outerHTML = element.outerHTML
        box = element.box
        styles = element.styles
        matches = element.matches
        truncated = element.truncated
    }
}
