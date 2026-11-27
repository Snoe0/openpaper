import Foundation

extension BridgeTools {
    static let componentTools: [BridgeTool] = [
        BridgeTool(
            name: "list_components",
            description: "List the document's components with their tags and props.",
            inputSchema: Schema.object(),
            run: { call in try .json(componentSummaries(of: call.document())) }
        ),
        BridgeTool(
            name: "read_component",
            description: "Read a component's template HTML.",
            inputSchema: Schema.object(["name": Schema.componentName], required: ["name"]),
            run: { call in try .text(call.document().componentHTML(name: call.string("name"))) }
        ),
        BridgeTool(
            name: "write_component",
            description: "Create or replace a component template; every artboard using <x-name> updates.",
            inputSchema: Schema.object([
                "name": Schema.componentName,
                "html": Schema.string("Template HTML with optional <style>, {{prop}} or {{prop|default}} placeholders, and <slot> elements."),
            ], required: ["name", "html"]),
            run: { call in
                let name = try call.string("name")
                try call.document().writeComponent(name: name, html: call.string("html"))
                return .text("Wrote component <x-\(name)>.")
            }
        ),
        BridgeTool(
            name: "delete_component",
            description: "Delete a component template.",
            inputSchema: Schema.object(["name": Schema.componentName], required: ["name"]),
            run: { call in
                let name = try call.string("name")
                try call.document().deleteComponent(name: name)
                return .text("Deleted component <x-\(name)>.")
            }
        ),
    ]

    static let tokenTools: [BridgeTool] = [
        BridgeTool(
            name: "get_tokens",
            description: "The design tokens, their modes and the document's current mode.",
            inputSchema: Schema.object(),
            run: { call in try .json(TokenSummary(call.document())) }
        ),
        BridgeTool(
            name: "set_tokens",
            description: "Add or replace tokens, replace the mode list, and/or remove tokens; other tokens are kept.",
            inputSchema: Schema.object([
                "tokens": [
                    "type": "object",
                    "description": "Token name → value: a string for every mode, or an object of mode → string, e.g. {\"color.bg\": {\"light\": \"#fff\", \"dark\": \"#000\"}}.",
                    "additionalProperties": ["type": ["string", "object"]],
                ],
                "modes": Schema.strings("The complete list of token modes, e.g. [\"light\", \"dark\"]: unique names of letters, digits, _ and -. Applied before tokens."),
                "remove": Schema.strings("Token names to remove."),
            ]),
            run: { call in
                let document = try call.document()
                let modes = try call.optionalStrings("modes")
                let values = try call.optionalObject("tokens").map(tokenValues)
                let removals = try call.optionalStrings("remove")
                guard modes != nil || values != nil || removals != nil else {
                    throw ToolError("Pass at least one of \"tokens\", \"modes\" or \"remove\".")
                }
                if let modes { try document.setModes(modes) }
                if let values { try document.setTokens(values) }
                for name in removals ?? [] { try document.removeToken(name) }
                return try .json(TokenSummary(document))
            }
        ),
        BridgeTool(
            name: "set_mode",
            description: "Switch the document's token mode, e.g. \"dark\"; artboards with their own mode keep it.",
            inputSchema: Schema.object(["mode": Schema.string("One of the token modes.")], required: ["mode"]),
            run: { call in
                let mode = try call.string("mode")
                try call.document().setMode(mode)
                return .text("The document mode is now \"\(mode)\".")
            }
        ),
    ]

    private static func componentSummaries(of document: CanvasDocument) throws -> [ComponentSummary] {
        try document.componentNames.map { name in
            ComponentSummary(name: name, tag: "x-\(name)", props: try document.props(ofComponent: name).map {
                ComponentSummary.Prop(name: $0.name, default: $0.defaultValue)
            })
        }
    }

    /// Token values from JSON: each a string, or an object of mode → string.
    private static func tokenValues(_ json: [String: JSONValue]) throws -> [String: TokenValue] {
        var values: [String: TokenValue] = [:]
        for (name, value) in json { values[name] = try tokenValue(value, named: name) }
        return values
    }

    private static func tokenValue(_ value: JSONValue, named name: String) throws -> TokenValue {
        if let single = value.string { return .single(single) }
        if let object = value.object, case let perMode = object.compactMapValues(\.string), perMode.count == object.count {
            return .perMode(perMode)
        }
        throw ToolError("Token \"\(name)\" must be a string or an object of mode → string.")
    }
}

private struct ComponentSummary: Encodable {
    struct Prop: Encodable {
        let name: String
        let `default`: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(`default`, forKey: .default)
        }

        private enum CodingKeys: String, CodingKey {
            case name, `default`
        }
    }

    let name: String
    let tag: String
    let props: [Prop]
}

private struct TokenSummary: Encodable {
    let mode: String
    let modes: [String]
    let tokens: [String: TokenValue]

    @MainActor
    init(_ document: CanvasDocument) {
        mode = document.manifest.mode
        modes = document.tokens.modes
        tokens = document.tokens.tokens
    }
}
