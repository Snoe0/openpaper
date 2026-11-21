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
