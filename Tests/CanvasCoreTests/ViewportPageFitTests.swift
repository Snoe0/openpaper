import XCTest
@testable import CanvasCore

/// WebKit sizes a web view's layout viewport from its width in whole points, so a half-point frame
/// (whole device pixels on Retina) still narrows the CSS viewport. Frames are whole points.
final class ViewportPageFitTests: XCTestCase {
    func testTheFrameWidthIsWholePointsAndTheZoomKeepsTheBoardWidth() {
        for scale in [0.249, 0.5615, 0.7419, 0.8787, 1.5188] as [CGFloat] {
            let fit = PageFit(boardSize: CGSize(width: 400, height: 300), scale: scale)

            XCTAssertEqual(fit.frameSize.width, (400 * scale).rounded(.down), "scale \(scale)")
            // The page's CSS viewport is exactly the board width, so width breakpoints don't flicker.
            XCTAssertEqual(fit.frameSize.width / fit.zoom, 400, accuracy: 1e-9, "scale \(scale)")
        }
    }

    func testTheHeightIsRoundedUpToWholePointsAtTheSameZoom() {
        let fit = PageFit(boardSize: CGSize(width: 400, height: 300), scale: 0.249)

        // Width 99 → zoom 0.2475; 300 × 0.2475 = 74.25 → 75, so the page covers the whole board
        // (the board view clips the overhang).
        XCTAssertEqual(fit.frameSize.height, 75)
        XCTAssertGreaterThanOrEqual(fit.frameSize.height / fit.zoom, 300)
    }

    func testWholeScalesAreExact() {
        let fit = PageFit(boardSize: CGSize(width: 1440, height: 900), scale: 1)

        XCTAssertEqual(fit.frameSize, CGSize(width: 1440, height: 900))
        XCTAssertEqual(fit.zoom, 1)
    }

    func testTinyScalesKeepAtLeastOnePoint() {
        let fit = PageFit(boardSize: CGSize(width: 10, height: 10), scale: 0.02)

        XCTAssertEqual(fit.frameSize, CGSize(width: 1, height: 1))
        XCTAssertEqual(fit.zoom, 0.1, accuracy: 1e-12)
    }
}
