import Foundation

/// The recently opened documents, most recent first, kept in user defaults. Documents that no
/// longer exist on disk are left out.
public struct RecentDocuments {
    public static let defaultKey = "recentDocuments"

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int
    private let fileExists: @Sendable (String) -> Bool

    public init(
        defaults: UserDefaults = .standard,
        key: String = RecentDocuments.defaultKey,
        limit: Int = 10,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
        self.fileExists = fileExists
    }

    public var urls: [URL] {
        existingPaths().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Moves the document to the front.
    public func add(_ url: URL) {
        let path = DocumentLocation.key(for: url)
        save([path] + existingPaths().filter { $0 != path })
    }

    public func remove(_ url: URL) {
        let path = DocumentLocation.key(for: url)
        save(existingPaths().filter { $0 != path })
    }

    private func existingPaths() -> [String] {
        (defaults.stringArray(forKey: key) ?? []).filter(fileExists)
    }

    private func save(_ paths: [String]) {
        defaults.set(Array(paths.prefix(limit)), forKey: key)
    }
}

/// How the app names and recognises `.canvas` document folders.
public enum DocumentLocation {
    public static let fileExtension = "canvas"

    /// One spelling per document folder, so the same document opened through different paths
    /// (a trailing slash, `..`, a symlink) is recognised as the same tab or recent entry.
    public static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// `url` with the `.canvas` extension added when it's missing.
    public static func canvasFolder(_ url: URL) -> URL {
        isCanvasFolder(url) ? url : url.appendingPathExtension(fileExtension)
    }

    public static func isCanvasFolder(_ url: URL) -> Bool {
        url.pathExtension == fileExtension
    }
}
