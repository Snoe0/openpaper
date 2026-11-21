import Foundation

/// Answers MCP messages (JSON-RPC 2.0): the handshake, ping, and listing and calling the Canvas tools.
@MainActor
final class MCPHandler {
    static let latestProtocolVersion = "2025-06-18"
    static let supportedProtocolVersions: Set = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
    Canvas is a macOS design app. A document is a `Name.canvas` folder of HTML artboards laid out on an infinite canvas \
    and rendered live. Use these tools to read and change the open document; open or create one first if none is open. \
    Tools that take `page` accept a page id or name and default to the current page. You can also edit the document's \
    files directly: get_document returns its path. After a visual change, take a screenshot to check the result.

    Pointers: the user can right-click anything on the canvas, copy a pointer to it and paste it in the chat. \
    `canvas:<artboard id>` names an artboard; `canvas:<artboard id> > <CSS selector>` names an element on that \
    artboard's page. Resolve a pointer with get_element (HTML, box and computed styles, or the artboard), then edit \
    the artboard's HTML. A stale pointer (its artboard was deleted, or nothing matches the selector any more) says why. \
    Selectors are positional (nth-of-type), so an edit that inserts siblings can make one point elsewhere: pointers are \
    for short-term use, so check the returned HTML is what the user meant.

    """ + DocumentGuide.markdown

    private let controller: any CanvasController
    private let status: BridgeStatus

    init(controller: any CanvasController, status: BridgeStatus) {
        self.controller = controller
        self.status = status
    }

    /// The response to one message, or nil when none is due (notifications and client responses).
    func handle(_ body: Data) async -> Data? {
        do throws(JSONRPCRejection) {
            switch try JSONRPCMessage(decoding: body) {
            case .request(let id, let method, let params):
                return await response(to: method, params: params, id: id).encoded()
            case .notification, .response:
                return nil
            }
        } catch {
            return JSONRPCMessage.error(error.error, id: error.id).encoded()
        }
    }

    private func response(to method: String, params: JSONValue, id: JSONValue) async -> JSONValue {
        do {
            return JSONRPCMessage.result(try await result(of: method, params: params), id: id)
        } catch let error as JSONRPCError {
            return JSONRPCMessage.error(error, id: id)
        } catch {
            return JSONRPCMessage.error(JSONRPCError(code: -32603, message: error.localizedDescription), id: id)
        }
    }

    private func result(of method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize": return initialize(params)
        case "ping": return [:]
        case "tools/list": return ["tools": .array(BridgeTools.all.map(\.definition))]
        case "tools/call": return try await callTool(params)
        default: throw JSONRPCError.methodNotFound(method)
        }
    }

    // MARK: - Methods

    private func initialize(_ params: JSONValue) -> JSONValue {
        recordClient(params["clientInfo"])
        return [
            "protocolVersion": .string(negotiatedVersion(params["protocolVersion"]?.string)),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "canvas", "title": "Canvas", "version": .string(CanvasCore.version)],
            "instructions": .string(Self.instructions),
        ]
    }

    /// The client's version when we support it, otherwise our latest (the client then decides whether to continue).
    private func negotiatedVersion(_ requested: String?) -> String {
        guard let requested, Self.supportedProtocolVersions.contains(requested) else { return Self.latestProtocolVersion }
        return requested
    }

    private func recordClient(_ info: JSONValue?) {
        status.client = BridgeClientInfo(
            name: info?["name"]?.string ?? "unknown client",
            version: info?["version"]?.string ?? ""
        )
    }

    private func callTool(_ params: JSONValue) async throws -> JSONValue {
        guard let name = params["name"]?.string else { throw JSONRPCError.invalidParams("tools/call needs a tool \"name\"") }
        guard let tool = BridgeTools.named(name) else { throw JSONRPCError.invalidParams("unknown tool \"\(name)\"") }
        guard let arguments = (params["arguments"] ?? [:]).object else {
            throw JSONRPCError.invalidParams("tool \"arguments\" must be an object")
        }
        let result = await run(tool, arguments: arguments)
        recordCall(name, result)
        return result.json
    }

    /// Runs a tool, turning any failure into an error result the agent can read and act on.
    private func run(_ tool: BridgeTool, arguments: [String: JSONValue]) async -> ToolResult {
        do {
            return try await tool.run(ToolCall(arguments: arguments, controller: controller))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func recordCall(_ name: String, _ result: ToolResult) {
        status.lastCall = ToolCallRecord(
            name: name, date: Date(), succeeded: !result.isError,
            errorMessage: result.isError ? result.text : nil
        )
    }
}
