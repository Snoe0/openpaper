import CryptoKit
import Foundation

/// Names one rendering of an artboard. The content hash covers everything that changes the
/// pixels, so an edited artboard gets a new key and misses the cache.
public struct SnapshotKey: Hashable, Sendable {
    public var artboardID: String
    public var contentHash: String

    public init(artboardID: String, contentHash: String) {
        self.artboardID = artboardID
        self.contentHash = contentHash
    }

    public var fileName: String { "\(artboardID)-\(contentHash).png" }

    /// The first 16 hex digits of the SHA-256 of `content`.
    public static func contentHash(of content: String) -> String {
        shortHash(Data(content.utf8))
    }

    static func shortHash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// PNG snapshots of artboards on disk, one file per artboard (`<id>-<hash>.png`). There is no
/// memory tier: callers decode what they show, and reads are rare.
public final class SnapshotCache {
    private let directory: URL

    /// `~/Library/Caches/Canvas`.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Canvas", isDirectory: true)
    }

    /// `<root>/<doc-hash>`, where the hash is of the document's path.
    public static func directory(forDocument documentURL: URL, in root: URL = defaultRoot) -> URL {
        root.appendingPathComponent(SnapshotKey.shortHash(Data(documentURL.standardizedFileURL.path.utf8)), isDirectory: true)
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public func snapshot(for key: SnapshotKey) -> Data? {
        try? Data(contentsOf: fileURL(key))
    }

    public func contains(_ key: SnapshotKey) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(key).path)
    }

    /// Keeps `png` as the artboard's only snapshot, replacing any older one.
    public func store(_ png: Data, for key: SnapshotKey) {
        invalidate(artboardID: key.artboardID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: fileURL(key), options: .atomic)
    }

    public func invalidate(artboardID: String) {
        removeFiles { $0 == artboardID }
    }

    /// Removes the files of artboards not in `artboardIDs`, e.g. ones deleted while the app was closed.
    public func prune(keeping artboardIDs: Set<String>) {
        removeFiles { !artboardIDs.contains($0) }
    }

    private func fileURL(_ key: SnapshotKey) -> URL {
        directory.appendingPathComponent(key.fileName)
    }

    /// Removes the snapshot files whose artboard id matches. Hashes hold no dashes, so the id is
    /// everything before the last one.
    private func removeFiles(where matches: (String) -> Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".png") && matches(name.split(separator: "-").dropLast().joined(separator: "-")) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
