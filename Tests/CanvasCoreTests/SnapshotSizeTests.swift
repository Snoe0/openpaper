import WebKit
import XCTest
@testable import CanvasCore

final class SnapshotSizeTests: XCTestCase {
    private let largestBoard = CGSize(width: 16384, height: 32768)
    /// Mirror of `LiveBoard.snapshotTimeout` (app target, not importable).
    private let snapshotTimeout: Duration = .seconds(10)

    func testSmallBoardsKeepOnePixelPerCSSPixelAndTodaysSnapshotWidth() {
        for backing: CGFloat in [1, 2, 3] {
            let size = SnapshotSize(nativeSize: CGSize(width: 1440, height: 900), backingScale: backing)

            XCTAssertEqual(size.pixelSize, CGSize(width: 1440, height: 900))
            XCTAssertEqual(size.snapshotWidth, 1440)
        }
    }

    func testAOnePixelBoardStaysOnePixel() {
        let size = SnapshotSize(nativeSize: CGSize(width: 1, height: 1), backingScale: 2)

        XCTAssertEqual(size.pixelSize, CGSize(width: 1, height: 1))
        XCTAssertEqual(size.snapshotWidth, 1)
    }

    func testABoardExactlyAtThePixelCapIsNotScaled() {
        let size = SnapshotSize(nativeSize: CGSize(width: 4096, height: 8192), backingScale: 2)

        XCTAssertEqual(size.pixelSize, CGSize(width: 4096, height: 8192))
        XCTAssertEqual(size.snapshotWidth, 4096)
    }

    func testHugeBoardsComeOutAtTheCapWithTheirAspectRatio() {
        let expected: [(CGSize, CGSize)] = [
            (largestBoard, CGSize(width: 4096, height: 8192)),
            (CGSize(width: 8192, height: 16384), CGSize(width: 4096, height: 8192)),
            (CGSize(width: 4096, height: 32768), CGSize(width: 2048, height: 16384)),
            (CGSize(width: 16384, height: 16384), CGSize(width: 5792, height: 5792)),
        ]
        for (native, pixels) in expected {
            XCTAssertEqual(SnapshotSize(nativeSize: native, backingScale: 2).pixelSize, pixels, "\(native)")
        }
    }

    func testABoardJustOverTheCapShrinksUnderIt() {
        let size = SnapshotSize(nativeSize: CGSize(width: 4097, height: 8192), backingScale: 2)

        XCTAssertLessThanOrEqual(area(size.pixelSize), SnapshotSize.maxPixels)
        XCTAssertLessThan(size.pixelSize.width, 4097)
        XCTAssertEqual(size.pixelSize.width / size.pixelSize.height, 4097 / 8192, accuracy: 1 / 8192)
    }

    func testNoBoardExceedsThePixelCapOrDistortsItsAspectRatio() {
        for native in allowedBoardSizes() {
            let pixels = SnapshotSize(nativeSize: native, backingScale: 2).pixelSize

            XCTAssertLessThanOrEqual(area(pixels), SnapshotSize.maxPixels, "\(native)")
            XCTAssertLessThanOrEqual(pixels.width, native.width, "\(native)")
            XCTAssertLessThanOrEqual(pixels.height, native.height, "\(native)")
            XCTAssertEqual(pixels.width / native.width, pixels.height / native.height, accuracy: 1 / min(pixels.width, pixels.height), "\(native)")
        }
    }

    func testWebKitNeverRendersMoreThanTheDevicePixelBudget() {
        for backing: CGFloat in [1, 2, 3] {
            for native in allowedBoardSizes() {
                let size = SnapshotSize(nativeSize: native, backingScale: backing)

                XCTAssertLessThanOrEqual(devicePixels(size, native: native, backing: backing), SnapshotSize.maxDevicePixels * 1.001, "\(native) @\(backing)x")
            }
        }
    }

    func testTheBudgetStaysWellUnderWhereWebKitFails() {
        // Measured: above ~400M device pixels WebKit returns a transparent image or WKError 1.
        XCTAssertLessThanOrEqual(SnapshotSize.maxDevicePixels, 150_000_000)
    }

    func testCappedBoardsRenderAtTheirOutputSizeOnARetinaScreen() {
        let size = SnapshotSize(nativeSize: largestBoard, backingScale: 2)

        XCTAssertEqual(size.snapshotWidth, size.pixelSize.width)
    }

    func testCappedBoardsRenderSmallerOnATripleScaleScreen() {
        let size = SnapshotSize(nativeSize: largestBoard, backingScale: 3)

        XCTAssertLessThan(size.snapshotWidth, size.pixelSize.width)
        XCTAssertEqual(size.pixelSize, CGSize(width: 4096, height: 8192))
    }

    // MARK: - WebKit

    /// On a 1x host WebKit draws a quarter of the device pixels it would at 2x, so this then checks
    /// the content but not that the 2x budget stays under WebKit's limit.
    @MainActor
    func testHugeBoardsSnapshotWithContentTopToBottom() async throws {
        for native in [largestBoard, CGSize(width: 8192, height: 16384), CGSize(width: 4096, height: 32768), CGSize(width: 1440, height: 900)] {
            let page = try await BandedPage.open(size: native)
            if page.backingScale < 2 { print("SnapshotSizeTests: \(page.backingScale)x host; the 2x device-pixel budget isn't exercised") }
            let size = SnapshotSize(nativeSize: native, backingScale: page.backingScale)

            // Only `takeSnapshot` is timed: the app's timeout races it, and the synchronous encode can't trip it.
            let start = ContinuousClock.now
            let image = try await page.webView.takeSnapshot(configuration: size.configuration(of: page.webView.bounds))
            let elapsed = ContinuousClock.now - start
            let source = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = try XCTUnwrap(Bitmap(source, pixelSize: size.pixelSize))

            print("SnapshotSizeTests: \(native) took \(elapsed) for a \(source.width)x\(source.height) image")
            if native == largestBoard {
                XCTAssertLessThan(elapsed, snapshotTimeout)
            }
            XCTAssertGreaterThanOrEqual(source.width, Int(size.pixelSize.width), "WebKit drew at least the PNG's resolution: \(native)")
            XCTAssertGreaterThanOrEqual(source.height, Int(size.pixelSize.height), "WebKit drew at least the PNG's resolution: \(native)")
            for (row, colors) in BandedPage.colors.enumerated() {
                for (column, color) in colors.enumerated() {
                    XCTAssertEqual(bitmap.cellCenter(row: row, column: column), color, "\(native) row \(row) column \(column)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func area(_ size: CGSize) -> CGFloat { size.width * size.height }

    /// What WebKit draws: `snapshotWidth` points across at the screen's scale, at the board's aspect ratio.
    private func devicePixels(_ size: SnapshotSize, native: CGSize, backing: CGFloat) -> CGFloat {
        let width = size.snapshotWidth * backing
        return width * width * native.height / native.width
    }

    private func allowedBoardSizes() -> [CGSize] {
        let edges: [CGFloat] = [1, 100, 1440, 4096, 4097, 6000, 8192, 12345, 16384, 32768]
        return edges.flatMap { width in edges.filter { _ in width <= 16384 }.map { CGSize(width: width, height: $0) } }
    }
}

/// A page of the board's size in a grid of solid colours, four rows by two columns.
@MainActor
private final class BandedPage {
    static let colors: [[RGBA]] = [
        [RGBA(255, 0, 0), RGBA(0, 255, 0)],
        [RGBA(0, 0, 255), RGBA(255, 255, 0)],
        [RGBA(255, 0, 255), RGBA(0, 255, 255)],
        [RGBA(136, 0, 0), RGBA(0, 136, 0)],
    ]

    let webView: WKWebView
    private let window: NSWindow
    private let navigation = PageNavigationWatcher()

    var backingScale: CGFloat { window.backingScaleFactor }

    private init(size: CGSize) {
        webView = WKWebView(frame: CGRect(origin: .zero, size: size))
        window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        disableOcclusionDetection(webView)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(webView)
        window.orderFrontRegardless()
        webView.navigationDelegate = navigation
    }

    static func open(size: CGSize) async throws -> BandedPage {
        let page = BandedPage(size: size)
        let cells = colors.joined().map { "<div style='background:rgb(\($0.r),\($0.g),\($0.b))'></div>" }.joined()
        let html = """
            <html style='margin:0'><body style='margin:0;width:\(Int(size.width))px;height:\(Int(size.height))px;\
            display:grid;grid-template:repeat(4,1fr)/repeat(2,1fr)'>\(cells)</body></html>
            """
        page.webView.loadHTMLString(html, baseURL: nil)
        try await page.navigation.waitForFinish()
        return page
    }

    isolated deinit {
        window.close()
    }
}

private struct RGBA: Equatable, CustomStringConvertible {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }
    var description: String { "rgba(\(r),\(g),\(b),\(a))" }
}

/// An image drawn into an sRGB bitmap of an exact pixel size, as `PNGEncoder` does.
private struct Bitmap {
    let width: Int, height: Int
    private let pixels: [UInt8]

    init?(_ source: CGImage, pixelSize: CGSize) {
        let (width, height) = (Int(pixelSize.width), Int(pixelSize.height))
        guard let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        (self.width, self.height) = (width, height)
        pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    /// The pixel at the centre of a cell of the 4×2 grid; row 0 is the top.
    func cellCenter(row: Int, column: Int) -> RGBA {
        let x = width * (2 * column + 1) / 4
        let y = height * (2 * row + 1) / 8
        let i = (y * width + x) * 4
        return RGBA(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }
}
