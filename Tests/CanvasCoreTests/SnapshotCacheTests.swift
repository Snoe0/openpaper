import XCTest
@testable import CanvasCore

final class SnapshotCacheTests: XCTestCase {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    private let otherPNG = Data([0x89, 0x50, 0x4E, 0x47, 9, 9])

    func testKeysNameTheFileByArtboardAndContentHash() {
        XCTAssertEqual(SnapshotKey(artboardID: "hero", contentHash: "abc123").fileName, "hero-abc123.png")
    }

    func testContentHashIsStableAndChangesWithTheContent() {
        let hash = SnapshotKey.contentHash(of: "<p>Hello</p>")

        XCTAssertEqual(hash, SnapshotKey.contentHash(of: "<p>Hello</p>"))
        XCTAssertNotEqual(hash, SnapshotKey.contentHash(of: "<p>Hello!</p>"))
        XCTAssertEqual(hash.count, 16)
        XCTAssertTrue(hash.allSatisfy(\.isHexDigit))
    }

    func testDocumentFoldersAreStableAndDistinct() {
        let root = URL(fileURLWithPath: "/tmp/caches")
        let a = SnapshotCache.directory(forDocument: URL(fileURLWithPath: "/docs/A.canvas"), in: root)

        XCTAssertEqual(a, SnapshotCache.directory(forDocument: URL(fileURLWithPath: "/docs/A.canvas"), in: root))
        XCTAssertNotEqual(a, SnapshotCache.directory(forDocument: URL(fileURLWithPath: "/docs/B.canvas"), in: root))
        XCTAssertEqual(a.deletingLastPathComponent().path, root.path)
    }

    func testTheRootIsASnapshotsFolderInTheBundlesOwnCaches() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

        XCTAssertEqual(SnapshotCache.root(forBundleID: "local.canvas.e2e").path, caches.appendingPathComponent("local.canvas.e2e/Snapshots").path)
        XCTAssertEqual(SnapshotCache.root(forBundleID: nil).path, caches.appendingPathComponent("Canvas/Snapshots").path)
    }

    func testTheDefaultRootFollowsTheMainBundle() {
        XCTAssertEqual(SnapshotCache.defaultRoot, SnapshotCache.root(forBundleID: Bundle.main.bundleIdentifier))
    }

    func testStoredSnapshotsAreReturnedForTheSameKey() throws {
        let cache = SnapshotCache(directory: try temporaryFolder())
        let key = SnapshotKey(artboardID: "hero", contentHash: "h1")

        cache.store(png, for: key)

        XCTAssertEqual(cache.snapshot(for: key), png)
    }

    func testSnapshotsSurviveOnDisk() throws {
        let folder = try temporaryFolder()
        let key = SnapshotKey(artboardID: "hero", contentHash: "h1")
        SnapshotCache(directory: folder).store(png, for: key)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("hero-h1.png").path))
        XCTAssertEqual(SnapshotCache(directory: folder).snapshot(for: key), png)
    }

    func testAnEditedArtboardMissesTheCache() throws {
        let cache = SnapshotCache(directory: try temporaryFolder())
        cache.store(png, for: SnapshotKey(artboardID: "hero", contentHash: "h1"))

        XCTAssertNil(cache.snapshot(for: SnapshotKey(artboardID: "hero", contentHash: "h2")))
    }

    func testStoringANewVersionReplacesTheOldFile() throws {
        let folder = try temporaryFolder()
        let cache = SnapshotCache(directory: folder)
        cache.store(png, for: SnapshotKey(artboardID: "hero", contentHash: "h1"))
        cache.store(otherPNG, for: SnapshotKey(artboardID: "hero-2", contentHash: "h1"))

        cache.store(otherPNG, for: SnapshotKey(artboardID: "hero", contentHash: "h2"))

        XCTAssertEqual(try files(in: folder), ["hero-2-h1.png", "hero-h2.png"])
        XCTAssertNil(SnapshotCache(directory: folder).snapshot(for: SnapshotKey(artboardID: "hero", contentHash: "h1")))
    }

    func testInvalidatingRemovesTheArtboardsFiles() throws {
        let folder = try temporaryFolder()
        let cache = SnapshotCache(directory: folder)
        let key = SnapshotKey(artboardID: "hero", contentHash: "h1")
        cache.store(png, for: key)
        cache.store(png, for: SnapshotKey(artboardID: "other", contentHash: "h1"))

        cache.invalidate(artboardID: "hero")

        XCTAssertNil(cache.snapshot(for: key))
        XCTAssertEqual(try files(in: folder), ["other-h1.png"])
    }

    func testContainsChecksTheFileForTheKey() throws {
        let cache = SnapshotCache(directory: try temporaryFolder())
        let key = SnapshotKey(artboardID: "hero", contentHash: "h1")
        XCTAssertFalse(cache.contains(key))

        cache.store(png, for: key)

        XCTAssertTrue(cache.contains(key))
        XCTAssertFalse(cache.contains(SnapshotKey(artboardID: "hero", contentHash: "h2")))
    }

    func testFilesRemovedBehindTheCachesBackAreMisses() throws {
        let folder = try temporaryFolder()
        let cache = SnapshotCache(directory: folder)
        let key = SnapshotKey(artboardID: "hero", contentHash: "h1")
        cache.store(png, for: key)

        try FileManager.default.removeItem(at: folder.appendingPathComponent(key.fileName))

        XCTAssertNil(cache.snapshot(for: key))
    }

    func testPruningKeepsOnlyTheGivenArtboards() throws {
        let folder = try temporaryFolder()
        let cache = SnapshotCache(directory: folder)
        for id in ["hero", "hero-2", "gone"] { cache.store(png, for: SnapshotKey(artboardID: id, contentHash: "h1")) }

        cache.prune(keeping: ["hero", "hero-2"])

        XCTAssertEqual(try files(in: folder), ["hero-2-h1.png", "hero-h1.png"])
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotCacheTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func files(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }
}
