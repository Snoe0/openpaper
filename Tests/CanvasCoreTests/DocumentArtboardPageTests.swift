import XCTest
@testable import CanvasCore

final class DocumentArtboardPageTests: XCTestCase {
    @MainActor
    func testPageHasSizeTokensRuntimeAndBody() throws {
        let document = try makeDocument()
        let hero = try document.addArtboard(name: "Hero", width: 1440, height: 900.5, html: "<h1>Hi</h1>")

        let html = try ArtboardPage.html(for: hero, in: document)

        XCTAssertTrue(html.hasPrefix("<!doctype html><html data-mode=\"light\">"), html)
        XCTAssertFalse(html.contains("<base"), "a <base> would send #fragment links to the document root")
        XCTAssertTrue(html.contains("<style id=\"canvas-reset\">html,body{margin:0;padding:0}html{width:1440px;height:900.5px;overflow:hidden}</style>"))
        XCTAssertTrue(html.contains("<style id=\"canvas-tokens\">\(TokenCompiler.css(for: document.tokens))</style>"))
        XCTAssertTrue(html.contains("<script id=\"canvas-runtime\">\(RuntimeScript.source)</script>"))
        XCTAssertTrue(html.contains("<script id=\"canvas-components\">window.Canvas&&Canvas.defineComponents({})</script>"))
        XCTAssertTrue(html.hasSuffix("<body><h1>Hi</h1></body></html>"))
    }

    @MainActor
    func testPagePartsComeInLoadOrder() throws {
        let document = try makeDocument()
        let hero = try document.addArtboard(name: "Hero", width: 10, height: 10, html: "<h1>Body</h1>")

        let html = try ArtboardPage.html(for: hero, in: document)

        let parts = [
            "<!doctype html>", "<meta charset=\"utf-8\">", "<style id=\"canvas-reset\">",
            "<style id=\"canvas-tokens\">", "<script id=\"canvas-runtime\">", "<script id=\"canvas-components\">", "<h1>Body</h1>",
        ]
        let offsets = try parts.map { part in try XCTUnwrap(html.range(of: part), part).lowerBound }
        XCTAssertEqual(offsets, offsets.sorted(), html)
    }

    @MainActor
    func testArtboardModeOverridesDocumentMode() throws {
        let document = try makeDocument()
        let hero = try document.addArtboard(name: "Hero", width: 10, height: 10, html: "")
        try document.updateArtboard(id: hero.id, mode: .some("dark"))

        let html = try ArtboardPage.html(for: try document.artboard(id: hero.id), in: document)

        XCTAssertTrue(html.hasPrefix("<!doctype html><html data-mode=\"dark\">"))
    }

    @MainActor
    func testComponentsJSONIsSafelyEmbedded() throws {
        let document = try makeDocument()
        try document.writeComponent(name: "evil", html: "<script>alert(1)</script>\u{2028}\u{2029}<!--")
        let hero = try document.addArtboard(name: "Hero", width: 10, height: 10, html: "")

        let html = try ArtboardPage.html(for: hero, in: document)

        let script = try XCTUnwrap(html.components(separatedBy: "<script id=\"canvas-components\">").last)
        let embedded = try XCTUnwrap(script.components(separatedBy: "</script>").first)
        XCTAssertEqual(
            embedded,
            #"window.Canvas&&Canvas.defineComponents({"evil":"<script>alert(1)<\/script>\u2028\u2029\u003c!--"})"#
        )
    }

    func testRuntimeScriptLoadsRuntimeJSFromTheFrameworkBundle() throws {
        let url = try XCTUnwrap(CanvasCore.bundle.url(forResource: "runtime", withExtension: "js"))
        XCTAssertEqual(RuntimeScript.source, try String(contentsOf: url, encoding: .utf8))
    }

    func testCanvasURLs() {
        XCTAssertEqual(CanvasURL.scheme, "canvas")
        XCTAssertEqual(CanvasURL.artboard("hero").absoluteString, "canvas://doc/__artboard__hero.html")
        XCTAssertEqual(CanvasURL.file("assets/my photo.png").absoluteString, "canvas://doc/assets/my%20photo.png")
    }
}
