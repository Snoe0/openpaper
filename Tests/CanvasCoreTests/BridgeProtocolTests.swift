import XCTest
@testable import CanvasCore

final class BridgeProtocolTests: XCTestCase {
    static let toolNames: Set<String> = [
        "get_document", "open_document", "create_document",
        "list_pages", "create_page", "switch_page",
        "create_artboard", "read_artboard", "write_artboard", "edit_artboard", "update_artboard",
        "delete_artboard", "duplicate_artboard",
        "get_selection", "screenshot", "get_element", "get_console", "focus_artboard",
        "list_components", "read_component", "write_component", "delete_component",
        "get_tokens", "set_tokens", "set_mode",
    ]

    @MainActor
    func testInitializeDescribesTheServerAndRecordsTheClient() async throws {
        let client = MCPTestClient(controller: MockCanvasController())

        let result = try await client.result("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "claude-code", "version": "2.1.0"],
        ])

        XCTAssertEqual(result["protocolVersion"], "2025-06-18")
        XCTAssertEqual(result["serverInfo"]?["name"], "canvas")
        XCTAssertEqual(result["serverInfo"]?["version"]?.string, CanvasCore.version)
        XCTAssertNotNil(result["capabilities"]?["tools"]?.object)
        let instructions = try XCTUnwrap(result["instructions"]?.string)
        XCTAssertTrue(instructions.contains("artboards/<id>.html"), instructions)
        XCTAssertEqual(client.status.client, BridgeClientInfo(name: "claude-code", version: "2.1.0"))
    }

    @MainActor
    func testInitializeEchoesOlderSupportedVersionsAndOffersTheLatestOtherwise() async throws {
        let client = MCPTestClient(controller: MockCanvasController())

        for (requested, expected) in [("2025-03-26", "2025-03-26"), ("2024-11-05", "2024-11-05"), ("1999-01-01", "2025-06-18")] {
            let result = try await client.result("initialize", [
                "protocolVersion": .string(requested), "capabilities": [:], "clientInfo": ["name": "x", "version": "1"],
            ])
            XCTAssertEqual(result["protocolVersion"]?.string, expected, requested)
        }
    }

    @MainActor
    func testNotificationsAndClientResponsesGetNoResponse() async throws {
        let client = MCPTestClient(controller: MockCanvasController())

        let initialized = try await client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let cancelled = try await client.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 3]])
        let clientResponse = try await client.send(["jsonrpc": "2.0", "id": 9, "result": [:]])

        XCTAssertNil(initialized)
        XCTAssertNil(cancelled)
        XCTAssertNil(clientResponse)
    }

    @MainActor
    func testPingAnswersWithAnEmptyResultAndEchoesStringIDs() async throws {
        let client = MCPTestClient(controller: MockCanvasController())

        let response = try await client.send(["jsonrpc": "2.0", "id": "abc", "method": "ping"])

        XCTAssertEqual(response?["id"], "abc")
        XCTAssertEqual(response?["result"], [:])
    }

    @MainActor
    func testUnknownMethodIsMethodNotFound() async throws {
        let client = MCPTestClient(controller: MockCanvasController())

        let code = try await client.errorCode("resources/list")

        XCTAssertEqual(code, -32601)
    }

    @MainActor
    func testMalformedMessagesAreParseOrInvalidRequestErrors() async throws {
        let client = MCPTestClient(controller: MockCanvasController())

        let garbage = try await client.send(raw: Data("{not json".utf8))
        let notAnObject = try await client.send(raw: Data("[1, 2]".utf8))

        XCTAssertEqual(garbage?["error"]?["code"]?.int, -32700)
        XCTAssertEqual(garbage?["id"], .null)
        XCTAssertEqual(notAnObject?["error"]?["code"]?.int, -32600)
    }

    @MainActor
    func testRejectsMessagesThatAreNotJSONRPC2AndEchoesValidIDs() async throws {
        let client = MCPTestClient(controller: MockCanvasController())

        let noVersion = try await client.send(["id": 5, "method": "ping"])
        let wrongVersion = try await client.send(["jsonrpc": "1.0", "id": "x", "method": "ping"])
        XCTAssertEqual(noVersion?["error"]?["code"]?.int, -32600)
        XCTAssertEqual(noVersion?["id"], 5)
        XCTAssertEqual(wrongVersion?["error"]?["code"]?.int, -32600)
        XCTAssertEqual(wrongVersion?["id"], "x")

        for badID: JSONValue in [["a": 1], [1], true, 1.5] {
            let response = try await client.send(["jsonrpc": "2.0", "id": badID, "method": "ping"])
            XCTAssertEqual(response?["error"]?["code"]?.int, -32600, "\(badID)")
            XCTAssertEqual(response?["id"], .null, "\(badID)")
        }
    }

    @MainActor
    func testToolsListDescribesEveryToolWithASchema() async throws {
        let client = MCPTestClient(controller: MockCanvasController())

        let result = try await client.result("tools/list")
        let tools = try XCTUnwrap(result["tools"]?.array)

        XCTAssertEqual(Set(tools.compactMap { $0["name"]?.string }), Self.toolNames)
        XCTAssertEqual(tools.count, Self.toolNames.count)
        for tool in tools {
            let name = tool["name"]?.string ?? "?"
            XCTAssertFalse((tool["description"]?.string ?? "").isEmpty, name)
            XCTAssertEqual(tool["inputSchema"]?["type"], "object", name)
            XCTAssertNotNil(tool["inputSchema"]?["properties"]?.object, name)
        }
    }

    @MainActor
    func testToolsCallWithBadParamsIsInvalidParams() async throws {
        let client = MCPTestClient(controller: MockCanvasController())

        let missingName = try await client.errorCode("tools/call", ["arguments": [:]])
        let unknownTool = try await client.errorCode("tools/call", ["name": "explode", "arguments": [:]])
        let badArguments = try await client.errorCode("tools/call", ["name": "get_document", "arguments": "nope"])

        XCTAssertEqual(missingName, -32602)
        XCTAssertEqual(unknownTool, -32602)
        XCTAssertEqual(badArguments, -32602)
    }
}
