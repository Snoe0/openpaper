import Foundation

extension CanvasDocument {
    /// Picks up an outside edit: reloads what changed and notifies, unless the file still
    /// matches what this document last read or wrote. Malformed JSON keeps the last good model.
    public func reloadFromDisk(_ change: DocumentChange) {
        switch change {
        case .manifest: reloadManifest()
        case .tokens: reloadTokens()
        case .artboard(let id): reloadArtboard(id)
        case .component(let name): reloadComponent(name)
        case .asset(let path): reloadAsset(path)
        }
    }

    /// Called by the watcher with paths relative to the document folder. When FSEvents dropped
    /// events (`needsRescan`), everything is re-checked instead.
    func handleFileEvents(at paths: [String], needsRescan: Bool) {
        guard !needsRescan else { return reloadEverything() }
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted {
            if let change = change(forFileAt: path) { reloadFromDisk(change) }
        }
    }

    /// Reloads the manifest and tokens (always reported, since events were lost), then every
    /// component and artboard that changed.
    private func reloadEverything() {
        refreshManifest()
        refreshTokens()
        notify(.manifest)
        notify(.tokens)
        let namesOnDisk = files.fileNames(in: DocumentPath.components).compactMap(ComponentTemplate.name(ofFile:))
        for name in Set(componentNames + namesOnDisk).sorted() { reloadComponent(name) }
        for board in manifest.artboards { reloadArtboard(board.id) }
    }

    /// Which part of the document a file belongs to; nil for files the document doesn't track.
    func change(forFileAt path: String) -> DocumentChange? {
        let parts = path.split(separator: "/").map(String.init)
        guard let fileName = parts.last, !Self.isScratchFile(fileName) else { return nil }
        if path == DocumentPath.manifest { return .manifest }
        if path == DocumentPath.tokens { return .tokens }
        if let board = manifest.artboards.first(where: { $0.file == path }) { return .artboard(id: board.id) }
        if parts.count == 2, parts[0] == DocumentPath.components, let name = ComponentTemplate.name(ofFile: fileName) {
            return .component(name: name)
        }
        if parts.count > 1, parts[0] == DocumentPath.assets { return .asset(path: path) }
        return nil
    }

    private func reloadManifest() {
        if refreshManifest() { notify(.manifest) }
    }

    private func reloadTokens() {
        if refreshTokens() { notify(.tokens) }
    }

    /// Takes a changed, valid `canvas.json` into the model; returns whether it did.
    @discardableResult
    private func refreshManifest() -> Bool {
        guard let data = changedFile(DocumentPath.manifest), let reloaded = try? Self.decodeManifest(data) else { return false }
        manifest = reloaded
        trackArtboardFiles()
        return true
    }

    /// Takes a changed, valid `tokens.json` into the model; returns whether it did.
    @discardableResult
    private func refreshTokens() -> Bool {
        guard let data = changedFile(DocumentPath.tokens), let reloaded = try? Self.decodeTokens(data) else { return false }
        tokens = reloaded
        return true
    }

    private func reloadArtboard(_ id: String) {
        guard let board = try? artboard(id: id), files.contentsIfChanged(board.file) != nil else { return }
        notify(.artboard(id: id))
    }

    private func reloadComponent(_ name: String) {
        switch files.contentsIfChanged(DocumentPath.component(name)) {
        case nil:
            return
        case .missing:
            guard componentSources.removeValue(forKey: name) != nil else { return }
        case .present(let data):
            componentSources[name] = String(decoding: data, as: UTF8.self)
        }
        notify(.component(name: name))
    }

    /// Assets aren't fingerprinted (they can be large): every create, modify or delete event is reported,
    /// once per batch.
    private func reloadAsset(_ path: String) {
        notify(.asset(path: path))
    }

    /// Hidden files and editor/atomic-write temp files (`name.sb-XXXX-YYYY`, `name~`, `.tmp`, `.swp`).
    private static func isScratchFile(_ name: String) -> Bool {
        name.hasPrefix(".") || name.contains(".sb-") || name.hasSuffix("~")
            || name.hasSuffix(".tmp") || name.hasSuffix(".swp")
    }

    /// The file's new data, or nil when it is missing or unchanged.
    private func changedFile(_ path: String) -> Data? {
        guard case .present(let data) = files.contentsIfChanged(path) else { return nil }
        return data
    }
}
