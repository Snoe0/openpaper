import Foundation
import Observation

/// A `Name.canvas` folder package: the manifest, tokens, artboard and component files, and assets.
/// Every mutation is written to disk atomically and reported through `onChange`, as are outside edits to the folder.
@MainActor @Observable
public final class CanvasDocument {
    public let url: URL
    public internal(set) var manifest: Manifest
    public internal(set) var tokens: Tokens
    /// Sorted names of the components in `components/`.
    public private(set) var componentNames: [String] = []

    let files: DocumentFiles
    @ObservationIgnored var componentSources: [String: String] = [:] {
        didSet { componentNames = componentSources.keys.sorted() }
    }
    @ObservationIgnored private var changeHandlers: [(id: Int, handler: @MainActor (DocumentChange) -> Void)] = []
    @ObservationIgnored private var lastHandlerID = 0
    @ObservationIgnored private let watcher: DocumentWatcher

    /// The folder name without `.canvas`.
    public var name: String { url.deletingPathExtension().lastPathComponent }

    private init(url: URL, files: DocumentFiles, watcher: DocumentWatcher, manifest: Manifest, tokens: Tokens) {
        self.url = url
        self.files = files
        self.watcher = watcher
        self.manifest = manifest
        self.tokens = tokens
    }

    /// Creates a new document; throws `.alreadyExists` rather than overwrite anything at `url`.
    public static func create(at url: URL) throws -> CanvasDocument {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw DocumentError.alreadyExists(url.path) }
        try writeSkeleton(at: url)
        return try open(at: url)
    }

    public static func open(at url: URL) throws -> CanvasDocument {
        // Watch before loading, so an edit landing in between is still reported.
        let watcher = DocumentWatcher(folder: url)
        let files = DocumentFiles(root: url)
        let document = CanvasDocument(
            url: url,
            files: files,
            watcher: watcher,
            manifest: try decodeManifest(files.load(DocumentPath.manifest)),
            tokens: try decodeTokens(files.load(DocumentPath.tokens))
        )
        document.loadComponents()
        document.trackArtboardFiles()
        document.listenToFileEvents()
        return document
    }

    // MARK: - Change notifications

    /// Calls `handler` for every change until the returned subscription is cancelled or released.
    public func onChange(_ handler: @escaping @MainActor (DocumentChange) -> Void) -> ChangeSubscription {
        lastHandlerID += 1
        changeHandlers.append((lastHandlerID, handler))
        return ChangeSubscription(document: self, id: lastHandlerID)
    }

    func removeChangeHandler(_ id: Int) {
        changeHandlers.removeAll { $0.id == id }
    }

    func notify(_ change: DocumentChange) {
        for entry in changeHandlers { entry.handler(change) }
    }

    private func listenToFileEvents() {
        watcher.onEvents = { [weak self] paths, needsRescan in
            self?.handleFileEvents(at: paths, needsRescan: needsRescan)
        }
    }

    // MARK: - Saving

    func updateManifest(_ change: (inout Manifest) throws -> Void) throws {
        try update { manifest, _ in try change(&manifest) }
    }

    func updateTokens(_ change: (inout Tokens) throws -> Void) throws {
        try update { _, tokens in try change(&tokens) }
    }

    /// One logical change to the manifest and/or tokens. Picks up outside edits first so they
    /// aren't overwritten, validates, saves only what changed, then notifies.
    func update(_ change: (inout Manifest, inout Tokens) throws -> Void) throws {
        reloadFromDisk(.manifest)
        reloadFromDisk(.tokens)
        var newManifest = manifest
        var newTokens = tokens
        try change(&newManifest, &newTokens)
        try newManifest.validate()

        var saved: [DocumentChange] = []
        defer { saved.forEach(notify) }
        if newTokens != tokens {
            try files.write(Self.encodeJSON(newTokens), to: DocumentPath.tokens)
            tokens = newTokens
            saved.append(.tokens)
        }
        if newManifest != manifest {
            try files.write(Self.encodeJSON(newManifest), to: DocumentPath.manifest)
            manifest = newManifest
            saved.append(.manifest)
        }
    }

    // MARK: - Coding

    /// Pretty-printed with sorted keys so the files diff cleanly in git.
    static func encodeJSON<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    static func decodeManifest(_ data: Data) throws -> Manifest {
        let manifest = try decodeJSON(Manifest.self, from: data, file: DocumentPath.manifest)
        try manifest.validate()
        return manifest
    }

    static func decodeTokens(_ data: Data) throws -> Tokens {
        try decodeJSON(Tokens.self, from: data, file: DocumentPath.tokens)
    }

    private static func decodeJSON<Value: Decodable>(_ type: Value.Type, from data: Data, file: String) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DocumentError.malformed("\(file): \(error.localizedDescription)")
        }
    }
}

/// Keeps an `onChange` handler registered; cancelling or releasing it removes the handler.
@MainActor
public final class ChangeSubscription {
    private weak var document: CanvasDocument?
    private let id: Int

    init(document: CanvasDocument, id: Int) {
        self.document = document
        self.id = id
    }

    public func cancel() {
        document?.removeChangeHandler(id)
        document = nil
    }

    isolated deinit {
        cancel()
    }
}

extension Manifest {
    /// Rejects a manifest the document can't safely use: no pages, duplicate ids, artboards on unknown
    /// pages, or an artboard file outside `artboards/<id>.html`.
    func validate() throws {
        let file = DocumentPath.manifest
        guard !pages.isEmpty else { throw DocumentError.malformed("\(file): there must be at least one page") }
        let pageIDs = Set(pages.map(\.id))
        guard pageIDs.count == pages.count else { throw DocumentError.malformed("\(file): page ids must be unique") }
        var artboardIDs = Set<String>()
        for board in artboards {
            guard board.hasCanonicalFile else {
                throw DocumentError.malformed("\(file): artboard \"\(board.id)\" must have a slug id and file artboards/<id>.html")
            }
            guard artboardIDs.insert(board.id).inserted else {
                throw DocumentError.malformed("\(file): artboard id \"\(board.id)\" is used twice")
            }
            guard pageIDs.contains(board.page) else {
                throw DocumentError.malformed("\(file): artboard \"\(board.id)\" is on unknown page \"\(board.page)\"")
            }
        }
    }
}
