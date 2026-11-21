import XCTest
@testable import CanvasCore

final class ShellTokenEditingTests: XCTestCase {
    private let tokens = Tokens(modes: ["light", "dark"], tokens: [
        "radius": .single("8px"),
        "color.bg": .perMode(["light": "#fff", "dark": "#000"]),
        "color.fg": .perMode(["light": "#111"]),
    ])

    func testValuesForAModeFallBackLikeTheCompiledCSS() {
        XCTAssertEqual(tokens.value(of: "radius", mode: "dark"), "8px")
        XCTAssertEqual(tokens.value(of: "color.bg", mode: "dark"), "#000")
        XCTAssertEqual(tokens.value(of: "color.fg", mode: "dark"), "#111")
        XCTAssertNil(tokens.value(of: "missing", mode: "dark"))
    }

    func testNamesAreSorted() {
        XCTAssertEqual(tokens.sortedNames, ["color.bg", "color.fg", "radius"])
    }

    func testEditingAPerModeTokenChangesOnlyThatMode() {
        XCTAssertEqual(tokens.editedValue(of: "color.bg", setting: "#222", mode: "dark"), .perMode(["light": "#fff", "dark": "#222"]))
    }

    func testEditingASingleValueSplitsItPerModeWhenThereAreSeveralModes() {
        XCTAssertEqual(tokens.editedValue(of: "radius", setting: "4px", mode: "dark"), .perMode(["light": "8px", "dark": "4px"]))
    }

    func testEditingASingleValueWithOneModeStaysSingle() {
        let single = Tokens(modes: ["default"], tokens: ["radius": .single("8px")])

        XCTAssertEqual(single.editedValue(of: "radius", setting: "4px", mode: "default"), .single("4px"))
    }

    func testANewTokenIsOneValueForEveryMode() {
        XCTAssertEqual(tokens.editedValue(of: "space.2", setting: "8px", mode: "dark"), .single("8px"))
    }

    func testAnInPlaceEditIsCommittedInTheModeItWasMadeIn() {
        XCTAssertEqual(
            tokens.committedValue(of: "color.bg", edited: "#222", shownWhenEditingBegan: "#000", mode: "dark"),
            .perMode(["light": "#fff", "dark": "#222"])
        )
    }

    func testAnUnchangedFieldCommitsNothingSoAnAgentsEditSurvives() {
        // The agent changed color.bg while the field was focused; the field still shows the old value.
        XCTAssertNil(tokens.committedValue(of: "color.bg", edited: "#123", shownWhenEditingBegan: "#123", mode: "dark"))
    }

    func testAnEditToADeletedTokenDoesntBringItBack() {
        XCTAssertNil(tokens.committedValue(of: "gone", edited: "#222", shownWhenEditingBegan: "#000", mode: "dark"))
    }

    func testTokenNamesAreTrimmedAndMustNotBeEmpty() throws {
        XCTAssertEqual(try TokenName.validated("  color.brand \n", existing: []), "color.brand")
        XCTAssertThrowsError(try TokenName.validated("   ", existing: []))
    }

    func testANewTokenCantReuseAnExistingName() {
        XCTAssertThrowsError(try TokenName.validated(" color.bg ", existing: tokens.sortedNames)) { error in
            XCTAssertTrue(error.localizedDescription.contains("color.bg"))
        }
    }
}
