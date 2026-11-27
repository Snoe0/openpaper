import XCTest
@testable import CanvasCore

final class ShellRecentDocumentsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "CanvasRecentDocumentsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func recents(limit: Int = 10, existing: Set<String>? = nil) -> RecentDocuments {
        RecentDocuments(defaults: defaults, limit: limit, fileExists: { path in existing?.contains(path) ?? true })
    }

    func testAddingPutsTheMostRecentFirstWithoutDuplicates() {
        let store = recents()

        store.add(URL(fileURLWithPath: "/docs/A.canvas"))
        store.add(URL(fileURLWithPath: "/docs/B.canvas"))
        store.add(URL(fileURLWithPath: "/docs/A.canvas/"))

        XCTAssertEqual(store.urls.map(\.path), ["/docs/A.canvas", "/docs/B.canvas"])
    }

    func testRecentsPersistAcrossInstances() {
        recents().add(URL(fileURLWithPath: "/docs/A.canvas"))

        XCTAssertEqual(recents().urls.map(\.path), ["/docs/A.canvas"])
    }

    func testMissingDocumentsAreDropped() {
        let store = recents(existing: ["/docs/B.canvas"])

        store.add(URL(fileURLWithPath: "/docs/A.canvas"))
        store.add(URL(fileURLWithPath: "/docs/B.canvas"))

        XCTAssertEqual(store.urls.map(\.path), ["/docs/B.canvas"])
    }

    func testOnlyTheMostRecentDocumentsAreKept() {
        let store = recents(limit: 2)

        for name in ["A", "B", "C"] { store.add(URL(fileURLWithPath: "/docs/\(name).canvas")) }

        XCTAssertEqual(store.urls.map(\.path), ["/docs/C.canvas", "/docs/B.canvas"])
    }

    func testRemoveForgetsADocument() {
        let store = recents()
        store.add(URL(fileURLWithPath: "/docs/A.canvas"))
        store.add(URL(fileURLWithPath: "/docs/B.canvas"))

        store.remove(URL(fileURLWithPath: "/docs/A.canvas"))

        XCTAssertEqual(store.urls.map(\.path), ["/docs/B.canvas"])
    }

    func testTheDefaultExistenceCheckLooksAtTheDisk() throws {
        let folder = try temporaryDocumentURL()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = RecentDocuments(defaults: defaults)

        store.add(folder)
        store.add(URL(fileURLWithPath: "/no/such/Missing.canvas"))

        XCTAssertEqual(store.urls.map(DocumentLocation.key), [DocumentLocation.key(for: folder)])
    }
}

final class ShellDocumentLocationTests: XCTestCase {
    func testKeysIgnoreTrailingSlashesAndDotSegments() {
        XCTAssertEqual(DocumentLocation.key(for: URL(fileURLWithPath: "/docs/A.canvas/")), "/docs/A.canvas")
        XCTAssertEqual(DocumentLocation.key(for: URL(fileURLWithPath: "/docs/x/../A.canvas")), "/docs/A.canvas")
    }

    func testKeysResolveSymlinks() throws {
        let folder = try temporaryDocumentURL()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.deletingLastPathComponent().appendingPathComponent("Link.canvas")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        XCTAssertEqual(DocumentLocation.key(for: link), DocumentLocation.key(for: folder))
    }

    func testCanvasFolderAddsTheExtensionOnlyWhenMissing() {
        XCTAssertEqual(DocumentLocation.canvasFolder(URL(fileURLWithPath: "/docs/Site")).path, "/docs/Site.canvas")
        XCTAssertEqual(DocumentLocation.canvasFolder(URL(fileURLWithPath: "/docs/Site.canvas")).path, "/docs/Site.canvas")
    }

    func testOnlyCanvasFoldersCount() {
        XCTAssertTrue(DocumentLocation.isCanvasFolder(URL(fileURLWithPath: "/docs/Site.canvas")))
        XCTAssertFalse(DocumentLocation.isCanvasFolder(URL(fileURLWithPath: "/docs/Site")))
    }
}
