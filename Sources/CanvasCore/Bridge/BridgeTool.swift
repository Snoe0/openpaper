import Foundation

/// An MCP tool: what `tools/list` shows, and what `tools/call` runs.
struct BridgeTool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    let run: @MainActor @Sendable (ToolCall) async throws -> ToolResult

    var definition: JSONValue {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema]
    }
}

/// Every Canvas tool, in the order `tools/list` shows them.
@MainActor
enum BridgeTools {
    static let all: [BridgeTool] = documentTools + pageTools + artboardTools + appTools + componentTools + tokenTools

    static func named(_ name: String) -> BridgeTool? {
        all.first { $0.name == name }
    }
}

/// The content of a `tools/call` result.
struct ToolResult {
    var content: [JSONValue]
    var isError = false

    var json: JSONValue {
        ["content": .array(content), "isError": .bool(isError)]
    }

    var text: String {
        content.compactMap { $0["text"]?.string }.joined()
    }

    static func text(_ text: String) -> ToolResult {
        ToolResult(content: [["type": "text", "text": .string(text)]])
    }

    /// Pretty-printed JSON text.
    static func json(_ value: some Encodable) throws -> ToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return .text(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func png(_ data: Data) -> ToolResult {
        ToolResult(content: [["type": "image", "data": .string(data.base64EncodedString()), "mimeType": "image/png"]])
    }

    static func failure(_ message: String) -> ToolResult {
        ToolResult(content: [["type": "text", "text": .string(message)]], isError: true)
    }
}

/// A tool failure whose message is shown to the agent as is.
struct ToolError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Builders for the JSON Schemas of tool inputs.
enum Schema {
    static func object(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string))]
    }

    static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    static func number(_ description: String) -> JSONValue {
        ["type": "number", "description": .string(description)]
    }

    static func integer(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description)]
    }

    static func strings(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    static let page = string("Page id or name. Defaults to the current page.")
    static let artboardID = string("Artboard id, as listed by get_document.")
    static let componentName = string("Component name: lowercase letters, digits and dashes, e.g. \"pricing-card\" for <x-pricing-card>.")
    static let html = string("HTML body fragment (no <html>, <head> or <body>); may include its own <style> and <script>.")
}
