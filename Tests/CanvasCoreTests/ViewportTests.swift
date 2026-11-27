import XCTest
@testable import CanvasCore

final class ViewportTests: XCTestCase {
    func testScreenAndCanvasPointsConvertBothWays() {
        let viewport = Viewport(origin: CGPoint(x: 100, y: -50), scale: 2)

        XCTAssertEqual(viewport.screenPoint(fromCanvas: CGPoint(x: 110, y: -40)), CGPoint(x: 20, y: 20))
        XCTAssertEqual(viewport.canvasPoint(fromScreen: CGPoint(x: 20, y: 20)), CGPoint(x: 110, y: -40))
    }

    func testRectsConvertBothWays() {
        let viewport = Viewport(origin: CGPoint(x: 10, y: 10), scale: 0.5)
        let canvasRect = CGRect(x: 110, y: 210, width: 400, height: 300)

        XCTAssertEqual(viewport.screenRect(fromCanvas: canvasRect), CGRect(x: 50, y: 100, width: 200, height: 150))
        XCTAssertEqual(viewport.canvasRect(fromScreen: CGRect(x: 50, y: 100, width: 200, height: 150)), canvasRect)
    }

    func testVisibleCanvasRectCoversTheScreen() {
        let viewport = Viewport(origin: CGPoint(x: -100, y: 40), scale: 4)

        XCTAssertEqual(viewport.visibleCanvasRect(screenSize: CGSize(width: 800, height: 400)), CGRect(x: -100, y: 40, width: 200, height: 100))
    }

    func testZoomKeepsTheCanvasPointUnderTheCursorFixed() {
        let viewport = Viewport(origin: CGPoint(x: 30, y: 70), scale: 1)
        let cursor = CGPoint(x: 400, y: 250)
        let underCursor = viewport.canvasPoint(fromScreen: cursor)

        let zoomed = viewport.zoomed(by: 2.5, around: cursor)

        XCTAssertEqual(zoomed.scale, 2.5, accuracy: 1e-9)
        assertEqual(zoomed.canvasPoint(fromScreen: cursor), underCursor)
    }

    func testZoomIsClampedToTheScaleRange() {
        let viewport = Viewport(origin: .zero, scale: 1)
        let cursor = CGPoint(x: 100, y: 100)

        XCTAssertEqual(viewport.zoomed(by: 1000, around: cursor).scale, Viewport.maxScale)
        XCTAssertEqual(viewport.zoomed(by: 0.0001, around: cursor).scale, Viewport.minScale)
        XCTAssertEqual(viewport.zoomed(to: 0, around: cursor).scale, Viewport.minScale)
        XCTAssertEqual(Viewport.minScale, 0.02)
        XCTAssertEqual(Viewport.maxScale, 8)
    }

    func testClampedZoomStillKeepsTheCursorPointFixed() {
        let viewport = Viewport(origin: CGPoint(x: 5, y: 5), scale: 4)
        let cursor = CGPoint(x: 300, y: 200)
        let underCursor = viewport.canvasPoint(fromScreen: cursor)

        assertEqual(viewport.zoomed(by: 10, around: cursor).canvasPoint(fromScreen: cursor), underCursor)
    }

    func testPanMovesContentWithTheScreenDelta() {
        let viewport = Viewport(origin: CGPoint(x: 100, y: 100), scale: 2)
        let canvasPoint = CGPoint(x: 150, y: 150)
        let before = viewport.screenPoint(fromCanvas: canvasPoint)

        let panned = viewport.panned(by: CGSize(width: 40, height: -10))

        XCTAssertEqual(panned.screenPoint(fromCanvas: canvasPoint), CGPoint(x: before.x + 40, y: before.y - 10))
        XCTAssertEqual(panned.scale, 2)
    }

    func testFittingCentresTheRectWithPadding() {
        let rect = CGRect(x: 100, y: 200, width: 1000, height: 500)
        let screen = CGSize(width: 1200, height: 800)

        let viewport = Viewport.fitting(rect, screenSize: screen, padding: 100)

        // Width-bound: (1200 - 200) / 1000 = 1.0; height would allow 600 / 500 = 1.2.
        XCTAssertEqual(viewport.scale, 1, accuracy: 1e-9)
        let shown = viewport.screenRect(fromCanvas: rect)
        XCTAssertEqual(shown.minX, 100, accuracy: 1e-9)
        XCTAssertEqual(shown.midY, 400, accuracy: 1e-9)
    }

    func testFittingIsClampedToTheScaleRange() {
        let screen = CGSize(width: 1000, height: 1000)

        XCTAssertEqual(Viewport.fitting(CGRect(x: 0, y: 0, width: 1, height: 1), screenSize: screen, padding: 0).scale, Viewport.maxScale)
        XCTAssertEqual(Viewport.fitting(CGRect(x: 0, y: 0, width: 1e7, height: 1e7), screenSize: screen, padding: 0).scale, Viewport.minScale)
    }

    func testFittingStillCentresWhenTheScaleIsClamped() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let viewport = Viewport.fitting(rect, screenSize: CGSize(width: 1000, height: 600), padding: 40)

        let shown = viewport.screenRect(fromCanvas: rect)
        XCTAssertEqual(shown.midX, 500, accuracy: 1e-9)
        XCTAssertEqual(shown.midY, 300, accuracy: 1e-9)
    }

    func testFittingSurvivesPaddingLargerThanTheScreen() {
        let viewport = Viewport.fitting(CGRect(x: 0, y: 0, width: 100, height: 100), screenSize: CGSize(width: 50, height: 50), padding: 100)

        XCTAssertEqual(viewport.scale, Viewport.minScale)
    }

    func testConversionsRoundTripAtTheScaleLimits() {
        for scale in [Viewport.minScale, Viewport.maxScale] {
            let viewport = Viewport(origin: CGPoint(x: -1234.5, y: 987.25), scale: scale)
            let point = CGPoint(x: 321.5, y: 77.25)
            let rect = CGRect(x: -50, y: 20, width: 400, height: 300)

            assertEqual(viewport.screenPoint(fromCanvas: viewport.canvasPoint(fromScreen: point)), point, accuracy: 1e-6)
            let back = viewport.canvasRect(fromScreen: viewport.screenRect(fromCanvas: rect))
            assertEqual(back.origin, rect.origin, accuracy: 1e-6)
            XCTAssertEqual(back.width, rect.width, accuracy: 1e-6)
            XCTAssertEqual(back.height, rect.height, accuracy: 1e-6)
        }
    }

    func testCentringPutsTheCanvasPointMidScreen() {
        let viewport = Viewport.centred(on: CGPoint(x: 500, y: -200), scale: 2, screenSize: CGSize(width: 800, height: 600))

        XCTAssertEqual(viewport.scale, 2)
        assertEqual(viewport.screenPoint(fromCanvas: CGPoint(x: 500, y: -200)), CGPoint(x: 400, y: 300))
    }

    func testCentringClampsTheScale() {
        XCTAssertEqual(Viewport.centred(on: .zero, scale: 100, screenSize: CGSize(width: 10, height: 10)).scale, Viewport.maxScale)
    }

    func testBoundingRectEnclosesEveryRect() {
        let rects = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 100, y: -20, width: 5, height: 5)]

        XCTAssertEqual(Viewport.boundingRect(of: rects), CGRect(x: 0, y: -20, width: 105, height: 30))
        XCTAssertNil(Viewport.boundingRect(of: []))
    }

    func testLayerBoundsShowLaidOutPositionsWhereTheCurrentViewportWantsThem() {
        let laidOut = Viewport(origin: CGPoint(x: 100, y: 50), scale: 0.5)
        let current = Viewport(origin: CGPoint(x: 130, y: 20), scale: 1.25)
        let frame = CGSize(width: 1000, height: 800)
        let bounds = current.layerBounds(laidOutFor: laidOut, frameSize: frame)

        let canvasPoint = CGPoint(x: 400, y: 300)
        let laidOutPoint = laidOut.screenPoint(fromCanvas: canvasPoint)
        // AppKit maps a point in the layer's bounds to (point - bounds.origin) * frame / bounds.
        let shown = CGPoint(
            x: (laidOutPoint.x - bounds.minX) * frame.width / bounds.width,
            y: (laidOutPoint.y - bounds.minY) * frame.height / bounds.height
        )
        assertEqual(shown, current.screenPoint(fromCanvas: canvasPoint), accuracy: 1e-9)
    }

    func testLayerBoundsAreTheFrameWhenNothingMoved() {
        let viewport = Viewport(origin: CGPoint(x: 3, y: 4), scale: 0.7)

        XCTAssertEqual(viewport.layerBounds(laidOutFor: viewport, frameSize: CGSize(width: 300, height: 200)), CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    func testInterpolationStartsAndEndsAtTheEndpoints() {
        let screen = CGSize(width: 800, height: 600)
        let from = Viewport(origin: CGPoint(x: 10, y: 20), scale: 0.5)
        let to = Viewport(origin: CGPoint(x: -300, y: 90), scale: 3)

        assertEqual(Viewport.interpolated(from: from, to: to, progress: 0, screenSize: screen), from)
        assertEqual(Viewport.interpolated(from: from, to: to, progress: 1, screenSize: screen), to)
    }

    func testInterpolationScalesGeometricallyAndMovesTheCentreInAStraightLine() {
        let screen = CGSize(width: 800, height: 600)
        let from = Viewport.centred(on: CGPoint(x: 0, y: 0), scale: 1, screenSize: screen)
        let to = Viewport.centred(on: CGPoint(x: 1000, y: 400), scale: 4, screenSize: screen)

        let halfway = Viewport.interpolated(from: from, to: to, progress: 0.5, screenSize: screen)

        XCTAssertEqual(halfway.scale, 2, accuracy: 1e-9)
        assertEqual(halfway.canvasPoint(fromScreen: CGPoint(x: 400, y: 300)), CGPoint(x: 500, y: 200))
    }

    private func assertEqual(_ a: Viewport, _ b: Viewport, file: StaticString = #filePath, line: UInt = #line) {
        assertEqual(a.origin, b.origin, file: file, line: line)
        XCTAssertEqual(a.scale, b.scale, accuracy: 1e-9, file: file, line: line)
    }

    private func assertEqual(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }
}
