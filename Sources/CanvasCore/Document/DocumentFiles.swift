import CryptoKit
import Foundation

/// Relative paths inside a `Name.canvas` folder.
enum DocumentPath {
    static let manifest = "canvas.json"
    static let tokens = "tokens.json"
    static let guide = "CLAUDE.md"
    static let artboards = "artboards"
    static let components = "components"
    static let assets = "assets"

    static func artboard(_ id: String) -> String { "\(artboards)/\(id).html" }
    static func component(_ name: String) -> String { "\(components)/\(name).html" }

    /// The file for a document-relative path, or nil if it resolves (through `..` or symlinks) outside the document folder.
    static func resolve(_ path: String, in root: URL) -> URL? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }
}

/// Reads and writes files in the document folder, which no path may leave. It remembers what this
/// document itself wrote of each file (and what was there at open), so file events caused by our own
/// writes can be told apart from outside edits. Later reads are not remembered: an outside edit that
/// is read before its file event arrives must still be reported.
@MainActor
final class DocumentFiles {
    enum Contents: Equatable {
        case missing
        case present(Data)
    }

    let root: URL
    private var fingerprints: [String: Fingerprint] = [:]

    init(root: URL) {
        self.root = root
    }

    /// The file for a document-relative path; throws `.invalidName` if it resolves outside the folder.
    func url(_ path: String) throws -> URL {
        guard let file = DocumentPath.resolve(path, in: root) else { throw DocumentError.invalidName(path) }
        return file
    }

    /// Throws `.notFound` for a missing file; any other read error is rethrown as is.
    func read(_ path: String) throws -> Data {
        let file = try url(path)
        do {
            return try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            throw DocumentError.notFound(path)
        }
    }

    func readText(_ path: String) throws -> String {
        String(decoding: try read(path), as: UTF8.self)
    }

    /// Reads a file while opening the document, remembering it as the known state.
    func load(_ path: String) throws -> Data {
        let data = try read(path)
        remember(.present(data), at: path)
        return data
    }

    /// Remembers what is on disk now for a file the document hasn't seen yet.
    func track(_ path: String) {
        guard fingerprints[path] == nil, let file = try? url(path) else { return }
        remember(contents(of: file), at: path)
    }

    func write(_ data: Data, to path: String) throws {
        let target = try url(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        remember(.present(data), at: path)
    }

    func write(_ text: String, to path: String) throws {
        try write(Data(text.utf8), to: path)
    }

    func remove(_ path: String) throws {
        let target = try url(path)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        remember(.missing, at: path)
    }

    func createFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    func fileNames(in folder: String) -> [String] {
        guard let directory = try? url(folder) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// What is on disk now, or nil when it matches the remembered state.
    /// A missing file this document never saw (like an editor's temp file, already renamed) is no change.
    func contentsIfChanged(_ path: String) -> Contents? {
        guard let file = try? url(path) else { return nil }
        let current = contents(of: file)
        guard (fingerprints[path] ?? .missing) != Fingerprint(current) else { return nil }
        remember(current, at: path)
        return current
    }

    private func contents(of file: URL) -> Contents {
        (try? Data(contentsOf: file)).map(Contents.present) ?? .missing
    }

    private func remember(_ contents: Contents, at path: String) {
        fingerprints[path] = Fingerprint(contents)
    }
}

/// A content hash, so file contents aren't kept in memory just to compare them.
private enum Fingerprint: Equatable {
    case missing
    case digest(SHA256.Digest)

    init(_ contents: DocumentFiles.Contents) {
        switch contents {
        case .missing: self = .missing
        case .present(let data): self = .digest(SHA256.hash(data: data))
        }
    }
}
