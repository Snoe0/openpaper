import Foundation

/// `bridge.json`: how `canvas-mcp` finds the running app. Readable by the owner only, since it holds the token.
struct BridgeFile: Codable, Equatable {
    var port: UInt16
    var token: String
    var pid: Int32

    /// `~/Library/Application Support/Canvas/bridge.json`. canvas-mcp hard-codes the same path
    /// (`AppConnection.Settings.defaultBridgeFile`), which holds because the app isn't sandboxed.
    static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Canvas/bridge.json")
    }

    /// Writes the file with 0600 permissions, creating its folder (0700) if needed. Writes a temporary
    /// file next to it and renames it over, so readers never see a partial file and a symlink at `url`
    /// is replaced rather than followed.
    func write(to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try Self.createPrivateFile(at: temporary, contents: JSONEncoder().encode(self))
            try Self.check(rename(temporary.path, url.path))
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    /// Creates a new file only the owner can read, failing if anything already exists at `url`.
    private static func createPrivateFile(at url: URL, contents: Data) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try check(descriptor)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: contents)
        try handle.close()
    }

    private static func check(_ result: Int32) throws {
        guard result >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Removes the file only if it is still ours: another Canvas instance may have replaced it since.
    static func remove(at url: URL, ifToken token: String) {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(BridgeFile.self, from: data),
              file.token == token else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
