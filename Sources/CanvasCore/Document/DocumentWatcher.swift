import CoreServices
import Foundation

/// Reports file-level changes inside a folder through FSEvents, on the main queue, as paths relative
/// to that folder. `needsRescan` is set when FSEvents dropped or coalesced events, so the receiver
/// must re-check everything. The stream starts at init and stops when the watcher is released.
/// Unchecked Sendable: its state is fixed after init, and events are only handled on the main queue.
final class DocumentWatcher: @unchecked Sendable {
    @MainActor var onEvents: (@MainActor (_ paths: [String], _ needsRescan: Bool) -> Void)?

    private let rootPath: String
    private let stream: FSEventStreamRef?

    private static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
    )

    init(folder: URL) {
        rootPath = Self.realPath(of: folder)
        let box = WatcherBox()
        stream = Self.makeStream(watching: rootPath, box: box)
        box.watcher = self
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)  // releases the box through the context's release callback
    }

    @MainActor
    fileprivate func deliver(_ absolutePaths: [String], needsRescan: Bool) {
        let prefix = rootPath + "/"
        let relativePaths = absolutePaths.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        guard !relativePaths.isEmpty || needsRescan else { return }
        onEvents?(relativePaths, needsRescan)
    }

    /// The stream retains the box, and the box only weakly points at the watcher, so a late
    /// callback can never reach a freed watcher.
    private static func makeStream(watching path: String, box: WatcherBox) -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<WatcherBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<WatcherBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        return FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard let info else { return }
                let box = Unmanaged<WatcherBox>.fromOpaque(info).takeUnretainedValue()
                let absolutePaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                let needsRescan = (0..<count).contains { flags[$0] & DocumentWatcher.rescanFlags != 0 }
                MainActor.assumeIsolated { box.watcher?.deliver(absolutePaths, needsRescan: needsRescan) }
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )
    }

    /// FSEvents reports fully resolved paths (e.g. `/private/var/...`), so match against the resolved folder.
    private static func realPath(of url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Unchecked Sendable: only touched on the main queue (and by the stream's retain/release).
private final class WatcherBox: @unchecked Sendable {
    weak var watcher: DocumentWatcher?
}
