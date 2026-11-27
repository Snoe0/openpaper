import XCTest
@testable import CanvasCore

@MainActor
final class ShellArtboardInfoTests: XCTestCase {
    func testPresentsTheFirstSelectedBoardOnTheCurrentPage() throws {
        let document = try makeDocument()
        try document.addArtboard(name: "One", width: 100, height: 100, html: "")
        let two = try document.addArtboard(name: "Two", width: 100, height: 100, html: "")

        XCTAssertEqual(document.presentationTarget(selectedIDs: ["gone", two.id])?.id, two.id)
    }

    func testPresentsTheFirstBoardOfTheCurrentPageWithoutASelection() throws {
        let document = try makeDocument()
        let page = try document.addPage(name: "Other")
        try document.addArtboard(name: "Elsewhere", width: 100, height: 100, html: "", page: page.id)
        let one = try document.addArtboard(name: "One", width: 100, height: 100, html: "")

        XCTAssertEqual(document.presentationTarget(selectedIDs: ["elsewhere"])?.id, one.id)
    }

    func testThereIsNothingToPresentOnAnEmptyPage() throws {
        XCTAssertNil(try makeDocument().presentationTarget(selectedIDs: []))
    }

    func testInfoShowsSizePageAndMode() throws {
        let document = try makeDocument()
        let board = try document.addArtboard(name: "Hero", width: 1440, height: 900.5, html: "")

        XCTAssertEqual(
            document.info(ofArtboard: board.id),
            ArtboardInfo(name: "Hero", size: "1440 × 900.5", page: "Page 1", mode: "light (document)")
        )

        try document.updateArtboard(id: board.id, mode: .some("dark"))
        XCTAssertEqual(document.info(ofArtboard: board.id)?.mode, "dark")
        XCTAssertNil(document.info(ofArtboard: "missing"))
    }
}
