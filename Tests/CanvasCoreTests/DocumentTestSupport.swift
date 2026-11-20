import WebKit
import XCTest
@testable import CanvasCore

extension XCTestCase {
    /// A fresh, not-yet-existing `Name.canvas` URL inside its own temp folder, removed after the test.
    func temporaryDocumentURL(named name: String = "Test") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("\(name).canvas", isDirectory: true)
    }

    @MainActor
    func makeDocument(named name: String = "Test") throws -> CanvasDocument {
        try CanvasDocument.create(at: temporaryDocumentURL(named: name))
    }
}

@MainActor
func manifestJSON(_ manifest: Manifest) throws -> String {
    String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
}

@MainActor
func readText(_ relativePath: String, in document: CanvasDocument) throws -> String {
    try String(contentsOf: document.url.appendingPathComponent(relativePath), encoding: .utf8)
}

/// Writes a file the way an outside editor would (not through the document).
@MainActor
func writeExternally(_ text: String, to relativePath: String, in document: CanvasDocument) throws {
    try Data(text.utf8).write(to: document.url.appendingPathComponent(relativePath), options: .atomic)
}

/// Polls `condition` until it holds or `timeout` passes, letting the main queue run in between.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Collects every change a document reports.
@MainActor
final class ChangeRecorder {
    private(set) var changes: [DocumentChange] = []
    private var subscription: ChangeSubscription?

    init(observing document: CanvasDocument) {
        subscription = document.onChange { [weak self] change in self?.changes.append(change) }
    }

    func reset() {
        changes = []
    }

    func count(of change: DocumentChange) -> Int {
        changes.filter { $0 == change }.count
    }
}

/// A web view that serves the `canvas:` scheme from a document.
@MainActor
final class DocumentWebView {
    let webView: WKWebView
    private let handler: DocumentSchemeHandler

    init(document: CanvasDocument) {
        handler = DocumentSchemeHandler(document: document)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: CanvasURL.scheme)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    }

    func open(_ url: URL) async throws {
        let waiter = DocumentNavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: url))
        try await waiter.waitForFinish()
    }

    func js(_ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }
}

@MainActor
private final class DocumentNavigationWaiter: NSObject, WKNavigationDelegate {
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

/// Set from `withObservationTracking`'s (Sendable) change callback.
final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    var value: Bool { lock.withLock { fired } }

    func set() {
        lock.withLock { fired = true }
    }
}

/// Records what a scheme handler sends for one request.
@MainActor
final class FakeSchemeTask: NSObject, @preconcurrency WKURLSchemeTask {
    let request: URLRequest
    private(set) var status: Int?
    private(set) var responseCount = 0
    private(set) var body = Data()
    private(set) var finished = false

    init(url: URL) {
        request = URLRequest(url: url)
    }

    func didReceive(_ response: URLResponse) {
        status = (response as? HTTPURLResponse)?.statusCode
        responseCount += 1
    }

    func didReceive(_ data: Data) {
        body.append(data)
    }

    func didFinish() {
        finished = true
    }

    func didFailWithError(_ error: any Error) {
        finished = true
    }
}
