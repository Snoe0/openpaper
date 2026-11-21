import XCTest
@testable import CanvasCore

final class BridgeToolTests: XCTestCase {
    @MainActor
    func testScriptedArtboardSession() async throws {
        let document = try makeDocument()
        let client = MCPTestClient(controller: MockCanvasController(document: document))
        _ = try await client.result("initialize", [
            "protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2"],
        ])
        _ = try await client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        _ = try await client.result("tools/list")

        let hero = try await client.json("create_artboard", ["name": "Hero", "width": 400, "height": 300, "html": "<h1>Hi</h1>"])
        let pricing = try await client.json("create_artboard", ["name": "Pricing", "width": 200, "height": 100])
        XCTAssertEqual(hero["id"], "hero")
        XCTAssertEqual(hero["x"]?.number, 0)
        XCTAssertEqual(pricing["id"], "pricing")
        XCTAssertEqual(pricing["x"]?.number, 480, "placed right of the right-most board with a gap")
        XCTAssertEqual(pricing["y"]?.number, 0)

        let html = try await client.text("read_artboard", ["id": "hero"])
        XCTAssertEqual(html, "<h1>Hi</h1>")

        _ = try await client.text("edit_artboard", ["id": "hero", "old_string": "Hi", "new_string": "Hello"])
        XCTAssertEqual(try document.html(ofArtboard: "hero"), "<h1>Hello</h1>")

        _ = try await client.text("write_artboard", ["id": "pricing", "html": "<p>$9</p>"])
        XCTAssertEqual(try document.html(ofArtboard: "pricing"), "<p>$9</p>")

        let updated = try await client.json("update_artboard", ["id": "hero", "name": "Landing", "x": -50, "width": 640, "mode": "dark"])
        XCTAssertEqual(updated["name"], "Landing")
        XCTAssertEqual(updated["mode"], "dark")
        XCTAssertEqual(try document.artboard(id: "hero").x, -50)
        XCTAssertEqual(try document.artboard(id: "hero").width, 640)
        _ = try await client.json("update_artboard", ["id": "hero", "mode": .null])
        XCTAssertNil(try document.artboard(id: "hero").mode)

        let copy = try await client.json("duplicate_artboard", ["id": "pricing"])
        XCTAssertEqual(copy["id"], "pricing-copy")
        XCTAssertEqual(try document.html(ofArtboard: "pricing-copy"), "<p>$9</p>")

        _ = try await client.text("delete_artboard", ["id": "pricing"])
        XCTAssertEqual(document.artboards().map(\.id), ["hero", "pricing-copy"])

        let overview = try await client.json("get_document")
        XCTAssertEqual(overview["name"], "Test")
        XCTAssertEqual(overview["path"]?.string, document.url.path)
        XCTAssertEqual(overview["currentPage"], "p1")
        XCTAssertEqual(overview["pages"]?[0]?["artboards"]?.array?.compactMap { $0["id"]?.string }, ["hero", "pricing-copy"])
    }

    @MainActor
    func testPageToolsAndThePageArgument() async throws {
        let document = try makeDocument()
        let client = MCPTestClient(controller: MockCanvasController(document: document))

        let mobile = try await client.json("create_page", ["name": "Mobile"])
        let mobileID = try XCTUnwrap(mobile["id"]?.string)
        let board = try await client.json("create_artboard", ["name": "Phone", "width": 390, "height": 844, "page": "Mobile"])
        XCTAssertEqual(board["page"]?.string, mobileID)
        XCTAssertEqual(document.currentPage.id, "p1", "creating on another page doesn't switch to it")

        let pages = try await client.json("list_pages")
        XCTAssertEqual(pages.array?.count, 2)
        XCTAssertEqual(pages[0]?["current"], true)
        XCTAssertEqual(pages[1]?["name"], "Mobile")
        XCTAssertEqual(pages[1]?["artboards"], 1)

        _ = try await client.text("switch_page", ["page": "mobile"])
        XCTAssertEqual(document.currentPage.id, mobileID)

        let second = try await client.json("create_artboard", ["name": "Tablet", "width": 800, "height": 600])
        XCTAssertEqual(second["page"]?.string, mobileID, "defaults to the current page")
        XCTAssertEqual(second["x"]?.number, 470)

        let unknown = try await client.failure("create_artboard", ["name": "X", "width": 1, "height": 1, "page": "Nowhere"])
        XCTAssertTrue(unknown.contains("No page \"Nowhere\""), unknown)
        XCTAssertTrue(unknown.contains("Mobile"), unknown)
    }

    @MainActor
    func testComponentTools() async throws {
        let document = try makeDocument()
        let client = MCPTestClient(controller: MockCanvasController(document: document))

        _ = try await client.text("write_component", ["name": "button", "html": "<button>{{label|Buy}} {{tone}}<slot></slot></button>"])
        XCTAssertEqual(document.componentNames, ["button"])

        let list = try await client.json("list_components")
        XCTAssertEqual(list, [[
            "name": "button", "tag": "x-button",
            "props": [["name": "label", "default": "Buy"], ["name": "tone", "default": .null]],
        ]])

        let html = try await client.text("read_component", ["name": "button"])
        XCTAssertEqual(html, "<button>{{label|Buy}} {{tone}}<slot></slot></button>")

        _ = try await client.text("delete_component", ["name": "button"])
        XCTAssertEqual(document.componentNames, [])
        let missing = try await client.failure("read_component", ["name": "button"])
        XCTAssertTrue(missing.contains("Not found"), missing)
        let invalid = try await client.failure("write_component", ["name": "Bad Name", "html": "x"])
        XCTAssertTrue(invalid.contains("Invalid name"), invalid)
    }

    @MainActor
    func testTokenAndModeTools() async throws {
        let document = try makeDocument()
        let client = MCPTestClient(controller: MockCanvasController(document: document))

        let initial = try await client.json("get_tokens")
        XCTAssertEqual(initial["modes"], ["light", "dark"])
        XCTAssertEqual(initial["mode"], "light")
        XCTAssertEqual(initial["tokens"]?["radius.md"], "8px")
        XCTAssertEqual(initial["tokens"]?["color.bg"]?["dark"], "#0b0b0c")

        let after = try await client.json("set_tokens", [
            "modes": ["light", "dark", "sepia"],
            "tokens": ["color.brand": ["light": "#f00", "sepia": "#a52"], "space.8": "32px"],
            "remove": ["radius.md"],
        ])
        XCTAssertEqual(document.tokens.modes, ["light", "dark", "sepia"])
        XCTAssertEqual(document.tokens.tokens["color.brand"], .perMode(["light": "#f00", "sepia": "#a52"]))
        XCTAssertEqual(document.tokens.tokens["space.8"], .single("32px"))
        XCTAssertNil(document.tokens.tokens["radius.md"])
        XCTAssertEqual(after["tokens"]?["space.8"], "32px")

        _ = try await client.text("set_mode", ["mode": "sepia"])
        XCTAssertEqual(document.manifest.mode, "sepia")

        let badMode = try await client.failure("set_mode", ["mode": "neon"])
        XCTAssertTrue(badMode.contains("neon"), badMode)
        let badValue = try await client.failure("set_tokens", ["tokens": ["color.x": "red;}"]])
        XCTAssertTrue(badValue.contains("color.x"), badValue)
        let badShape = try await client.failure("set_tokens", ["tokens": ["color.x": 3]])
        XCTAssertTrue(badShape.contains("color.x"), badShape)
        let nothing = try await client.failure("set_tokens", [:])
        XCTAssertTrue(nothing.contains("tokens"), nothing)
    }

    @MainActor
    func testSelectionScreenshotConsoleAndFocus() async throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 400, height: 300, html: "<h1>Hi</h1>")
        try document.addArtboard(name: "Footer", width: 400, height: 100, html: "")
        let controller = MockCanvasController(document: document)
        let client = MCPTestClient(controller: controller)

        controller.selection = CanvasSelection(
            artboardIDs: ["hero"],
            element: SelectedElement(
                artboardID: "hero", selector: "h1", outerHTML: "<h1>Hi</h1>",
                rect: ElementRect(x: 10, y: 20, width: 100, height: 40)
            )
        )
        let selection = try await client.json("get_selection")
        XCTAssertEqual(selection["artboardIDs"], ["hero"])
        XCTAssertEqual(selection["element"]?["selector"], "h1")
        XCTAssertEqual(selection["element"]?["outerHTML"], "<h1>Hi</h1>")
        XCTAssertEqual(selection["element"]?["rect"]?["width"]?.number, 100)

        let shot = try await client.callTool("screenshot", ["id": "hero"])
        XCTAssertFalse(shot.isError, shot.text)
        XCTAssertEqual(shot.content.first?["type"], "image")
        XCTAssertEqual(shot.content.first?["mimeType"], "image/png")
        XCTAssertEqual(shot.content.first?["data"]?.string, controller.screenshotPNG.base64EncodedString())
        XCTAssertEqual(controller.screenshotRequests, ["hero"])
        let missingBoard = try await client.failure("screenshot", ["id": "nope"])
        XCTAssertTrue(missingBoard.contains("nope"), missingBoard)
        XCTAssertEqual(controller.screenshotRequests, ["hero"])

        controller.console = [
            ConsoleEntry(artboardID: "hero", level: "log", message: "ready", timestamp: Date(timeIntervalSince1970: 0)),
            ConsoleEntry(artboardID: "footer", level: "error", message: "boom", timestamp: Date(timeIntervalSince1970: 1)),
        ]
        let heroLogs = try await client.text("get_console", ["id": "hero"])
        XCTAssertTrue(heroLogs.contains("ready"), heroLogs)
        XCTAssertFalse(heroLogs.contains("boom"), heroLogs)
        let allLogs = try await client.text("get_console")
        XCTAssertTrue(allLogs.contains("[error] footer: boom"), allLogs)
        let lastOnly = try await client.text("get_console", ["limit": 1])
        XCTAssertFalse(lastOnly.contains("ready"), lastOnly)
        controller.console = []
        let none = try await client.text("get_console")
        XCTAssertFalse(none.isEmpty)

        _ = try await client.text("focus_artboard", ["id": "footer"])
        XCTAssertEqual(controller.focusedArtboards, ["footer"])
        _ = try await client.failure("focus_artboard", ["id": "nope"])
        XCTAssertEqual(controller.focusedArtboards, ["footer"])
    }

    @MainActor
    func testToolsFailCleanlyWithoutADocument() async throws {
        let controller = MockCanvasController()
        controller.recentDocuments = [URL(fileURLWithPath: "/tmp/Recent.canvas")]
        let client = MCPTestClient(controller: controller)

        let overview = try await client.failure("get_document")
        XCTAssertTrue(overview.contains("No document is open"), overview)
        XCTAssertTrue(overview.contains("/tmp/Recent.canvas"), overview)
        for (tool, arguments): (String, JSONValue) in [
            ("create_artboard", ["name": "X", "width": 1, "height": 1]), ("list_pages", [:]), ("get_tokens", [:]),
            ("screenshot", ["id": "x"]), ("list_components", [:]),
        ] {
            let message = try await client.failure(tool, arguments)
            XCTAssertTrue(message.contains("No document is open"), "\(tool): \(message)")
        }
    }

    @MainActor
    func testOpenAndCreateDocument() async throws {
        let controller = MockCanvasController()
        let client = MCPTestClient(controller: controller)
        let folder = try temporaryDocumentURL().deletingLastPathComponent()

        let created = try await client.json("create_document", ["path": .string(folder.appendingPathComponent("New").path)])
        XCTAssertEqual(controller.activeDocument?.url.lastPathComponent, "New.canvas")
        XCTAssertEqual(created["name"], "New")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("New.canvas/canvas.json").path))

        let existing = try CanvasDocument.create(at: folder.appendingPathComponent("Other.canvas"))
        let opened = try await client.json("open_document", ["path": .string(existing.url.path)])
        XCTAssertEqual(controller.activeDocument?.url.path, existing.url.path)
        XCTAssertEqual(opened["name"], "Other")

        let relative = try await client.failure("create_document", ["path": "Relative.canvas"])
        XCTAssertTrue(relative.contains("absolute"), relative)
        let duplicate = try await client.failure("create_document", ["path": .string(existing.url.path)])
        XCTAssertTrue(duplicate.contains("already exists"), duplicate)
    }

    @MainActor
    func testMissingOrInvalidArgumentsAndDocumentErrorsAreToolErrors() async throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 400, height: 300, html: "<p>a</p><p>a</p>")
        let client = MCPTestClient(controller: MockCanvasController(document: document))

        let missing = try await client.failure("read_artboard")
        XCTAssertTrue(missing.contains("Missing required argument \"id\""), missing)
        let wrongType = try await client.failure("create_artboard", ["name": "X", "width": "wide", "height": 10])
        XCTAssertTrue(wrongType.contains("\"width\" must be a number"), wrongType)
        let notUnique = try await client.failure("edit_artboard", ["id": "hero", "old_string": "a", "new_string": "b"])
        XCTAssertTrue(notUnique.contains("appears 2 times"), notUnique)
        let badSize = try await client.failure("update_artboard", ["id": "hero", "width": -1])
        XCTAssertTrue(badSize.contains("width"), badSize)
    }

    @MainActor
    func testStatusRecordsTheLastToolCall() async throws {
        let document = try makeDocument()
        let client = MCPTestClient(controller: MockCanvasController(document: document))
        XCTAssertNil(client.status.lastCall)

        _ = try await client.text("list_pages")
        let success = try XCTUnwrap(client.status.lastCall)
        XCTAssertEqual(success.name, "list_pages")
        XCTAssertTrue(success.succeeded)
        XCTAssertNil(success.errorMessage)
        XCTAssertLessThan(abs(success.date.timeIntervalSinceNow), 60)

        _ = try await client.failure("read_artboard", ["id": "nope"])
        let failure = try XCTUnwrap(client.status.lastCall)
        XCTAssertEqual(failure.name, "read_artboard")
        XCTAssertFalse(failure.succeeded)
        XCTAssertTrue(failure.errorMessage?.contains("nope") == true)
    }
}
