import XCTest
import CanvasCore

final class ShellZoomStepsTests: XCTestCase {
    func testZoomingInGoesToTheNextPresetAbove() {
        XCTAssertEqual(ZoomSteps.zoomedIn(from: 1), 1.5)
        XCTAssertEqual(ZoomSteps.zoomedIn(from: 0.6), 0.75)
        XCTAssertEqual(ZoomSteps.zoomedIn(from: 8), 8)
    }

    func testZoomingOutGoesToTheNextPresetBelow() {
        XCTAssertEqual(ZoomSteps.zoomedOut(from: 1), 0.75)
        XCTAssertEqual(ZoomSteps.zoomedOut(from: 0.6), 0.5)
        XCTAssertEqual(ZoomSteps.zoomedOut(from: 0.02), 0.02)
    }

    func testAScaleJustOffAPresetStillMovesAFullStep() {
        XCTAssertEqual(ZoomSteps.zoomedIn(from: 0.99999), 1.5)
        XCTAssertEqual(ZoomSteps.zoomedOut(from: 1.00001), 0.75)
    }

    func testPercentLabelsRound() {
        XCTAssertEqual(ZoomSteps.percent(1), "100%")
        XCTAssertEqual(ZoomSteps.percent(0.333), "33%")
        XCTAssertEqual(ZoomSteps.percent(0.004), "0.4%")
    }
}
