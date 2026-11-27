import AppKit
import WebKit
import XCTest
@testable import CanvasCore

final class DocumentSchemeHandlerTests: XCTestCase {
    @MainActor
    func testServesTheArtboardPageWithTokens() async throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 400, height: 300, html: "<h1 id=t>Hi</h1>")
        let page = DocumentWebView(document: document)

        try await page.open(CanvasURL.artboard("hero"))

        let body = try await page.js("return document.body.innerHTML") as? String
        let background = try await page.js("return getComputedStyle(document.documentElement).getPropertyValue('--color-bg').trim()") as? String
        XCTAssertEqual(body, "<h1 id=\"t\">Hi</h1>")
        XCTAssertEqual(background, "#ffffff")
    }

    @MainActor
    func testServesAssetsWithTheirMIMEType() async throws {
        let document = try makeDocument()
        try pngData(width: 3, height: 2).write(to: document.url.appendingPathComponent("assets/dot.png"))
        try document.addArtboard(name: "Hero", width: 400, height: 300, html: "<img id=i src=\"assets/dot.png\">")
        let page = DocumentWebView(document: document)

        try await page.open(CanvasURL.artboard("hero"))

        let imageWidth = try await page.js("return document.getElementById('i').naturalWidth") as? Int
        let pngType = try await page.js("return (await fetch('assets/dot.png')).headers.get('content-type')") as? String
        let jsonType = try await page.js("return (await fetch('tokens.json')).headers.get('content-type')") as? String
        XCTAssertEqual(imageWidth, 3)
        XCTAssertEqual(pngType, "image/png")
        XCTAssertEqual(jsonType, "application/json")
    }

    @MainActor
    func testUnknownPathsAndTraversalAre404() async throws {
        let document = try makeDocument()
        try "secret".write(to: document.url.deletingLastPathComponent().appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try document.addArtboard(name: "Hero", width: 400, height: 300, html: "")
        let page = DocumentWebView(document: document)
        try await page.open(CanvasURL.artboard("hero"))

        for path in ["nope.txt", "__artboard__missing.html", "..%2Fsecret.txt", "assets/..%2F..%2Fsecret.txt", "assets"] {
            let status = try await page.js("return (await fetch('canvas://doc/\(path)')).status") as? Int
            XCTAssertEqual(status, 404, path)
        }
    }

    @MainActor
    func testFileResolutionStaysInsideTheDocument() throws {
        let root = URL(fileURLWithPath: "/tmp/Doc.canvas", isDirectory: true)

        let inside = DocumentPath.resolve("assets/a.png", in: root)?.path
        XCTAssertTrue(inside?.hasSuffix("/tmp/Doc.canvas/assets/a.png") == true, String(describing: inside))
        XCTAssertNil(DocumentPath.resolve("../secret.txt", in: root))
        XCTAssertNil(DocumentPath.resolve("assets/../../Doc.canvas2/x", in: root))
        XCTAssertNil(DocumentPath.resolve("", in: root))
    }

    func testMIMETypes() {
        let expected = [
            "a.html": "text/html", "a.css": "text/css", "a.js": "text/javascript", "a.json": "application/json",
            "a.png": "image/png", "a.JPG": "image/jpeg", "a.jpeg": "image/jpeg", "a.gif": "image/gif",
            "a.webp": "image/webp", "a.svg": "image/svg+xml", "a.woff": "font/woff", "a.woff2": "font/woff2",
            "a.ttf": "font/ttf", "a.otf": "font/otf", "a.mp4": "video/mp4", "a.webm": "video/webm",
            "a.avif": "image/avif", "a.ico": "image/x-icon", "a.mov": "video/quicktime", "a.mp3": "audio/mpeg",
            "a.wasm": "application/wasm", "a.txt": "text/plain",
            "a.bin": "application/octet-stream", "noext": "application/octet-stream",
        ]
        for (path, mime) in expected {
            XCTAssertEqual(DocumentSchemeHandler.mimeType(forPath: path), mime, path)
        }
    }

    @MainActor
    func testRelativeURLsResolveWithoutABaseTag() async throws {
        let document = try makeDocument()
        try pngData(width: 3, height: 2).write(to: document.url.appendingPathComponent("assets/dot.png"))
        try document.addArtboard(name: "Hero", width: 400, height: 300, html: "<img id=i src=\"assets/dot.png\"><a id=a href=\"#top\">top</a>")
        let page = DocumentWebView(document: document)

        try await page.open(CanvasURL.artboard("hero"))

        let imageWidth = try await page.js("return document.getElementById('i').naturalWidth") as? Int
        let anchor = try await page.js("return document.getElementById('a').href") as? String
        let baseTags = try await page.js("return document.querySelectorAll('base').length") as? Int
        XCTAssertEqual(imageWidth, 3)
        XCTAssertEqual(anchor, "canvas://doc/__artboard__hero.html#top")
        XCTAssertEqual(baseTags, 0)
    }

    @MainActor
    func testRangeRequestsReturnPartialContent() async throws {
        let document = try makeDocument()
        try Data((0..<100).map { UInt8($0) }).write(to: document.url.appendingPathComponent("assets/clip.mp4"))
        try document.addArtboard(name: "Hero", width: 10, height: 10, html: "")
        let page = DocumentWebView(document: document)
        try await page.open(CanvasURL.artboard("hero"))

        let ranged = try await page.js("""
            const r = await fetch('assets/clip.mp4', { headers: { Range: 'bytes=10-19' } });
            const bytes = new Uint8Array(await r.arrayBuffer());
            return [r.status, bytes.length, bytes[0], r.headers.get('content-range'), r.headers.get('content-length'), r.headers.get('accept-ranges')].join(',')
            """) as? String
        let openEnded = try await page.js("""
            const r = await fetch('assets/clip.mp4', { headers: { Range: 'bytes=95-' } });
            const bytes = new Uint8Array(await r.arrayBuffer());
            return [r.status, bytes.length, bytes[0], r.headers.get('content-range')].join(',')
            """) as? String
        let whole = try await page.js("""
            const r = await fetch('assets/clip.mp4');
            return [r.status, (await r.arrayBuffer()).byteLength, r.headers.get('accept-ranges')].join(',')
            """) as? String

        XCTAssertEqual(ranged, "206,10,10,bytes 10-19/100,10,bytes")
        XCTAssertEqual(openEnded, "206,5,95,bytes 95-99/100")
        XCTAssertEqual(whole, "200,100,bytes")
    }

    @MainActor
    func testHiddenPathsAndSymlinkEscapesAre404() async throws {
        let document = try makeDocument()
        let secret = document.url.deletingLastPathComponent().appendingPathComponent("secret.txt")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: document.url.appendingPathComponent("assets/link.txt"), withDestinationURL: secret)
        try "x".write(to: document.url.appendingPathComponent("assets/.hidden.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: document.url.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "x".write(to: document.url.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try "ok".write(to: document.url.appendingPathComponent("assets/ok.txt"), atomically: true, encoding: .utf8)
        try document.addArtboard(name: "Hero", width: 10, height: 10, html: "")
        let page = DocumentWebView(document: document)
        try await page.open(CanvasURL.artboard("hero"))

        for (path, status) in [("assets/link.txt", 404), ("assets/.hidden.txt", 404), (".git/config", 404), ("assets/ok.txt", 200)] {
            let result = try await page.js("return (await fetch('canvas://doc/\(path)')).status") as? Int
            XCTAssertEqual(result, status, path)
        }
    }

    @MainActor
    func testStoppedTasksAreNeverAnswered() async throws {
        let document = try makeDocument()
        try "hello".write(to: document.url.appendingPathComponent("assets/a.txt"), atomically: true, encoding: .utf8)
        let handler = DocumentSchemeHandler(document: document)
        let webView = WKWebView()
        let stopped = FakeSchemeTask(url: CanvasURL.file("assets/a.txt"))
        let answered = FakeSchemeTask(url: CanvasURL.file("assets/a.txt"))

        handler.webView(webView, start: stopped)
        handler.webView(webView, start: answered)
        handler.webView(webView, stop: stopped)

        let finished = try await eventually { answered.finished }
        XCTAssertTrue(finished)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(answered.status, 200)
        XCTAssertEqual(answered.body, Data("hello".utf8))
        XCTAssertNil(stopped.status)
        XCTAssertFalse(stopped.finished)
    }

    /// A stopped task's slot must not be answered for a new task that WebKit happens to allocate at the same address.
    @MainActor
    func testANewTaskNeverGetsAStoppedTasksReply() async throws {
        let document = try makeDocument()
        try "first".write(to: document.url.appendingPathComponent("assets/a.txt"), atomically: true, encoding: .utf8)
        try "second".write(to: document.url.appendingPathComponent("assets/b.txt"), atomically: true, encoding: .utf8)
        let handler = DocumentSchemeHandler(document: document)
        let webView = WKWebView()

        var first: FakeSchemeTask? = FakeSchemeTask(url: CanvasURL.file("assets/a.txt"))
        handler.webView(webView, start: first!)
        handler.webView(webView, stop: first!)
        first = nil
        let second = FakeSchemeTask(url: CanvasURL.file("assets/b.txt"))
        handler.webView(webView, start: second)

        let finished = try await eventually { second.finished }
        XCTAssertTrue(finished)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(String(decoding: second.body, as: UTF8.self), "second")
        XCTAssertEqual(second.responseCount, 1)
    }

    func testPartialResponsesAreCappedAt8MB() async throws {
        let file = try temporaryDocumentURL().deletingLastPathComponent().appendingPathComponent("big.mp4")
        try Data(count: 9 * 1024 * 1024).write(to: file)

        let reply = await FileReader.reply(for: file, mimeType: "video/mp4", range: "bytes=0-")

        XCTAssertEqual(reply.status, 206)
        XCTAssertEqual(reply.body.count, 8 * 1024 * 1024)
        XCTAssertEqual(reply.headers["Content-Range"], "bytes 0-8388607/9437184")
        XCTAssertEqual(reply.headers["Content-Length"], "8388608")
    }
}

private func pngData(width: Int, height: Int) throws -> Data {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
}
