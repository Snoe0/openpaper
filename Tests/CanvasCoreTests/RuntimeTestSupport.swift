import WebKit
import XCTest
@testable import CanvasCore

/// A WKWebView loaded with an artboard-like page that inlines `runtime.js`,
/// recording every message the runtime posts to the `canvas` handler.
@MainActor
final class RuntimePage {
    let webView: WKWebView
    let recorder = MessageRecorder()
    private let navigation = PageNavigationWatcher()
    private let window: NSWindow

    private init(installsMessageHandler: Bool) {
        let configuration = WKWebViewConfiguration()
        if installsMessageHandler { configuration.userContentController.add(recorder, name: "canvas") }
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.navigationDelegate = navigation
        window = RuntimePage.visibleWindow(showing: webView)
    }

    /// Loads a page shaped like the one Swift assembles: tokens, runtime, components, then the body.
    /// `preamble` runs before the runtime; `inlinesRuntime: false` leaves the runtime out of the head.
    static func open(
        body: String,
        components: [String: String] = [:],
        tokens: String = "",
        head: String = "",
        preamble: String = "",
        inlinesRuntime: Bool = true,
        installsMessageHandler: Bool = true
    ) async throws -> RuntimePage {
        let page = RuntimePage(installsMessageHandler: installsMessageHandler)
        let runtime = inlinesRuntime ? try runtimeScript() : ""
        let html = try pageHTML(body: body, components: components, tokens: tokens, head: head, preamble: preamble, runtime: runtime)
        try await page.loadPage(html)
        return page
    }

    /// Runs `body` as an async JS function in the page world and returns its result.
    @discardableResult
    func js(_ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    func double(_ body: String) async throws -> Double {
        let value = try await js(body)
        return try XCTUnwrap((value as? NSNumber)?.doubleValue, "not a number: \(String(describing: value))")
    }

    func string(_ body: String) async throws -> String? {
        try await js(body) as? String
    }

    func bool(_ body: String) async throws -> Bool {
        try await js(body) as? Bool ?? false
    }

    /// Polls a JS boolean expression until it is true or the timeout passes (returns as soon as it holds).
    func waitUntil(_ condition: String, timeout: Duration = .seconds(10)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await bool("return Boolean(\(condition))") { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Waits for the first posted message of the given type.
    func message(ofType type: String, timeout: Duration = .seconds(10)) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = messages(ofType: type).first { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RuntimeTestError.noMessage(type)
    }

    func messages(ofType type: String) -> [[String: Any]] {
        recorder.messages.filter { $0["type"] as? String == type }
    }

    /// Dispatches a composed mouse (or `PointerEvent`) event at the centre of the element `elementJS` evaluates to.
    func dispatchMouse(_ type: String, on elementJS: String, eventClass: String = "MouseEvent") async throws {
        try await js("""
            const element = \(elementJS)
            const rect = element.getBoundingClientRect()
            const init = { bubbles: true, cancelable: true, composed: true, clientX: rect.x + rect.width / 2, clientY: rect.y + rect.height / 2 }
            element.dispatchEvent(new \(eventClass)('\(type)', init))
        """)
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    private func loadPage(_ html: String) async throws {
        // A real origin, like the app's canvas://doc/, so inline-script errors aren't muted to "Script error.".
        webView.loadHTMLString(html, baseURL: URL(string: "https://canvas.test/"))
        try await navigation.waitForFinish()
    }

    /// Hosts the view in an off-screen window that WebKit treats as visible.
    private static func visibleWindow(showing webView: WKWebView) -> NSWindow {
        disableOcclusionDetection(webView)
        let window = NSWindow(
            contentRect: webView.frame.offsetBy(dx: -20_000, dy: -20_000),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        return window
    }

    deinit {
        MainActor.assumeIsolated { window.close() }
    }
}

/// WebKit only ticks animation frames and paints for visible pages, and the test runner's windows
/// report as occluded, so switch off occlusion detection (WebKit SPI, when there is one).
@MainActor
func disableOcclusionDetection(_ webView: WKWebView) {
    guard webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) else { return }
    // KVC resolves `_set<Key>:` and unboxes the Bool for the BOOL parameter.
    webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
}

enum RuntimeTestError: Error {
    case missingRuntime
    case noMessage(String)
    case loadTimedOut
    case webContentTerminated
}

/// A silent 8 kHz, 8-bit mono WAV of the given length, as a data URL.
func silentWAVDataURL(seconds: Double = 1) -> String {
    let sampleCount = Int(8000 * seconds)
    var data = Data("RIFF".utf8)
    data.append(littleEndian: UInt32(36 + sampleCount))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    data.append(littleEndian: UInt32(16))
    data.append(littleEndian: UInt16(1))
    data.append(littleEndian: UInt16(1))
    data.append(littleEndian: UInt32(8000))
    data.append(littleEndian: UInt32(8000))
    data.append(littleEndian: UInt16(1))
    data.append(littleEndian: UInt16(8))
    data.append(contentsOf: Array("data".utf8))
    data.append(littleEndian: UInt32(sampleCount))
    data.append(Data(repeating: 128, count: sampleCount))
    return "data:audio/wav;base64," + data.base64EncodedString()
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

func runtimeSource() throws -> String {
    guard let url = CanvasCore.bundle.url(forResource: "runtime", withExtension: "js") else {
        throw RuntimeTestError.missingRuntime
    }
    return try String(contentsOf: url, encoding: .utf8)
}

func runtimeScript() throws -> String {
    "<script id=\"canvas-runtime\">\(try runtimeSource())</script>"
}

private func pageHTML(
    body: String,
    components: [String: String],
    tokens: String,
    head: String,
    preamble: String,
    runtime: String
) throws -> String {
    let componentJSON = String(decoding: try JSONSerialization.data(withJSONObject: components), as: UTF8.self)
    return """
    <!doctype html><html data-mode="light"><head><meta charset="utf-8">
    <style id="canvas-tokens">\(tokens)</style>
    \(preamble)
    \(runtime)
    <script id="canvas-components">window.Canvas&&Canvas.defineComponents(\(componentJSON))</script>
    \(head)
    </head><body>\(body)</body></html>
    """
}

@MainActor
final class MessageRecorder: NSObject, WKScriptMessageHandler {
    private(set) var messages: [[String: Any]] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }
}

/// Waits for page loads (with a timeout) and fails the test if the web content process dies.
@MainActor
final class PageNavigationWatcher: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    /// Generous because page loads exceed 10 s when the machine is saturated (load average ~25 observed).
    func waitForFinish(timeout duration: Duration = .seconds(30)) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                try? await Task.sleep(for: duration)
                if !Task.isCancelled { self?.resume(with: .failure(RuntimeTestError.loadTimedOut)) }
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if continuation != nil {
            resume(with: .failure(RuntimeTestError.webContentTerminated))
        } else {
            XCTFail("The web content process terminated")
        }
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
        timeout?.cancel()
        timeout = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
