import Foundation
import WebKit

/// URLs served by `DocumentSchemeHandler`: `canvas://doc/<path>` for document files and
/// `canvas://doc/__artboard__<id>.html` for an assembled artboard page. Artboard pages sit at the
/// document root, so their relative URLs resolve against the document folder.
public enum CanvasURL {
    public static let scheme = "canvas"
    static let root = URL(string: "\(scheme)://doc/")!
    private static let artboardPrefix = "__artboard__"
    private static let artboardSuffix = ".html"

    public static func artboard(_ id: String) -> URL {
        file(artboardPrefix + id + artboardSuffix)
    }

    public static func file(_ relativePath: String) -> URL {
        let encoded = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
        return URL(string: encoded, relativeTo: root)!.absoluteURL
    }

    /// "__artboard__hero.html" → "hero"; nil for any other path.
    static func artboardID(inPath path: String) -> String? {
        guard path.hasPrefix(artboardPrefix), path.hasSuffix(artboardSuffix),
              path.count > artboardPrefix.count + artboardSuffix.count else { return nil }
        return String(path.dropFirst(artboardPrefix.count).dropLast(artboardSuffix.count))
    }
}

/// Serves a document to WKWebViews over the `canvas` scheme. Artboard pages are assembled on the main
/// actor; files are read off the main thread, with `Range` support for media. Unknown paths, hidden
/// paths and paths outside the folder get a 404. A task stopped by WebKit is never answered.
@MainActor
public final class DocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    private let document: CanvasDocument
    private var activeTasks: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    public init(document: CanvasDocument) {
        self.document = document
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return urlSchemeTask.didFailWithError(URLError(.badURL)) }
        let path = String(url.path(percentEncoded: false).drop { $0 == "/" })
        if let id = CanvasURL.artboardID(inPath: path) {
            return send(artboardReply(id: id), to: urlSchemeTask, url: url)
        }
        guard let file = Self.servableFile(atPath: path, in: document.url) else {
            return send(.notFound, to: urlSchemeTask, url: url)
        }
        let range = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
        serve(file, mimeType: Self.mimeType(forPath: path), range: range, to: urlSchemeTask, url: url)
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        activeTasks[ObjectIdentifier(urlSchemeTask)] = nil
    }

    // MARK: - Replies

    private func artboardReply(id: String) -> SchemeReply {
        guard let board = try? document.artboard(id: id),
              let html = try? ArtboardPage.html(for: board, in: document) else { return .notFound }
        return SchemeReply(mimeType: "text/html", body: Data(html.utf8))
    }

    /// Reads the file in the background, then answers only if WebKit hasn't stopped the task meanwhile.
    /// The identity check matters: a new task can reuse a stopped task's address, and so its key.
    private func serve(_ file: URL, mimeType: String, range: String?, to task: any WKURLSchemeTask, url: URL) {
        let key = ObjectIdentifier(task)
        activeTasks[key] = task
        Task {
            let reply = await FileReader.reply(for: file, mimeType: mimeType, range: range)
            guard activeTasks[key] === task else { return }
            activeTasks[key] = nil
            send(reply, to: task, url: url)
        }
    }

    private func send(_ reply: SchemeReply, to task: any WKURLSchemeTask, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        task.didReceive(response)
        task.didReceive(reply.body)
        task.didFinish()
    }

    // MARK: - Files

    /// The file to serve for a path, or nil for hidden paths (any `.segment`) and paths outside the document.
    nonisolated static func servableFile(atPath path: String, in root: URL) -> URL? {
        guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        return DocumentPath.resolve(path, in: root)
    }

    nonisolated static func mimeType(forPath path: String) -> String {
        mimeTypes[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }

    private nonisolated static let mimeTypes = [
        "html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
        "json": "application/json", "txt": "text/plain", "wasm": "application/wasm",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "avif": "image/avif", "svg": "image/svg+xml", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "mp4": "video/mp4", "webm": "video/webm", "mov": "video/quicktime", "mp3": "audio/mpeg",
    ]
}

struct SchemeReply: Sendable {
    var status = 200
    var headers: [String: String]
    var body: Data

    init(status: Int = 200, mimeType: String, body: Data, headers extra: [String: String] = [:]) {
        self.status = status
        self.body = body
        headers = ["Content-Type": mimeType, "Content-Length": String(body.count), "Cache-Control": "no-store"]
            .merging(extra) { _, new in new }
    }

    static let notFound = SchemeReply(status: 404, mimeType: "text/plain", body: Data("Not found".utf8))
}

/// Reads document files on a utility queue, honoring `Range: bytes=a-b` and `bytes=a-`.
/// A partial response carries at most `maxPartialLength` bytes; RFC 9110 lets a server send less than asked.
enum FileReader {
    static let maxPartialLength: UInt64 = 8 * 1024 * 1024
    private static let queue = DispatchQueue(label: "local.canvas.document-files", qos: .utility, attributes: .concurrent)

    static func reply(for file: URL, mimeType: String, range: String?) async -> SchemeReply {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: read(file, mimeType: mimeType, range: range)) }
        }
    }

    private static func read(_ file: URL, mimeType: String, range header: String?) -> SchemeReply {
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: file),
              let size = try? handle.seekToEnd() else { return .notFound }
        defer { try? handle.close() }
        let acceptRanges = ["Accept-Ranges": "bytes"]
        guard let requested = header.flatMap(byteRange) else {
            guard (try? handle.seek(toOffset: 0)) != nil, let body = try? handle.readToEnd() ?? Data() else { return .notFound }
            return SchemeReply(mimeType: mimeType, body: body, headers: acceptRanges)
        }
        let end = min(requested.end ?? size &- 1, size &- 1, requested.start &+ maxPartialLength &- 1)
        guard requested.start < size, requested.start <= end else {
            return SchemeReply(status: 416, mimeType: "text/plain", body: Data(), headers: ["Content-Range": "bytes */\(size)"])
        }
        guard (try? handle.seek(toOffset: requested.start)) != nil,
              let body = try? handle.read(upToCount: Int(end - requested.start + 1)) else { return .notFound }
        return SchemeReply(
            status: 206, mimeType: mimeType, body: body,
            headers: acceptRanges.merging(["Content-Range": "bytes \(requested.start)-\(end)/\(size)"]) { _, new in new }
        )
    }

    /// "bytes=10-19" → (10, 19); "bytes=10-" → (10, nil). Other forms are ignored (the whole file is sent).
    private static func byteRange(_ header: String) -> (start: UInt64, end: UInt64?)? {
        guard let match = header.wholeMatch(of: /\s*bytes=(\d+)-(\d*)\s*/),
              let start = UInt64(match.output.1) else { return nil }
        if match.output.2.isEmpty { return (start, nil) }
        guard let end = UInt64(match.output.2) else { return nil }
        return (start, end)
    }
}
