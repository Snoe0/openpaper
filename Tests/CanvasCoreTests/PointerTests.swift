import XCTest
@testable import CanvasCore

final class PointerTests: XCTestCase {
    func testABoardPointerIsCanvasColonTheBoardID() throws {
        XCTAssertEqual(CanvasPointer.board("hero").description, "canvas:hero")
        XCTAssertEqual(try CanvasPointer(parsing: "canvas:hero"), .board("hero"))
    }

    func testAnElementPointerAddsTheSelectorAfterAnAngleBracket() throws {
        let pointer = CanvasPointer.element(board: "hero", selector: "section.pricing > a.cta")
        XCTAssertEqual(pointer.description, "canvas:hero > section.pricing > a.cta")
        XCTAssertEqual(try CanvasPointer(parsing: pointer.description), pointer)
    }

    func testSelectorsRoundTripWhateverTheyContain() throws {
        let selectors = [
            "body > main:nth-of-type(1) > p:nth-of-type(2)",
            "#two",
            "#a\\ b > span",
            #"a[title="say \"hi\" > there"]"#,
            "a[title='it''s'] > b",
            "ul li:nth-of-type(2n + 1) > a",
        ]
        for selector in selectors {
            let pointer = CanvasPointer.element(board: "pricing-page", selector: selector)
            XCTAssertEqual(try CanvasPointer(parsing: pointer.description), pointer, selector)
        }
    }

    func testParsingToleratesSurroundingWhitespaceAndTightBrackets() throws {
        XCTAssertEqual(try CanvasPointer(parsing: "  canvas:hero > h1\n"), .element(board: "hero", selector: "h1"))
        XCTAssertEqual(try CanvasPointer(parsing: "canvas:hero>h1>b"), .element(board: "hero", selector: "h1>b"))
    }

    func testTheBoardOfAPointer() {
        XCTAssertEqual(CanvasPointer.board("hero").boardID, "hero")
        XCTAssertEqual(CanvasPointer.element(board: "hero", selector: "h1").boardID, "hero")
    }

    func testGarbledPointersAreRejectedWithAClearError() {
        let cases: [(String, PointerError)] = [
            ("", .notAPointer("")),
            ("hero > h1", .notAPointer("hero > h1")),
            ("canvas:", .invalidBoardID("")),
            ("canvas:Hero Page", .invalidBoardID("Hero Page")),
            ("canvas:hero >", .emptySelector),
            ("canvas:hero >   ", .emptySelector),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try CanvasPointer(parsing: text), text) { error in
                XCTAssertEqual(error as? PointerError, expected, text)
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    /// Later kinds look like `canvas:note/<id>`: a slash, which board ids never contain, so a board named
    /// "note" (`canvas:note`) never collides with them. Kinds this build doesn't know are rejected.
    func testUnknownKindsAreRejectedAndNeverMistakenForBoards() throws {
        XCTAssertEqual(try CanvasPointer(parsing: "canvas:note"), .board("note"))
        XCTAssertThrowsError(try CanvasPointer(parsing: "canvas:note/abc")) { error in
            XCTAssertEqual(error as? PointerError, .unknownKind("note"))
            XCTAssertTrue(error.localizedDescription.contains("note"))
        }
    }

    func testErrorMessagesShowTheExpectedFormat() {
        XCTAssertTrue(PointerError.notAPointer("hi").localizedDescription.contains("canvas:<artboard id>"))
    }
}
