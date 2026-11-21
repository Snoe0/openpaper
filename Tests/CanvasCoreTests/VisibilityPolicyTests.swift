import XCTest
@testable import CanvasCore

final class VisibilityPolicyTests: XCTestCase {
    private let screen = CGSize(width: 1000, height: 800)
    private let policy = VisibilityPolicy(minLiveScale: 0.3, margin: 100, capacity: 12)

    func testBoardsInViewAtReadableScaleAreLive() {
        let boards = [board("b", x: 600, y: 0), board("a", x: 0, y: 0)]

        XCTAssertEqual(policy.liveBoards(boards, viewport: Viewport(origin: .zero, scale: 1), screenSize: screen), ["a", "b"])
    }

    func testBoardsBelowTheScaleThresholdAreNotLive() {
        let boards = [board("a", x: 0, y: 0)]

        XCTAssertEqual(policy.liveBoards(boards, viewport: Viewport(origin: .zero, scale: 0.29), screenSize: screen), [])
        XCTAssertEqual(policy.liveBoards(boards, viewport: Viewport(origin: .zero, scale: 0.3), screenSize: screen), ["a"])
    }

    func testBoardsJustOutsideTheViewportStayLiveWithinTheMargin() {
        // At scale 1 the screen shows canvas x 0…1000; the margin adds 100 screen points.
        let nearby = board("near", x: 1050, y: 0)
        let far = board("far", x: 1150, y: 0)

        XCTAssertEqual(policy.liveBoards([nearby, far], viewport: Viewport(origin: .zero, scale: 1), screenSize: screen), ["near"])
    }

    func testTheMarginIsInScreenPoints() {
        // At scale 2 the margin of 100 screen points covers 50 canvas points.
        let viewport = Viewport(origin: .zero, scale: 2) // shows canvas x 0…500
        let inside = board("in", x: 540, y: 0)
        let outside = board("out", x: 560, y: 0)

        XCTAssertEqual(policy.liveBoards([inside, outside], viewport: viewport, screenSize: screen), ["in"])
    }

    func testLiveBoardsAreOrderedByDistanceToTheCentreThenID() {
        let viewport = Viewport(origin: .zero, scale: 1) // centre at (500, 400)
        let boards = [
            board("z-edge", x: 0, y: 0, width: 100, height: 100),
            board("b-centre", x: 450, y: 350, width: 100, height: 100),
            board("a-centre", x: 450, y: 350, width: 100, height: 100),
        ]

        XCTAssertEqual(policy.liveBoards(boards, viewport: viewport, screenSize: screen), ["a-centre", "b-centre", "z-edge"])
    }

    func testLiveBoardsAreCappedAtCapacityKeepingTheClosest() {
        let small = VisibilityPolicy(minLiveScale: 0.3, margin: 0, capacity: 2)
        let boards = [board("left", x: 0, y: 350, width: 10, height: 10),
                      board("mid", x: 495, y: 395, width: 10, height: 10),
                      board("right", x: 600, y: 395, width: 10, height: 10)]

        XCTAssertEqual(small.liveBoards(boards, viewport: Viewport(origin: .zero, scale: 1), screenSize: screen), ["mid", "right"])
    }

    func testDefaultsMatchTheSpec() {
        let defaults = VisibilityPolicy()
        XCTAssertEqual(defaults.minLiveScale, 0.3)
        XCTAssertEqual(defaults.capacity, 12)
        XCTAssertEqual(defaults.liveAreaBudget, 6_000_000)
    }

    // MARK: - Area budget (below 100% WebKit rasterises a live page at its board size)

    func testTwelvePhoneBoardsAtHalfSizeAreAllLive() {
        let boards = (0..<12).map { board("p\($0)", x: CGFloat($0 % 6) * 430, y: CGFloat($0 / 6) * 900, width: 390, height: 844) }

        let live = VisibilityPolicy().liveBoards(boards, viewport: Viewport(origin: .zero, scale: 0.5), screenSize: screen)

        XCTAssertEqual(Set(live), Set(boards.map(\.id)))
    }

    func testSixWebsiteBoardsAtThirtyPercentStopAtTheAreaBudgetLeavingTheFarthest() {
        let live = VisibilityPolicy().liveBoards(websiteBoards(), viewport: Viewport(origin: .zero, scale: 0.3), screenSize: screen)

        XCTAssertEqual(live.count, 5)
        XCTAssertFalse(live.contains("r0c0"), "the farthest from the centre gets a snapshot")
    }

    func testTheNearestBoardIsLiveEvenOverTheBudget() {
        let huge = [board("huge", x: 0, y: 0, width: 3000, height: 4000)]

        XCTAssertEqual(VisibilityPolicy().liveBoards(huge, viewport: Viewport(origin: .zero, scale: 0.5), screenSize: screen), ["huge"])
    }

    func testAtFullSizeTheBudgetDoesNotApply() {
        let live = VisibilityPolicy().liveBoards(websiteBoards(), viewport: Viewport(origin: .zero, scale: 1), screenSize: CGSize(width: 3000, height: 3000))

        XCTAssertEqual(live.count, 6)
    }

    /// The inspected board stays live: it comes first and counts toward the budget and capacity.
    func testAKeptBoardIsLiveFirstAndCountsTowardTheBudget() {
        let live = VisibilityPolicy().liveBoards(websiteBoards(), viewport: Viewport(origin: .zero, scale: 0.3), screenSize: screen, keeping: "r0c0")

        XCTAssertEqual(live.first, "r0c0")
        XCTAssertEqual(live.count, 5)
    }

    func testAKeptBoardIsLiveBelowTheScaleThresholdAndOutOfView() {
        let boards = [board("a", x: 0, y: 0), board("far", x: 90_000, y: 0)]

        XCTAssertEqual(policy.liveBoards(boards, viewport: Viewport(origin: .zero, scale: 0.2), screenSize: screen, keeping: "far"), ["far"])
        XCTAssertEqual(policy.liveBoards(boards, viewport: Viewport(origin: .zero, scale: 0.2), screenSize: screen, keeping: "gone"), [])
    }

    func testAKeptBoardCountsTowardCapacity() {
        let two = VisibilityPolicy(minLiveScale: 0.3, margin: 0, capacity: 2)
        let boards = [board("a", x: 0, y: 0), board("b", x: 450, y: 0), board("far", x: 90_000, y: 0)]

        XCTAssertEqual(two.liveBoards(boards, viewport: Viewport(origin: .zero, scale: 1), screenSize: screen, keeping: "far").count, 2)
    }

    /// A board too big for what's left of the budget is skipped, and a smaller, farther one still fits.
    func testABoardOverTheRemainingBudgetIsSkippedForASmallerFartherOne() {
        let budget = VisibilityPolicy(liveAreaBudget: 1_000_000)
        let viewport = Viewport(origin: .zero, scale: 0.5) // shows canvas 0…2000 × 0…1600, centre (1000, 800)
        let boards = [board("near", x: 750, y: 550, width: 500, height: 500),      // 0.25 MP at the centre
                      board("big", x: 1200, y: 300, width: 1000, height: 1000),    // 1 MP, 700 away
                      board("small", x: 800, y: 1500, width: 400, height: 400)]    // 0.16 MP, 900 away

        XCTAssertEqual(budget.liveBoards(boards, viewport: viewport, screenSize: screen), ["near", "small"])
    }

    /// The kept board is live first even over the budget, so it pushes out the nearest.
    func testAKeptBoardOverTheBudgetPushesOutTheNearest() {
        let budget = VisibilityPolicy(liveAreaBudget: 1_000_000)
        let boards = [board("near", x: 700, y: 500, width: 600, height: 600), board("huge", x: 90_000, y: 0, width: 1000, height: 1100)]

        XCTAssertEqual(budget.liveBoards(boards, viewport: Viewport(origin: .zero, scale: 0.5), screenSize: screen, keeping: "huge"), ["huge"])
    }

    /// Six 1280×800 boards (1.02 MP each) in 2 columns and 3 rows, all in view at 30%.
    private func websiteBoards() -> [BoardFrame] {
        (0..<6).map { board("r\($0 / 2)c\($0 % 2)", x: CGFloat($0 % 2) * 1360, y: CGFloat($0 / 2) * 880, width: 1280, height: 800) }
    }

    func testNearestFirstOrdersByDistanceToThePointThenID() {
        let boards = [board("far", x: 900, y: 0, width: 10, height: 10),
                      board("b", x: 95, y: 95, width: 10, height: 10),
                      board("a", x: 95, y: 95, width: 10, height: 10)]

        XCTAssertEqual(VisibilityPolicy.nearestFirst(boards, to: CGPoint(x: 100, y: 100)), ["a", "b", "far"])
    }

    private func board(_ id: String, x: CGFloat, y: CGFloat, width: CGFloat = 400, height: CGFloat = 300) -> BoardFrame {
        BoardFrame(id: id, rect: CGRect(x: x, y: y, width: width, height: height))
    }
}
