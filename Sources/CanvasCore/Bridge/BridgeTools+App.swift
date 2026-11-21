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
            description: "A PNG image of an artboard as Canvas currently renders it.",
            inputSchema: Schema.object(["id": Schema.artboardID], required: ["id"]),
            run: { call in try await .png(call.controller.screenshot(artboardID: call.artboard().id)) }
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

    /// One `<time> [level] artboard: message` line per entry.
    private static func consoleText(_ entries: some Collection<ConsoleEntry>) -> String {
        guard !entries.isEmpty else { return "No console messages." }
        let time = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return entries
            .map { "\($0.timestamp.formatted(time)) [\($0.level)] \($0.artboardID): \($0.message)" }
            .joined(separator: "\n")
    }
}
