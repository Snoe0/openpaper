import XCTest
@testable import CanvasCore

/// `get_element`: resolving a pointer the user copied from the canvas.
@MainActor
final class BridgePointerToolTests: XCTestCase {
    private let cta = PageElement(
        selector: "body > section:nth-of-type(1) > a:nth-of-type(1)",
        outerHTML: #"<a class="cta">Buy</a>"#,
        box: ElementRect(x: 10, y: 20, width: 116, height: 38),
        styles: ["display": "block", "font-size": "20px"],
        matches: 1
    )

    private func makeController() throws -> MockCanvasController {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 400, height: 300, html: #"<section><a class="cta">Buy</a></section>"#)
        let controller = MockCanvasController(document: document)
        controller.elements = ["hero": ["section > a.cta": cta]]
        return controller
    }

    func testAnElementPointerReturnsTheElementsHTMLBoxAndStyles() async throws {
        let controller = try makeController()
        let client = MCPTestClient(controller: controller)

        let element = try await client.json("get_element", ["pointer": "canvas:hero > section > a.cta"])

        XCTAssertEqual(element["pointer"], "canvas:hero > section > a.cta")
        XCTAssertEqual(element["board"]?["id"], "hero")
        XCTAssertEqual(element["board"]?["name"], "Hero")
        XCTAssertEqual(element["selector"]?.string, cta.selector)
        XCTAssertEqual(element["outerHTML"]?.string, cta.outerHTML)
        XCTAssertEqual(element["box"], ["x": 10, "y": 20, "width": 116, "height": 38])
        XCTAssertEqual(element["styles"], ["display": "block", "font-size": "20px"])
        XCTAssertEqual(element["matches"], 1)
        XCTAssertNil(element["truncated"])
        XCTAssertEqual(controller.elementRequests.map(\.selector), ["section > a.cta"])
    }

    func testCutHTMLAndAmbiguousSelectorsAreFlagged() async throws {
        let controller = try makeController()
        var long = cta
        long.outerHTML = String(repeating: "x", count: PageElement.maxHTMLLength)
        long.truncated = true
        long.matches = 3
        controller.elements["hero"]?["a"] = long
        let client = MCPTestClient(controller: controller)

        let element = try await client.json("get_element", ["pointer": "canvas:hero > a"])

        XCTAssertEqual(element["truncated"], true)
        XCTAssertEqual(element["matches"], 3)
    }

    func testAMalformedSelectorIsReportedAsSuchNotAsStale() async throws {
        let controller = try makeController()
        controller.invalidSelectors = ["a["]
        let client = MCPTestClient(controller: controller)

        let message = try await client.failure("get_element", ["pointer": "canvas:hero > a["])

        XCTAssertTrue(message.contains("\"a[\" isn't a valid CSS selector"), message)
        XCTAssertFalse(message.contains("stale"), message)
    }

    func testWithNoDocumentOpenItSaysSoRatherThanStale() async throws {
        let client = MCPTestClient(controller: MockCanvasController())

        let message = try await client.failure("get_element", ["pointer": "canvas:hero"])

        XCTAssertTrue(message.contains("No document is open"), message)
        XCTAssertFalse(message.contains("stale"), message)
    }

    func testABoardPointerReturnsTheArtboard() async throws {
        let client = MCPTestClient(controller: try makeController())

        let board = try await client.json("get_element", ["pointer": "canvas:hero"])

        XCTAssertEqual(board["id"], "hero")
        XCTAssertEqual(board["name"], "Hero")
        XCTAssertEqual(board["width"]?.number, 400)
        XCTAssertEqual(board["height"]?.number, 300)
    }

    func testAPointerToADeletedBoardIsStale() async throws {
        let controller = try makeController()
        let client = MCPTestClient(controller: controller)
        try controller.activeDocument?.deleteArtboard(id: "hero")

        let element = try await client.failure("get_element", ["pointer": "canvas:hero > section > a.cta"])
        let board = try await client.failure("get_element", ["pointer": "canvas:hero"])

        XCTAssertTrue(element.contains("stale"), element)
        XCTAssertTrue(element.contains("no artboard \"hero\""), element)
        XCTAssertTrue(board.contains("no artboard \"hero\""), board)
        XCTAssertTrue(controller.elementRequests.isEmpty)
    }

    func testABoardDeletedWhileItsPageIsAskedMakesThePointerStale() async throws {
        let controller = try makeController()
        controller.whileAnswering = {
            try controller.activeDocument?.deleteArtboard(id: "hero")
            throw ToolError("Artboard hero no longer exists.")
        }
        let client = MCPTestClient(controller: controller)

        let message = try await client.failure("get_element", ["pointer": "canvas:hero > section > a.cta"])

        XCTAssertTrue(message.contains("The pointer canvas:hero > section > a.cta is stale"), message)
        XCTAssertTrue(message.contains("there is no artboard \"hero\""), message)
    }

    func testAPageThatFailsWhileItsBoardStillExistsKeepsItsOwnError() async throws {
        let controller = try makeController()
        controller.whileAnswering = { throw ToolError("Artboard hero's page didn't answer within 5 s.") }
        let client = MCPTestClient(controller: controller)

        let message = try await client.failure("get_element", ["pointer": "canvas:hero > section > a.cta"])

        XCTAssertTrue(message.contains("didn't answer"), message)
        XCTAssertFalse(message.contains("stale"), message)
    }

    func testTheToolGivesTheHTMLCap() throws {
        let description = try XCTUnwrap(BridgeTools.named("get_element")?.description)
        XCTAssertTrue(description.contains("at most \(PageElement.maxHTMLLength) characters"), description)
    }

    func testAPointerWhoseSelectorMatchesNothingIsStale() async throws {
        let client = MCPTestClient(controller: try makeController())

        let message = try await client.failure("get_element", ["pointer": "canvas:hero > section > a.gone"])

        XCTAssertTrue(message.contains("stale"), message)
        XCTAssertTrue(message.contains("no element on artboard \"hero\" matches \"section > a.gone\""), message)
    }

    func testAGarbledPointerExplainsTheFormat() async throws {
        let client = MCPTestClient(controller: try makeController())

        let garbled = try await client.failure("get_element", ["pointer": "hero > a"])
        let unknownKind = try await client.failure("get_element", ["pointer": "canvas:note/n1"])

        XCTAssertTrue(garbled.contains("canvas:<artboard id> > <CSS selector>"), garbled)
        XCTAssertTrue(unknownKind.contains("\"note/\""), unknownKind)
    }

    func testTheInstructionsExplainPointers() {
        XCTAssertTrue(MCPHandler.instructions.contains("canvas:<artboard id> > <CSS selector>"))
        XCTAssertTrue(MCPHandler.instructions.contains("get_element"))
        XCTAssertTrue(MCPHandler.instructions.contains("short-term"))
    }

    func testTheToolSaysWhereTheBoxIsMeasuredFrom() throws {
        let description = try XCTUnwrap(BridgeTools.named("get_element")?.description)
        XCTAssertTrue(description.contains("viewport"), description)
    }

    func testTheScreenshotToolSaysHugeBoardsComeBackScaledDown() throws {
        let description = try XCTUnwrap(BridgeTools.named("screenshot")?.description)
        XCTAssertTrue(description.contains("scaled down"), description)
    }
}
