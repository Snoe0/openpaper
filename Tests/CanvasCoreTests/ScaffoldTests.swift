import WebKit
import XCTest
@testable import CanvasCore

final class ScaffoldTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(CanvasCore.version, "0.1.0")
    }

    func testPlaceholderResourceLoadsFromFrameworkBundle() throws {
        let byIdentifier = try XCTUnwrap(Bundle(identifier: "local.canvas.core"))
        XCTAssertEqual(byIdentifier.bundleURL, CanvasCore.bundle.bundleURL)

        let url = try XCTUnwrap(CanvasCore.bundle.url(forResource: "placeholder", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "canvas-core-resource")
    }

    @MainActor
    func testWebViewEvaluatesJavaScriptWithoutHostApp() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        try await loadHTML( "<p id=x>hi</p>", into: webView)

        let text = try await webView.evaluateJavaScript("document.getElementById('x').textContent")
        XCTAssertEqual(text as? String, "hi")
    }
}

// MARK: - Helpers

@MainActor
private func loadHTML(_ html: String, into webView: WKWebView) async throws {
    let waiter = NavigationWaiter()
    webView.navigationDelegate = waiter
    webView.loadHTMLString(html, baseURL: nil)
    try await waiter.waitForFinish()
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func waitForFinish() async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume(with: .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resume(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
