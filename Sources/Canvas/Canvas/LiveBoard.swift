import AppKit
import CanvasCore
import UniformTypeIdentifiers
import WebKit

/// One artboard page in a web view: loads it, talks to its runtime, reports its messages, and
/// renders it to a PNG. Changes to what the page shows (reloads, hot-patches) are chained, so a
/// snapshot can wait for them to land.
@MainActor
final class LiveBoard: NSObject {
    /// The largest board (16384×32768) takes WebKit up to ~3 s to snapshot even when it is plain, so
    /// this leaves room for real content.
    static let snapshotTimeout: Duration = .seconds(10)
    /// How long a hot-patch may take before the changes queued after it go ahead anyway.
    static let patchTimeout: Duration = .seconds(5)

    let artboardID: String
    let webView: ArtboardWebView
    /// The page finished loading (images and fonts included).
    private(set) var isLoaded = false
    /// The runtime announced itself, so `window.Canvas` calls work.
    private(set) var isReady = false
    /// The snapshot-then-pause step in flight, if any; the id tells overlapping suspensions apart.
    var suspension: (id: UUID, task: Task<Void, Never>)?
    /// Receives every runtime message as `(board, body)`.
    var onMessage: ((LiveBoard, [String: Any]) -> Void)?
    var onLoad: ((LiveBoard) -> Void)?
    var onCrash: ((LiveBoard) -> Void)?

    private var loadWaiters: [CheckedContinuation<Bool, Never>] = []
    private var pendingChange: Task<Void, Never>?

    init(artboardID: String, schemeHandler: DocumentSchemeHandler, receivesMessages: Bool = true) {
        self.artboardID = artboardID
        webView = ArtboardWebViewFactory.makeWebView(schemeHandler: schemeHandler)
        super.init()
        webView.navigationDelegate = self
        if receivesMessages { ArtboardWebViewFactory.deliverMessages(of: webView, to: self) }
    }

    func load() {
        isLoaded = false
        isReady = false
        webView.load(URLRequest(url: CanvasURL.artboard(artboardID)))
    }

    /// Lays the page out at 100%, at the board's size in canvas points (off-screen renders). On
    /// screen, a `PageHost` fits pages to their board views at any scale.
    func layout(size: CGSize) {
        webView.frame = CGRect(origin: .zero, size: size)
        webView.pageZoom = 1
    }

    /// Runs a control script (pause, resume, inspect) without waiting; nothing happens before the runtime is ready.
    func evaluate(_ script: String, arguments: [String: Any] = [:]) {
        guard isReady else { return }
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { _ in }
    }

    /// Runs a script that changes what the page shows (new tokens, components or mode); snapshots wait
    /// for it, but no longer than `patchTimeout`, so a hung page can't hold up the changes behind it.
    /// Only for a ready page: one still loading may have fetched the old document and needs a reload.
    func patch(_ script: String, arguments: [String: Any] = [:]) {
        change { [webView] in
            try? await withTimeout(Self.patchTimeout) {
                await withCheckedContinuation { continuation in
                    webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { _ in continuation.resume() }
                }
            }
        }
    }

    /// Runs `work` after the changes already queued; `waitForChanges()` waits for all of them.
    func change(_ work: @escaping @MainActor () async -> Void) {
        let previous = pendingChange
        pendingChange = Task {
            await previous?.value
            await work()
        }
    }

    func waitForChanges() async {
        while let task = pendingChange {
            await task.value
            if pendingChange == task { pendingChange = nil }
        }
    }

    /// Waits until the page has loaded, or `timeout` passes; returns whether it loaded.
    @discardableResult
    func waitUntilLoaded(timeout: Duration = .seconds(20)) async -> Bool {
        guard !isLoaded else { return true }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finishWaiting()
        }
        let loaded = await withCheckedContinuation { loadWaiters.append($0) }
        timer.cancel()
        return loaded
    }

    /// A PNG of the page, freshly rendered by WebKit: at its native size (1 pixel per CSS pixel), or
    /// smaller for a huge board (`SnapshotSize`). Draw it at the board's size, not its pixel size.
    /// Throws `SnapshotError.timedOut` if WebKit doesn't answer within `snapshotTimeout`.
    func pngSnapshot(nativeSize: CGSize) async throws -> Data {
        let size = SnapshotSize(nativeSize: nativeSize, backingScale: backingScale)
        let configuration = size.configuration(of: webView.bounds)
        return try await withTimeout(Self.snapshotTimeout) { [webView] in
            try PNGEncoder.png(of: try await webView.takeSnapshot(configuration: configuration), pixelSize: size.pixelSize)
        }
    }

    /// The scale WebKit draws snapshots at: its window's screen's.
    private var backingScale: CGFloat {
        webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// The page as it looks now, or nil if it hasn't loaded, isn't in a window (WebKit wouldn't paint
    /// it) or the snapshot fails.
    func currentLook(nativeSize: CGSize) async -> Data? {
        guard isLoaded, webView.window != nil else { return nil }
        return try? await pngSnapshot(nativeSize: nativeSize)
    }

    private func finishWaiting() {
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume(returning: isLoaded) }
    }
}

extension LiveBoard: WKNavigationDelegate {
    /// Keeps the page on its board (`NavigationPolicy`); a clicked web link opens in the browser. Every
    /// board web view (canvas, presentation, snapshots) is a `LiveBoard`, so they all follow it.
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let policy = NavigationPolicy.decide(
            url: action.request.url, targetIsMainFrame: action.targetFrame?.isMainFrame,
            boardURL: CanvasURL.artboard(artboardID), isUserClick: isUserClick(action)
        )
        if policy == .openExternally, let url = action.request.url { NSWorkspace.shared.open(url) }
        decisionHandler(policy == .allow ? .allow : .cancel)
    }

    /// A script's `a.click()` is a link activation too; only a real click on a page that takes the pointer counts.
    private func isUserClick(_ action: WKNavigationAction) -> Bool {
        NavigationPolicy.isUserClick(
            isLinkActivation: action.navigationType == .linkActivated,
            mouseButton: action.buttonNumber, viewAcceptsMouse: webView.acceptsMouse
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        finishWaiting()
        onLoad?(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if !isOurOwnCancel(error) { finishWaiting() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if !isOurOwnCancel(error) { finishWaiting() }
    }

    /// WebKit's "frame load interrupted" (WebKitErrorDomain 102; the named constants are deprecated): a
    /// navigation the policy above cancelled, which says nothing about the board's own page loading.
    private func isOurOwnCancel(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == "WebKitErrorDomain" && error.code == 102
    }

    /// The owner decides whether a crashed page comes back; the page itself never reloads.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        isReady = false
        finishWaiting()
        onCrash?(self)
    }
}

extension LiveBoard: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "ready" { isReady = true }
        onMessage?(self, body)
    }
}

enum SnapshotError: Error {
    case encodingFailed
    case timedOut
    case loadFailed
}

/// Runs `work`, failing with `SnapshotError.timedOut` after `limit`. WebKit can leave a call
/// unanswered (a snapshot in a covered window, a script on a hung page), so the work is abandoned
/// rather than cancelled; when the work wins, the timer is cancelled.
@MainActor
func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withCheckedThrowingContinuation { continuation in
        race.continuation = continuation
        let timer = Task {
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            race.finish(.failure(SnapshotError.timedOut))
        }
        Task {
            do { race.finish(.success(try await work())) } catch { race.finish(.failure(error)) }
            timer.cancel()
        }
    }
}

/// Resumes its continuation once, with whichever result comes first.
@MainActor
private final class TimeoutRace<T: Sendable> {
    var continuation: CheckedContinuation<T, any Error>?

    func finish(_ result: Result<T, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Draws an image into an sRGB bitmap of an exact pixel size and encodes it as PNG.
enum PNGEncoder {
    @MainActor
    static func png(of image: NSImage, pixelSize: CGSize) throws -> Data {
        let width = max(Int(pixelSize.width.rounded()), 1)
        let height = max(Int(pixelSize.height.rounded()), 1)
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw SnapshotError.encodingFailed }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard let output = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotError.encodingFailed
        }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { throw SnapshotError.encodingFailed }
        return data as Data
    }
}
