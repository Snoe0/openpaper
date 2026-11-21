import WebKit
import XCTest
@testable import CanvasCore

/// `board` shown at `scale`, snapped to device pixels (half points on Retina) like a board view's rect.
private func onScreen(_ board: CGSize, at scale: CGFloat) -> CGSize {
    CGSize(width: (board.width * scale * 2).rounded() / 2, height: (board.height * scale * 2).rounded() / 2)
}

/// Below 100% the page lays out at the board's size in a host scaled down to the board view (zoom would
/// trip WebKit's minimum font size); at 100% and up it's zoomed in a frame of whole points.
final class ViewportPageFitTests: XCTestCase {
    private let board = CGSize(width: 400, height: 300)

    func testAboveFullSizeTheFrameIsWholePointsAndTheZoomKeepsTheBoardWidth() {
        for scale in [1.0, 1.2537, 1.5188, 2.7] as [CGFloat] {
            let shown = onScreen(board, at: scale)
            let fit = PageFit(boardSize: board, onScreen: shown)

            XCTAssertEqual(fit.frameSize.width, shown.width.rounded(.down), "scale \(scale)")
            XCTAssertEqual(fit.boundsSize, fit.frameSize, "scale \(scale)")
            // The page's CSS viewport is exactly the board width, so width breakpoints don't flicker.
            XCTAssertEqual(fit.frameSize.width / fit.pageZoom, 400, accuracy: 1e-4, "scale \(scale)")
        }
    }

    func testBelowFullSizeTheBoundsAreTheBoardAndThePageIsNotZoomed() {
        for scale in [0.249, 0.5, 0.5615, 0.7419, 0.8787, 0.999] as [CGFloat] {
            let fit = PageFit(boardSize: board, onScreen: onScreen(board, at: scale))

            XCTAssertEqual(fit.boundsSize, board, "scale \(scale)")
            XCTAssertEqual(fit.pageZoom, 1, "scale \(scale)")
        }
    }

    /// The page covers its board view, so it lines up with the snapshot under it: as tall as the board
    /// view, under a point narrow at most (whole points at 100% and up), and exactly the board view below.
    func testTheHostCoversTheBoardOnScreen() {
        let board = CGSize(width: 390, height: 844)
        for scale in stride(from: 0.05, through: 3, by: 0.0137) {
            let shown = onScreen(board, at: scale)
            let fit = PageFit(boardSize: board, onScreen: shown)

            XCTAssertGreaterThanOrEqual(fit.frameSize.height, shown.height, "scale \(scale)")
            XCTAssertLessThan(shown.width - fit.frameSize.width, 1, "scale \(scale)")
            if shown.width < board.width { XCTAssertEqual(fit.frameSize, shown, "scale \(scale)") }
        }
    }

    /// A board view that isn't laid out yet has no size; the host keeps at least a point, so its bounds
    /// scale stays finite.
    func testAnEmptyBoardViewStillGetsAPoint() {
        let fit = PageFit(boardSize: CGSize(width: 390, height: 844), onScreen: .zero)

        XCTAssertEqual(fit.frameSize, CGSize(width: 1, height: 1))
    }

    /// WebKit keeps the zoom in single precision and truncates the layout width, so a zoom that rounds
    /// up to the next float (390-wide board at 111%: 432 / 1.1076923 = 389.99997) would lose a CSS pixel.
    func testTheViewportWebKitComputesInSinglePrecisionIsTheBoardWidth() {
        for boardWidth in [390, 375, 400, 768, 1280, 1440] as [CGFloat] {
            for scale in stride(from: 1, through: 4, by: 0.01) {
                let board = CGSize(width: boardWidth, height: 844)
                let fit = PageFit(boardSize: board, onScreen: onScreen(board, at: scale))

                let cssWidth = (Float(fit.frameSize.width) / Float(fit.pageZoom)).rounded(.down)
                XCTAssertEqual(cssWidth, Float(boardWidth), "board \(boardWidth) at scale \(scale)")
            }
        }
    }

    /// Presentation fills the stage on the board's limiting side exactly, in whole points.
    func testAPresentedBoardFillsTheStageOnItsLimitingSide() {
        let cases: [(board: CGSize, stage: CGSize, shown: CGSize)] = [
            (CGSize(width: 390, height: 844), CGSize(width: 700, height: 500), CGSize(width: 231, height: 500)),
            (CGSize(width: 155, height: 100), CGSize(width: 1512, height: 1000), CGSize(width: 1512, height: 975)),
            (CGSize(width: 1080, height: 1350), CGSize(width: 1512, height: 945), CGSize(width: 756, height: 945)),
            (CGSize(width: 390, height: 844), CGSize(width: 700.5, height: 500.5), CGSize(width: 231, height: 500)),
            (CGSize(width: 10_000, height: 10), CGSize(width: 100, height: 100), CGSize(width: 100, height: 1)),
        ]
        for (board, stage, shown) in cases {
            XCTAssertEqual(PageFit.presentedSize(of: board, in: stage), shown, "\(board) on \(stage)")
        }
    }

    func testFullSizeIsExact() {
        let board = CGSize(width: 1440, height: 900)
        let fit = PageFit(boardSize: board, onScreen: board)

        XCTAssertEqual(fit.frameSize, board)
        XCTAssertEqual(fit.boundsSize, board)
        XCTAssertEqual(fit.pageZoom, 1)
    }
}

/// A page in a `PageHost` lays out exactly as it does at 100% whatever the scale (same CSS width, same
/// text) and draws the whole board on screen.
@MainActor
final class WebViewPageFitTests: XCTestCase {
    private static let board = CGSize(width: 390, height: 844)
    /// The fit for the board shown at `scale`, as a board view would lay it out.
    private static func fit(_ scale: CGFloat) -> PageFit {
        PageFit(boardSize: board, onScreen: onScreen(board, at: scale))
    }

    private static let html = """
    <body style="margin:0"><span id="line" style="font-size:14px; white-space:nowrap">Tea ceremony, Camellia Garden</span></body>
    """

    func testAShrunkPageLaysOutAtTheBoardWidthWithItsFullSizeText() async throws {
        let fullSizePage = try await FittedPage.open(Self.html, fit: Self.fit(1))
        defer { fullSizePage.close() }
        let fullSize = try await fullSizePage.layoutOnceSettled()
        for scale in [0.56, 0.5, 0.25] as [CGFloat] {
            let page = try await FittedPage.open(Self.html, fit: Self.fit(scale))
            defer { page.close() }

            let layout = try await page.layoutOnceSettled()
            XCTAssertEqual(layout.innerWidth, 390, "innerWidth at scale \(scale)")
            XCTAssertEqual(layout.clientWidth, 390, "clientWidth at scale \(scale)")
            XCTAssertTrue(layout.matchesBoardWidth, "(min-width: 390px) and (max-width: 390px) at scale \(scale)")
            // WebKit's 9 px minimum logical font size must not grow 14px text drawn under 9 device points.
            XCTAssertEqual(layout.fontSize, fullSize.fontSize, "font size at scale \(scale)")
            XCTAssertEqual(layout.lineWidth, fullSize.lineWidth, accuracy: 0.01, "line width at scale \(scale)")
        }
    }

    func testAnEnlargedPageLaysOutAtTheBoardWidthWithItsFullSizeText() async throws {
        let page = try await FittedPage.open(Self.html, fit: Self.fit(1.7))
        defer { page.close() }

        let layout = try await page.layoutOnceSettled()
        XCTAssertEqual(layout.innerWidth, 390)
        XCTAssertEqual(layout.clientWidth, 390)
        XCTAssertTrue(layout.matchesBoardWidth)
        XCTAssertEqual(layout.fontSize, "14px")
    }

    /// The window shows the whole board: left half red, right half blue, a green strip at the bottom.
    /// (A snapshot from WebKit isn't enough: it repaints the page itself, whatever is on screen.)
    func testAShrunkPageDrawsTheWholeBoard() async throws {
        let html = """
        <body style="margin:0; height:844px; display:grid; grid-template:1fr 44px / 1fr 1fr">
        <div style="background:red"></div><div style="background:blue"></div>
        <div style="background:lime; grid-column:span 2"></div>
        <span id="line" style="position:absolute; font-size:14px">.</span></body>
        """
        let page = try await FittedPage.open(html, fit: Self.fit(0.56))
        defer { page.close() }
        _ = try await page.layoutOnceSettled()

        let image = try await page.windowImageOnceDrawn()
        XCTAssertEqual(image.color(atX: 20, y: 400), .red)
        XCTAssertEqual(image.color(atX: 370, y: 400), .blue)
        XCTAssertEqual(image.color(atX: 370, y: 830), .green)
    }

    /// Inspect mode hands clicks to the page: one at a board point lands on that CSS point and element.
    func testAClickOnAShrunkPageLandsOnThePointUnderIt() async throws {
        let html = """
        <body style="margin:0; height:844px; display:grid; grid-template:1fr 1fr / 1fr 1fr">
        <div id="a"></div><div id="b"></div><div id="c"></div><div id="d"></div>
        <span id="line" style="position:absolute; font-size:14px">.</span>
        <script>addEventListener('mousedown', (e) => { window.hit = [e.clientX, e.clientY, e.target.id] })</script></body>
        """
        let page = try await FittedPage.open(html, fit: Self.fit(0.56))
        defer { page.close() }
        _ = try await page.layoutOnceSettled()

        let hit = try await page.click(atBoardPoint: CGPoint(x: 300, y: 600))
        XCTAssertEqual(hit.element, "d")
        XCTAssertEqual(hit.point.x, 300, accuracy: 2)
        XCTAssertEqual(hit.point.y, 600, accuracy: 2)
    }

    /// Presentation shows a tall board whole on a short screen: centred, and laid out as at 100%.
    func testATallBoardPresentedOnAShortStageIsCentredWithItsFullSizeText() async throws {
        let stage = CGRect(x: 0, y: 0, width: 700, height: 500)
        let page = try await FittedPage.open(Self.html) { host, webView in
            host.fit(webView, boardSize: Self.board, centredIn: stage)
        }
        defer { page.close() }

        let layout = try await page.layoutOnceSettled()
        XCTAssertEqual(layout.clientWidth, 390)
        XCTAssertTrue(layout.matchesBoardWidth)
        XCTAssertEqual(layout.fontSize, "14px")
        let shown = page.host.frame
        XCTAssertEqual(shown.width, (390 * 500 / 844).rounded(.down))
        XCTAssertEqual(shown.height, 500)
        XCTAssertEqual(shown.midX, stage.midX, accuracy: 1)
        XCTAssertEqual(shown.midY, stage.midY, accuracy: 1)
    }

    /// WebKit's 9 px "smart minimum" grows text specified at 9px or more that zoom draws under 9 points,
    /// so it can't apply at a page zoom of 1 or more; relative-unit text under 9px stays as at 100% too.
    func testRelativeTextUnderNinePixelsJustAboveFullSizeMatchesFullSize() async throws {
        let html = """
        <body style="margin:0; font-size:16px"><span id="line" style="font-size:0.5em; white-space:nowrap">Tea ceremony, Camellia Garden</span></body>
        """
        let fullSizePage = try await FittedPage.open(html, fit: Self.fit(1))
        defer { fullSizePage.close() }
        let enlargedPage = try await FittedPage.open(html, fit: Self.fit(1.05))
        defer { enlargedPage.close() }

        let fullSize = try await fullSizePage.layoutOnceSettled()
        let enlarged = try await enlargedPage.layoutOnceSettled()
        XCTAssertEqual(enlarged.clientWidth, 390)
        XCTAssertEqual(enlarged.fontSize, fullSize.fontSize)
        XCTAssertEqual(enlarged.lineWidth, fullSize.lineWidth, accuracy: 0.01)
    }

    /// One web view in a `PageHost` in an off-screen window, like a live board. Tests close it.
    private final class FittedPage: NSObject, WKNavigationDelegate {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let host = PageHost()
        private let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 700, height: 1500), styleMask: [.borderless], backing: .buffered, defer: false)
        private var loaded: CheckedContinuation<Void, any Error>?

        struct Layout { var innerWidth: Int; var clientWidth: Int; var matchesBoardWidth: Bool; var fontSize: String; var lineWidth: Double }

        static func open(_ html: String, fit: PageFit) async throws -> FittedPage {
            try await open(html) { host, webView in host.fit(webView, to: fit) }
        }

        /// Loads `html` in a web view that `place` fits inside the host (top left of the window).
        static func open(_ html: String, place: (PageHost, WKWebView) -> Void) async throws -> FittedPage {
            let page = FittedPage()
            page.window.isReleasedWhenClosed = false
            page.window.contentView = FlippedView()  // so the host sits at the top left
            page.window.contentView?.wantsLayer = true
            page.window.contentView?.addSubview(page.host)
            page.host.addSubview(page.webView)
            disableOcclusionDetection(page.webView)
            page.window.orderFrontRegardless()
            page.webView.navigationDelegate = page
            place(page.host, page.webView)
            try await withCheckedThrowingContinuation { continuation in
                page.loaded = continuation
                page.webView.loadHTMLString(html, baseURL: nil)
            }
            return page
        }

        /// The layout once WebKit has applied the fit (it does so asynchronously), or as it stands after 3 s.
        func layoutOnceSettled() async throws -> Layout {
            let deadline = ContinuousClock.now + .seconds(3)
            var layout = try await currentLayout()
            while ContinuousClock.now < deadline, layout.clientWidth != 390 {
                try await Task.sleep(for: .milliseconds(30))
                layout = try await currentLayout()
            }
            return layout
        }

        /// Sends a mouse down at a point of the board through the window's hit-testing, and returns where
        /// the page saw it.
        func click(atBoardPoint point: CGPoint) async throws -> (point: CGPoint, element: String) {
            let inWindow = host.convert(point, to: nil)
            let content = try XCTUnwrap(window.contentView)
            // `hitTest(_:)` takes a point in the receiver's superview, like `ArtboardView.hitTest(_:)` hands on.
            let view = try XCTUnwrap(content.hitTest(content.superview?.convert(inWindow, from: nil) ?? inWindow))
            XCTAssertTrue(view.isDescendant(of: webView), "hit \(view)")
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            view.mouseDown(with: event)
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                if let hit = try await webView.callAsyncJavaScript("return window.hit ?? null", contentWorld: .page) as? [Any], hit.count == 3 {
                    let x = (hit[0] as? NSNumber)?.doubleValue ?? -1, y = (hit[1] as? NSNumber)?.doubleValue ?? -1
                    return (CGPoint(x: x, y: y), hit[2] as? String ?? "")
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw RuntimeTestError.loadTimedOut
        }

        /// The window image once the page's bottom-right corner is painted, or as it stands after 3 s.
        func windowImageOnceDrawn() async throws -> Bitmap {
            let deadline = ContinuousClock.now + .seconds(3)
            var image = try windowImage()
            while ContinuousClock.now < deadline, image.color(atX: 370, y: 830) == .other {
                try await Task.sleep(for: .milliseconds(50))
                image = try windowImage()
            }
            return image
        }

        /// The page as the window shows it, scaled to the board's width (`CGWindowListCreateImage` is
        /// hidden from the SDK but still captures one's own windows; see `DevRemote`).
        /// Skips the test where the system can't capture windows.
        func windowImage() throws -> Bitmap {
            typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { throw XCTSkip("CGWindowListCreateImage is unavailable") }
            let includingWindow: UInt32 = 1 << 3, boundsIgnoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            guard let image = create(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?.takeRetainedValue() else {
                throw XCTSkip("couldn't capture the test window")
            }
            let pixelsPerPoint = CGFloat(image.width) / window.frame.width
            let hostPixels = CGRect(origin: .zero, size: host.frame.size).applying(CGAffineTransform(scaleX: pixelsPerPoint, y: pixelsPerPoint))
            return try XCTUnwrap(image.cropping(to: hostPixels.integral).flatMap(Bitmap.init))
        }

        private func currentLayout() async throws -> Layout {
            let script = """
            return [innerWidth, document.documentElement.clientWidth, matchMedia('(min-width: 390px) and (max-width: 390px)').matches,
                    getComputedStyle(line).fontSize, line.getBoundingClientRect().width]
            """
            let result = try await webView.callAsyncJavaScript(script, contentWorld: .page)
            let values = try XCTUnwrap(result as? [Any])
            return Layout(
                innerWidth: (values[0] as? NSNumber)?.intValue ?? -1,
                clientWidth: (values[1] as? NSNumber)?.intValue ?? -1,
                matchesBoardWidth: values[2] as? Bool ?? false,
                fontSize: values[3] as? String ?? "",
                lineWidth: (values[4] as? NSNumber)?.doubleValue ?? -1
            )
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { finishLoading(with: nil) }
        }

        /// A failed load fails the test instead of leaving it waiting.
        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            MainActor.assumeIsolated { finishLoading(with: error) }
        }

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            MainActor.assumeIsolated { finishLoading(with: error) }
        }

        private func finishLoading(with error: (any Error)?) {
            if let error { loaded?.resume(throwing: error) } else { loaded?.resume() }
            loaded = nil
        }

        func close() {
            window.close()
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// An image redrawn into an RGBA buffer at its pixel size, to sample colours.
private struct Bitmap {
    enum Color { case red, green, blue, other }

    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init?(_ cgImage: CGImage) {
        let (width, height) = (cgImage.width, cgImage.height)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        (self.width, self.height, pixels) = (width, height, buffer)
    }

    /// The colour at a point given in board pixels (scaled to the image), top-left origin.
    func color(atX x: CGFloat, y: CGFloat, boardWidth: CGFloat = 390) -> Color {
        let scale = CGFloat(width) / boardWidth
        let column = min(Int(x * scale), width - 1), row = min(Int(y * scale), height - 1)
        let offset = (row * width + column) * 4
        let (r, g, b) = (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        switch (r > 200, g > 200, b > 200) {
        case (true, false, false): return .red
        case (false, true, false): return .green
        case (false, false, true): return .blue
        default: return .other
        }
    }
}
