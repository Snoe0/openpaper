import XCTest
@testable import CanvasCore

final class NavigationPolicyTests: XCTestCase {
    private let board = CanvasURL.artboard("hero")

    private func decide(_ url: String?, mainFrame: Bool? = true, userClick: Bool = false) -> NavigationPolicy {
        NavigationPolicy.decide(url: url.flatMap(URL.init(string:)), targetIsMainFrame: mainFrame, boardURL: board, isUserClick: userClick)
    }

    func testTheBoardsOwnPageLoadsReloadsAndFollowsFragments() {
        XCTAssertEqual(board.absoluteString, "canvas://doc/__artboard__hero.html")
        XCTAssertEqual(decide(board.absoluteString), .allow)
        XCTAssertEqual(decide("canvas://doc/__artboard__hero.html#pricing", userClick: true), .allow)
        XCTAssertEqual(decide("canvas://doc/__artboard__hero.html#"), .allow)
    }

    func testOtherMainFrameNavigationsAreCancelled() {
        XCTAssertEqual(decide("https://example.com/"), .cancel, "a script setting location")
        XCTAssertEqual(decide("canvas://doc/__artboard__other.html"), .cancel)
        XCTAssertEqual(decide("canvas://doc/__artboard__hero.html?x=1"), .cancel)
        XCTAssertEqual(decide("canvas://doc/assets/logo.png", userClick: true), .cancel)
        XCTAssertEqual(decide("about:blank"), .cancel)
        XCTAssertEqual(decide("file:///etc/passwd", userClick: true), .cancel)
        XCTAssertEqual(decide("mailto:a@b.c", userClick: true), .cancel)
        XCTAssertEqual(decide(nil), .cancel)
    }

    func testClickedWebLinksOpenInTheBrowser() {
        XCTAssertEqual(decide("https://example.com/", userClick: true), .openExternally)
        XCTAssertEqual(decide("HTTP://example.com/", userClick: true), .openExternally)
    }

    func testANewWindowRequestCountsAsTopLevel() {
        XCTAssertEqual(decide("https://example.com/", mainFrame: nil, userClick: true), .openExternally, "a clicked target=_blank link")
        XCTAssertEqual(decide("https://example.com/", mainFrame: nil), .cancel, "a new window without the user's click (a script's window.open or a.click())")
    }

    func testOnlyARealMouseClickInAViewThatTakesThePointerIsTheUsers() {
        let isUserClick = { NavigationPolicy.isUserClick(isLinkActivation: $0, mouseButton: $1, viewAcceptsMouse: $2) }
        XCTAssertTrue(isUserClick(true, 1, true), "a left click in a presented page or inspect mode")
        XCTAssertFalse(isUserClick(true, 0, true), "a script's a.click(): WebKit reports no mouse button")
        XCTAssertFalse(isUserClick(true, 1, false), "a board that ignores the pointer (canvas, snapshots)")
        XCTAssertFalse(isUserClick(false, 1, true), "not a link activation")
    }

    func testSubframeLoadsAreUnaffected() {
        XCTAssertEqual(decide("https://www.youtube.com/embed/x", mainFrame: false), .allow)
        XCTAssertEqual(decide("canvas://doc/__artboard__other.html", mainFrame: false), .allow)
    }
}
