import XCTest
@testable import CanvasCore

final class ShellTabListTests: XCTestCase {
    private func tabs(_ ids: String..., selected: String? = nil) -> TabList<String> {
        var list = TabList<String>()
        for id in ids { list.open(id) }
        list.select(selected)
        return list
    }

    func testStartsOnTheDashboard() {
        let list = TabList<String>()

        XCTAssertEqual(list.ids, [])
        XCTAssertNil(list.selected)
    }

    func testOpeningAddsATabAndSelectsIt() {
        var list = TabList<String>()

        list.open("a")
        list.open("b")

        XCTAssertEqual(list.ids, ["a", "b"])
        XCTAssertEqual(list.selected, "b")
    }

    func testOpeningAnOpenTabSelectsItWithoutDuplicating() {
        var list = tabs("a", "b")

        list.open("a")

        XCTAssertEqual(list.ids, ["a", "b"])
        XCTAssertEqual(list.selected, "a")
    }

    func testSelectingNilShowsTheDashboardAndUnknownIDsAreIgnored() {
        var list = tabs("a", "b")

        list.select(nil)
        XCTAssertNil(list.selected)

        list.select("zzz")
        XCTAssertNil(list.selected)
    }

    func testClosingTheSelectedTabSelectsTheTabToItsRight() {
        var list = tabs("a", "b", "c", selected: "b")

        list.close("b")

        XCTAssertEqual(list.ids, ["a", "c"])
        XCTAssertEqual(list.selected, "c")
    }

    func testClosingTheLastTabSelectsTheTabToItsLeft() {
        var list = tabs("a", "b", "c", selected: "c")

        list.close("c")

        XCTAssertEqual(list.selected, "b")
    }

    func testClosingTheOnlyTabShowsTheDashboard() {
        var list = tabs("a")

        list.close("a")

        XCTAssertEqual(list.ids, [])
        XCTAssertNil(list.selected)
    }

    func testClosingAnotherTabKeepsTheSelection() {
        var list = tabs("a", "b", "c", selected: "a")

        list.close("c")

        XCTAssertEqual(list.ids, ["a", "b"])
        XCTAssertEqual(list.selected, "a")
    }

    func testClosingWhileOnTheDashboardStaysThere() {
        var list = tabs("a", "b", selected: nil)

        list.close("a")

        XCTAssertNil(list.selected)
    }
}
