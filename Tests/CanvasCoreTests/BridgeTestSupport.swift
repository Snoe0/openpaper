import XCTest
@testable import CanvasCore

/// A `CanvasController` backed by a real document, recording what the bridge asks of the app.
@MainActor
final class MockCanvasController: CanvasController {
    var activeDocument: CanvasDocument?
    var recentDocuments: [URL] = []
    var selection = CanvasSelection()
    var console: [ConsoleEntry] = []
    var screenshotPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    /// What each board's page matches, by artboard id, then selector.
    var elements: [String: [String: PageElement]] = [:]
    /// Selectors every page rejects as malformed.
    var invalidSelectors: Set<String> = []
    /// Runs while a page is being asked for an element, e.g. to delete the board or fail.
    var whileAnswering: (() throws -> Void)?
    private(set) var focusedArtboards: [String] = []
    private(set) var screenshotRequests: [String] = []
    private(set) var elementRequests: [(artboardID: String, selector: String)] = []

    init(document: CanvasDocument? = nil) {
        activeDocument = document
    }

    func openDocument(at url: URL) throws -> CanvasDocument {
        let document = try CanvasDocument.open(at: url)
        activeDocument = document
        return document
    }

    func createDocument(at url: URL) throws -> CanvasDocument {
        let document = try CanvasDocument.create(at: url)
        activeDocument = document
        return document
    }

    func screenshot(artboardID: String) async throws -> Data {
        screenshotRequests.append(artboardID)
        return screenshotPNG
    }

    func element(onArtboard artboardID: String, matching selector: String) async throws -> PageElement? {
        elementRequests.append((artboardID, selector))
        if invalidSelectors.contains(selector) { throw PageElementError.invalidSelector }
        try whileAnswering?()
        return elements[artboardID]?[selector]
    }

    func consoleLogs(artboardID: String?) -> [ConsoleEntry] {
        console.filter { artboardID == nil || $0.artboardID == artboardID }
    }

    func focus(artboardID: String) {
        focusedArtboards.append(artboardID)
    }
}

/// Talks JSON-RPC to an `MCPHandler` the way an MCP client would.
@MainActor
final class MCPTestClient {
    let status = BridgeStatus()
    let handler: MCPHandler
    private var lastID = 0

    init(controller: any CanvasController) {
        handler = MCPHandler(controller: controller, status: status)
    }

    /// Sends a request and returns the whole response object.
    func request(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        lastID += 1
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .int(lastID), "method": .string(method)]
        message["params"] = params
        let reply = try await send(.object(message))
        let response = try XCTUnwrap(reply, "no response to \(method)")
        XCTAssertEqual(response["id"], .int(lastID))
        XCTAssertEqual(response["jsonrpc"], "2.0")
        return response
    }

    /// The `result` of a request that must succeed.
    func result(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        let response = try await request(method, params)
        XCTAssertNil(response["error"], "\(method) failed: \(response)")
        return try XCTUnwrap(response["result"])
    }

    /// The error code of a request that must fail at the JSON-RPC level.
    func errorCode(_ method: String, _ params: JSONValue? = nil) async throws -> Int? {
        try await request(method, params)["error"]?["code"]?.int
    }

    func callTool(_ name: String, _ arguments: JSONValue = [:]) async throws -> ToolReply {
        let result = try await result("tools/call", ["name": .string(name), "arguments": arguments])
        return ToolReply(
            isError: result["isError"]?.bool ?? false,
            content: try XCTUnwrap(result["content"]?.array, "no content in \(result)")
        )
    }

    /// Calls a tool that must succeed and returns its text.
    func text(_ name: String, _ arguments: JSONValue = [:], file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let reply = try await callTool(name, arguments)
        XCTAssertFalse(reply.isError, "\(name) failed: \(reply.text)", file: file, line: line)
        return reply.text
    }

    /// Calls a tool that must succeed and decodes its JSON text.
    func json(_ name: String, _ arguments: JSONValue = [:], file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let text = try await text(name, arguments, file: file, line: line)
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Calls a tool that must fail and returns its error text.
    func failure(_ name: String, _ arguments: JSONValue = [:], file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let reply = try await callTool(name, arguments)
        XCTAssertTrue(reply.isError, "\(name) should have failed: \(reply.text)", file: file, line: line)
        return reply.text
    }

    func send(_ message: JSONValue) async throws -> JSONValue? {
        try await send(raw: JSONEncoder().encode(message))
    }

    func send(raw: Data) async throws -> JSONValue? {
        guard let data = await handler.handle(raw) else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

struct ToolReply {
    let isError: Bool
    let content: [JSONValue]

    var text: String {
        content.compactMap { $0["text"]?.string }.joined()
    }
}
