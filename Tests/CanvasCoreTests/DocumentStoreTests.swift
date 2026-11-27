import Observation
import XCTest
@testable import CanvasCore

final class DocumentStoreTests: XCTestCase {
    // MARK: - Create / open

    @MainActor
    func testCreateWritesSkeletonPackage() throws {
        let document = try makeDocument(named: "Landing")
        let fm = FileManager.default

        for file in ["canvas.json", "tokens.json", "CLAUDE.md"] {
            XCTAssertTrue(fm.fileExists(atPath: document.url.appendingPathComponent(file).path), file)
        }
        for folder in ["artboards", "components", "assets"] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(fm.fileExists(atPath: document.url.appendingPathComponent(folder).path, isDirectory: &isDirectory), folder)
            XCTAssertTrue(isDirectory.boolValue, folder)
        }
        XCTAssertEqual(try readText("CLAUDE.md", in: document), DocumentGuide.markdown)
        XCTAssertEqual(document.name, "Landing")
        XCTAssertEqual(document.manifest.pages, [Page(id: "p1", name: "Page 1")])
        XCTAssertEqual(document.currentPage, Page(id: "p1", name: "Page 1"))
        XCTAssertEqual(document.manifest.mode, "light")
        XCTAssertEqual(document.manifest.version, 1)
        XCTAssertTrue(document.manifest.artboards.isEmpty)
        XCTAssertEqual(document.tokens.modes, ["light", "dark"])
        XCTAssertEqual(
            Set(document.tokens.tokens.keys),
            ["color.bg", "color.fg", "color.accent", "color.muted", "font.sans", "radius.md", "space.4"]
        )
        XCTAssertEqual(document.tokens.tokens["color.bg"], .perMode(["light": "#ffffff", "dark": "#0b0b0c"]))
        XCTAssertEqual(document.componentNames, [])
    }

    @MainActor
    func testOpenRoundTripsTheModel() throws {
        let created = try makeDocument()
        try created.addArtboard(name: "Hero", width: 1440, height: 900, html: "<h1>Hi</h1>")
        try created.updateArtboard(id: "hero", mode: .some("dark"))
        try created.writeComponent(name: "button", html: "<button>{{label}}</button>")
        try created.setTokens(["brand": .single("#f00")])

        let opened = try CanvasDocument.open(at: created.url)

        XCTAssertEqual(opened.manifest, created.manifest)
        XCTAssertEqual(opened.tokens, created.tokens)
        XCTAssertEqual(opened.componentNames, ["button"])
        XCTAssertEqual(try opened.html(ofArtboard: "hero"), "<h1>Hi</h1>")
    }

    @MainActor
    func testOpenMissingDocumentThrowsNotFound() throws {
        let url = try temporaryDocumentURL()
        XCTAssertThrowsError(try CanvasDocument.open(at: url)) { error in
            guard case DocumentError.notFound = error else { return XCTFail("\(error)") }
        }
    }

    @MainActor
    func testOpenRejectsArtboardFilesOutsideTheirSlot() throws {
        let created = try makeDocument()
        let escapes = [
            Artboard(id: "evil", page: "p1", name: "Evil", file: "../../secret.txt", x: 0, y: 0, width: 1, height: 1),
            Artboard(id: "../evil", page: "p1", name: "Evil", file: "artboards/../evil.html", x: 0, y: 0, width: 1, height: 1),
            Artboard(id: "hero", page: "p1", name: "Hero", file: "artboards/other.html", x: 0, y: 0, width: 1, height: 1),
        ]
        for board in escapes {
            var manifest = created.manifest
            manifest.artboards = [board]
            try writeExternally(String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self), to: "canvas.json", in: created)

            XCTAssertThrowsError(try CanvasDocument.open(at: created.url), board.file) { error in
                guard case DocumentError.malformed = error else { return XCTFail("\(error)") }
            }
        }
    }

    @MainActor
    func testSymlinkedArtboardFilePointingOutsideIsNotRead() throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 10, height: 10, html: "<p>hero</p>")
        let secret = document.url.deletingLastPathComponent().appendingPathComponent("secret.txt")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        let board = document.url.appendingPathComponent("artboards/hero.html")
        try FileManager.default.removeItem(at: board)
        try FileManager.default.createSymbolicLink(at: board, withDestinationURL: secret)

        XCTAssertThrowsError(try document.html(ofArtboard: "hero")) {
            XCTAssertEqual($0 as? DocumentError, .invalidName("artboards/hero.html"))
        }
        XCTAssertThrowsError(try ArtboardPage.html(for: document.artboard(id: "hero"), in: document))
        XCTAssertThrowsError(try document.writeHTML("x", toArtboard: "hero"))
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "secret")
    }

    @MainActor
    func testManifestIsPrettySortedAndKeepsNullMode() throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 1440, height: 900, html: "")

        let json = try readText("canvas.json", in: document)

        XCTAssertTrue(json.contains("\"mode\" : null"), json)
        XCTAssertTrue(json.contains("\"file\" : \"artboards/hero.html\""), json)
        XCTAssertTrue(json.contains("\n  \"artboards\" : ["), json)
        let keys = ["\"artboards\"", "\"currentPage\"", "\"mode\" : \"light\"", "\"pages\"", "\"version\""]
        let offsets = keys.map { json.range(of: $0)!.lowerBound }
        XCTAssertEqual(offsets, offsets.sorted())
    }

    // MARK: - Artboards

    @MainActor
    func testArtboardIDsAreUniqueSlugsOfTheName() throws {
        let document = try makeDocument()

        let ids = try ["Pricing Page", "Pricing Page", "pricing page", "  Hello, World! ", "Café", "!!!"].map {
            try document.addArtboard(name: $0, width: 100, height: 100, html: "").id
        }

        XCTAssertEqual(ids, ["pricing-page", "pricing-page-2", "pricing-page-3", "hello-world", "cafe", "artboard"])
        XCTAssertEqual(try document.artboard(id: "pricing-page-2").file, "artboards/pricing-page-2.html")
        XCTAssertEqual(try document.artboard(id: "pricing-page-2").name, "Pricing Page")
    }

    @MainActor
    func testDefaultPlacementGoesRightOfTheRightMostBoard() throws {
        let document = try makeDocument()

        let first = try document.addArtboard(name: "A", width: 1440, height: 900, html: "")
        let second = try document.addArtboard(name: "B", width: 375, height: 812, html: "")
        try document.addArtboard(name: "C", width: 300, height: 300, html: "", x: 100, y: 2000)
        let lowered = try document.addArtboard(name: "D", width: 200, height: 200, html: "", y: 40)
        let fifth = try document.addArtboard(name: "E", width: 10, height: 10, html: "")

        XCTAssertEqual([first.x, first.y], [0, 0])
        XCTAssertEqual([second.x, second.y], [1520, 0])
        XCTAssertEqual([lowered.x, lowered.y], [1975, 40])
        XCTAssertEqual([fifth.x, fifth.y], [2255, 40])
    }

    @MainActor
    func testPlacementIsPerPage() throws {
        let document = try makeDocument()
        try document.addArtboard(name: "A", width: 1440, height: 900, html: "")
        let page = try document.addPage(name: "Mobile")

        let board = try document.addArtboard(name: "M", width: 375, height: 812, html: "", page: page.id)

        XCTAssertEqual(board.page, page.id)
        XCTAssertEqual([board.x, board.y], [0, 0])
        XCTAssertEqual(document.artboards(onPage: page.id).map(\.id), ["m"])
        XCTAssertEqual(document.artboards().map(\.id), ["a"])
    }

    @MainActor
    func testAddArtboardToMissingPageThrows() throws {
        let document = try makeDocument()
        XCTAssertThrowsError(try document.addArtboard(name: "A", width: 1, height: 1, html: "", page: "nope")) {
            XCTAssertEqual($0 as? DocumentError, .notFound("nope"))
        }
    }

    @MainActor
    func testDuplicatePlacesACopyToTheRight() throws {
        let document = try makeDocument()
        let hero = try document.addArtboard(name: "Hero", width: 1440, height: 900, html: "<h1>Hi</h1>")
        try document.updateArtboard(id: hero.id, mode: .some("dark"))

        let copy = try document.duplicateArtboard(id: hero.id)

        XCTAssertEqual(copy.id, "hero-copy")
        XCTAssertEqual(copy.name, "Hero copy")
        XCTAssertEqual(copy.page, hero.page)
        XCTAssertEqual([copy.x, copy.y, copy.width, copy.height], [1520, 0, 1440, 900])
        XCTAssertEqual(copy.mode, "dark")
        XCTAssertEqual(try document.html(ofArtboard: copy.id), "<h1>Hi</h1>")
    }

    @MainActor
    func testWriteReadUpdateAndDeleteArtboard() throws {
        let document = try makeDocument()
        let hero = try document.addArtboard(name: "Hero", width: 1440, height: 900, html: "<p>a</p>")

        try document.writeHTML("<p>b</p>", toArtboard: hero.id)
        XCTAssertEqual(try document.html(ofArtboard: hero.id), "<p>b</p>")
        XCTAssertEqual(try readText("artboards/hero.html", in: document), "<p>b</p>")

        try document.updateArtboard(id: hero.id, name: "Landing", x: 10, y: 20, width: 800, height: 600, mode: .some("dark"))
        XCTAssertEqual(
            try document.artboard(id: hero.id),
            Artboard(id: "hero", page: "p1", name: "Landing", file: "artboards/hero.html", x: 10, y: 20, width: 800, height: 600, mode: "dark")
        )
        try document.updateArtboard(id: hero.id, mode: .some(nil))
        XCTAssertNil(try document.artboard(id: hero.id).mode)
        try document.updateArtboard(id: hero.id, x: 5)
        XCTAssertEqual(try document.artboard(id: hero.id).x, 5)
        XCTAssertEqual(try document.artboard(id: hero.id).name, "Landing")

        try document.deleteArtboard(id: hero.id)
        XCTAssertThrowsError(try document.artboard(id: hero.id)) { XCTAssertEqual($0 as? DocumentError, .notFound("hero")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.url.appendingPathComponent("artboards/hero.html").path))
        XCTAssertThrowsError(try document.deleteArtboard(id: hero.id))
    }

    @MainActor
    func testEditHTMLReplacesAUniqueMatch() throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 100, height: 100, html: "<h1>Hello</h1><p>x</p><p>x</p>")

        try document.editHTML(ofArtboard: "hero", replacing: "Hello", with: "Bye")
        XCTAssertEqual(try document.html(ofArtboard: "hero"), "<h1>Bye</h1><p>x</p><p>x</p>")

        XCTAssertThrowsError(try document.editHTML(ofArtboard: "hero", replacing: "Missing", with: "y")) {
            XCTAssertEqual($0 as? DocumentError, .editMatchNotFound)
        }
        XCTAssertThrowsError(try document.editHTML(ofArtboard: "hero", replacing: "<p>x</p>", with: "y")) {
            XCTAssertEqual($0 as? DocumentError, .editMatchNotUnique(count: 2))
        }
        XCTAssertThrowsError(try document.editHTML(ofArtboard: "nope", replacing: "a", with: "b")) {
            XCTAssertEqual($0 as? DocumentError, .notFound("nope"))
        }
        XCTAssertEqual(try document.html(ofArtboard: "hero"), "<h1>Bye</h1><p>x</p><p>x</p>")
    }

    // MARK: - Pages

    @MainActor
    func testPagesAddRenameSwitchAndDelete() throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Home", width: 100, height: 100, html: "")

        let mobile = try document.addPage(name: "Mobile")
        XCTAssertEqual(mobile, Page(id: "p2", name: "Mobile"))
        XCTAssertEqual(document.currentPage.id, "p1")

        try document.renamePage(id: mobile.id, to: "Phone")
        try document.switchPage(id: mobile.id)
        XCTAssertEqual(document.currentPage, Page(id: "p2", name: "Phone"))
        try document.addArtboard(name: "Small", width: 375, height: 812, html: "<p>s</p>")
        XCTAssertEqual(document.artboards().map(\.id), ["small"])

        try document.deletePage(id: mobile.id)
        XCTAssertEqual(document.manifest.pages.map(\.id), ["p1"])
        XCTAssertEqual(document.currentPage.id, "p1")
        XCTAssertEqual(document.manifest.artboards.map(\.id), ["home"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.url.appendingPathComponent("artboards/small.html").path))
        XCTAssertEqual(try document.addPage(name: "Again").id, "p2")

        let reopened = try CanvasDocument.open(at: document.url)
        XCTAssertEqual(reopened.manifest, document.manifest)
    }

    @MainActor
    func testAddPageSurfacesAFailedSave() throws {
        let document = try makeDocument()
        let folder = document.url.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }

        XCTAssertThrowsError(try document.addPage(name: "Mobile"))
        XCTAssertEqual(document.manifest.pages.map(\.id), ["p1"])
    }

    @MainActor
    func testPageErrors() throws {
        let document = try makeDocument()

        XCTAssertThrowsError(try document.deletePage(id: "p1")) { XCTAssertEqual($0 as? DocumentError, .lastPage) }
        XCTAssertThrowsError(try document.switchPage(id: "nope")) { XCTAssertEqual($0 as? DocumentError, .notFound("nope")) }
        XCTAssertThrowsError(try document.renamePage(id: "nope", to: "x")) { XCTAssertEqual($0 as? DocumentError, .notFound("nope")) }
        XCTAssertThrowsError(try document.deletePage(id: "nope")) { XCTAssertEqual($0 as? DocumentError, .notFound("nope")) }
    }

    // MARK: - Change notifications

    @MainActor
    func testInAppMutationsNotifyEverySubscriber() throws {
        let document = try makeDocument()
        let first = ChangeRecorder(observing: document)
        let second = ChangeRecorder(observing: document)

        try document.addArtboard(name: "Hero", width: 100, height: 100, html: "")
        try document.writeHTML("<p>b</p>", toArtboard: "hero")
        try document.writeComponent(name: "card", html: "<div></div>")
        try document.setTokens(["brand": .single("red")])

        let expected: [DocumentChange] = [.manifest, .artboard(id: "hero"), .component(name: "card"), .tokens]
        XCTAssertEqual(first.changes, expected)
        XCTAssertEqual(second.changes, expected)
    }

    // MARK: - Review fixes

    @MainActor
    func testCreateRefusesAnExistingFolder() throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 10, height: 10, html: "<p>keep</p>")

        XCTAssertThrowsError(try CanvasDocument.create(at: document.url)) {
            XCTAssertEqual($0 as? DocumentError, .alreadyExists(document.url.path))
        }
        XCTAssertEqual(try CanvasDocument.open(at: document.url).manifest.artboards.map(\.id), ["hero"])
    }

    @MainActor
    func testSubscriptionsStopWhenCancelledOrReleased() throws {
        let document = try makeDocument()
        var cancelledCalls = 0
        var releasedCalls = 0
        var keptCalls = 0
        let cancelled = document.onChange { _ in cancelledCalls += 1 }
        var released: ChangeSubscription? = document.onChange { _ in releasedCalls += 1 }
        let kept = document.onChange { _ in keptCalls += 1 }

        try document.addPage(name: "A")
        cancelled.cancel()
        released = nil
        try document.addPage(name: "B")

        XCTAssertNil(released)
        XCTAssertEqual([cancelledCalls, releasedCalls, keptCalls], [1, 1, 2])
        kept.cancel()
    }

    @MainActor
    func testArtboardGeometryAndModeAreValidated() throws {
        let document = try makeDocument()
        for (width, height) in [(0.0, 10.0), (10, -1), (.infinity, 10), (10, .nan)] {
            XCTAssertThrowsError(try document.addArtboard(name: "A", width: width, height: height, html: "")) {
                guard case DocumentError.invalidValue = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try document.addArtboard(name: "A", width: 10, height: 10, html: "", x: .nan)) {
            guard case DocumentError.invalidValue = $0 else { return XCTFail("\($0)") }
        }
        let board = try document.addArtboard(name: "A", width: 10, height: 10, html: "")

        for update in [{ try document.updateArtboard(id: board.id, width: 0) },
                       { try document.updateArtboard(id: board.id, y: .infinity) },
                       { try document.updateArtboard(id: board.id, mode: .some("sepia")) }] {
            XCTAssertThrowsError(try update()) {
                guard case DocumentError.invalidValue = $0 else { return XCTFail("\($0)") }
            }
        }
        try document.updateArtboard(id: board.id, mode: .some("dark"))
        XCTAssertEqual(try document.artboard(id: board.id), Artboard(id: "a", page: "p1", name: "A", file: "artboards/a.html", x: 0, y: 0, width: 10, height: 10, mode: "dark"))
    }

    @MainActor
    func testArtboardGeometryHasUpperBounds() throws {
        let document = try makeDocument()
        let (width, height, reach) = (Artboard.maxWidth, Artboard.maxHeight, Artboard.maxCoordinate)
        XCTAssertEqual(width, 16_384)
        XCTAssertEqual(height, 32_768)
        XCTAssertEqual(reach, 1_000_000)
        let board = try document.addArtboard(name: "A", width: width, height: height, html: "", x: -reach, y: reach)

        for (attempt, limit) in [({ _ = try document.addArtboard(name: "B", width: width + 1, height: 10, html: "") }, "16384"),
                                 ({ _ = try document.addArtboard(name: "B", width: 10, height: height + 1, html: "") }, "32768"),
                                 ({ _ = try document.addArtboard(name: "B", width: 10, height: 1e300, html: "") }, "32768"),
                                 ({ _ = try document.addArtboard(name: "B", width: 10, height: 10, html: "", x: reach + 1) }, "1000000"),
                                 ({ try document.updateArtboard(id: board.id, width: width + 1) }, "16384"),
                                 ({ try document.updateArtboard(id: board.id, height: height + 1) }, "32768"),
                                 ({ try document.updateArtboard(id: board.id, y: -1e300) }, "1000000")] {
            XCTAssertThrowsError(try attempt()) {
                guard case DocumentError.invalidValue(let detail) = $0 else { return XCTFail("\($0)") }
                XCTAssertTrue(detail.contains(limit), detail)
            }
        }
        XCTAssertEqual(document.manifest.artboards.map(\.id), ["a"])
    }

    func testTheGuideStatesTheGeometryLimits() {
        for limit in ["widths up to \(Int(Artboard.maxWidth)) px", "heights up to \(Int(Artboard.maxHeight)) px", "±1,000,000"] {
            XCTAssertTrue(DocumentGuide.markdown.contains(limit), limit)
        }
    }

    @MainActor
    func testGeometryErrorsPrintWholeNumbersWithoutADecimalPoint() throws {
        let document = try makeDocument()
        XCTAssertThrowsError(try document.addArtboard(name: "B", width: 20_000, height: 10, html: "")) {
            guard case DocumentError.invalidValue(let detail) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(detail.hasSuffix("not 20000"), detail)
        }
        XCTAssertThrowsError(try document.addArtboard(name: "B", width: 10, height: 10, html: "", x: -2_000_000.5)) {
            guard case DocumentError.invalidValue(let detail) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(detail.hasSuffix("not -2000000.5"), detail)
        }
    }

    @MainActor
    func testAutomaticPlacementCantGoPastTheCoordinateLimit() throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Far", width: 100, height: 100, html: "", x: Artboard.maxCoordinate - 100)

        XCTAssertThrowsError(try document.addArtboard(name: "Next", width: 100, height: 100, html: "")) {
            guard case DocumentError.invalidValue(let detail) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(detail, "no room to place it automatically (x would be 1000080, past 1000000); pass x and y")
        }
        XCTAssertThrowsError(try document.duplicateArtboard(id: "far")) {
            guard case DocumentError.invalidValue(let detail) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(detail, "no room to place it automatically (x would be 1000080, past 1000000); "
                + "make room with update_artboard, or create the copy with create_artboard and x/y")
        }
        XCTAssertEqual(document.manifest.artboards.map(\.id), ["far"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.url.appendingPathComponent("artboards/next.html").path))
    }

    @MainActor
    func testOpenRejectsOutOfRangeGeometry() throws {
        let created = try makeDocument()
        let hero = Artboard(id: "hero", page: "p1", name: "Hero", file: "artboards/hero.html", x: 0, y: 0, width: 1, height: 1)
        var huge = hero, tall = hero, zero = hero, far = hero
        huge.width = 1e300
        tall.height = 32_769
        zero.height = 0
        far.x = -2_000_000
        for (board, limit) in [(huge, "16384"), (tall, "32768"), (zero, "32768"), (far, "1000000")] {
            var manifest = created.manifest
            manifest.artboards = [board]
            try writeExternally(try manifestJSON(manifest), to: "canvas.json", in: created)

            XCTAssertThrowsError(try CanvasDocument.open(at: created.url)) {
                guard case DocumentError.malformed(let detail) = $0 else { return XCTFail("\($0)") }
                XCTAssertTrue(detail.contains("hero") && detail.contains(limit), detail)
            }
        }
    }

    @MainActor
    func testEffectiveModeFallsBackToTheDocumentMode() throws {
        let document = try makeDocument()
        let board = try document.addArtboard(name: "A", width: 10, height: 10, html: "")

        XCTAssertEqual(board.effectiveMode(in: document.manifest), "light")
        try document.updateArtboard(id: board.id, mode: .some("dark"))
        XCTAssertEqual(try document.artboard(id: board.id).effectiveMode(in: document.manifest), "dark")
    }

    @MainActor
    func testDeletePageKeepsABoardAnOutsideEditMovedOffIt() throws {
        let document = try makeDocument()
        let other = try document.addPage(name: "Other")
        try document.addArtboard(name: "Moved", width: 10, height: 10, html: "<p>keep</p>", page: other.id)
        var external = document.manifest
        external.artboards[0].page = "p1"
        try writeExternally(try manifestJSON(external), to: "canvas.json", in: document)

        try document.deletePage(id: other.id)

        XCTAssertEqual(document.manifest.artboards.map(\.id), ["moved"])
        XCTAssertEqual(try document.html(ofArtboard: "moved"), "<p>keep</p>")
    }

    @MainActor
    func testDeleteArtboardSeesABoardAnOutsideEditAdded() throws {
        let document = try makeDocument()
        var external = document.manifest
        external.artboards = [Artboard(id: "late", page: "p1", name: "Late", file: "artboards/late.html", x: 0, y: 0, width: 10, height: 10)]
        try writeExternally("<p>late</p>", to: "artboards/late.html", in: document)
        try writeExternally(try manifestJSON(external), to: "canvas.json", in: document)

        try document.deleteArtboard(id: "late")

        XCTAssertEqual(document.manifest.artboards, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.url.appendingPathComponent("artboards/late.html").path))
    }

    @MainActor
    func testOpenRejectsDuplicateIdsAndUnknownPages() throws {
        let created = try makeDocument()
        let hero = Artboard(id: "hero", page: "p1", name: "Hero", file: "artboards/hero.html", x: 0, y: 0, width: 1, height: 1)
        var orphan = hero
        orphan.page = "p9"
        for boards in [[hero, hero], [orphan]] {
            var manifest = created.manifest
            manifest.artboards = boards
            try writeExternally(try manifestJSON(manifest), to: "canvas.json", in: created)

            XCTAssertThrowsError(try CanvasDocument.open(at: created.url)) {
                guard case DocumentError.malformed = $0 else { return XCTFail("\($0)") }
            }
        }
    }

    @MainActor
    func testInAppSaveKeepsAnExternalEditNotYetSeen() throws {
        let document = try makeDocument()
        var external = document.manifest
        external.pages[0].name = "Renamed by Claude"
        try writeExternally(try manifestJSON(external), to: "canvas.json", in: document)
        try writeExternally(##"{"modes":["light","dark"],"tokens":{"brand":"#f00"}}"##, to: "tokens.json", in: document)

        try document.addPage(name: "Second")
        try document.setTokens(["accent": .single("blue")])

        let reopened = try CanvasDocument.open(at: document.url)
        XCTAssertEqual(reopened.manifest.pages.map(\.name), ["Renamed by Claude", "Second"])
        XCTAssertEqual(reopened.tokens.tokens, ["brand": .single("#f00"), "accent": .single("blue")])
        XCTAssertEqual(document.manifest, reopened.manifest)
    }

    @MainActor
    func testCurrentPageFallsBackToTheFirstPage() throws {
        let created = try makeDocument()
        var manifest = created.manifest
        manifest.currentPage = "gone"
        try writeExternally(try manifestJSON(manifest), to: "canvas.json", in: created)

        XCTAssertEqual(try CanvasDocument.open(at: created.url).currentPage, Page(id: "p1", name: "Page 1"))
    }

    @MainActor
    func testReadReportsOnlyAMissingFileAsNotFound() throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 10, height: 10, html: "")
        let file = document.url.appendingPathComponent("artboards/hero.html")

        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try document.html(ofArtboard: "hero")) { XCTAssertEqual($0 as? DocumentError, .notFound("artboards/hero.html")) }

        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertThrowsError(try document.html(ofArtboard: "hero")) { XCTAssertNil($0 as? DocumentError, "\($0)") }
    }

    func testErrorsHaveReadableDescriptions() {
        let errors: [DocumentError] = [
            .notFound("hero"), .invalidName("Bad Name"), .editMatchNotFound, .editMatchNotUnique(count: 3), .lastPage,
            .malformed("canvas.json: oops"), .alreadyExists("/x/Doc.canvas"), .invalidValue("width must be > 0"),
        ]
        for error in errors {
            let description = error.localizedDescription
            XCTAssertFalse(description.contains("DocumentError"), description)
            XCTAssertFalse(description.contains("operation couldn"), description)
        }
        XCTAssertTrue(DocumentError.editMatchNotUnique(count: 3).localizedDescription.contains("3"))
        XCTAssertTrue(DocumentError.notFound("hero").localizedDescription.contains("hero"))
    }

    @MainActor
    func testObservationTracksManifestTokensAndComponentNames() throws {
        let document = try makeDocument()

        XCTAssertTrue(try observes({ _ = document.manifest }, after: { _ = try document.addPage(name: "A") }))
        XCTAssertTrue(try observes({ _ = document.tokens }, after: { try document.setTokens(["x": .single("1")]) }))
        XCTAssertTrue(try observes({ _ = document.componentNames }, after: { try document.writeComponent(name: "card", html: "") }))
        XCTAssertFalse(try observes({ _ = document.componentNames }, after: { try document.setTokens(["y": .single("2")]) }))
    }

    @MainActor
    private func observes(_ read: () -> Void, after change: () throws -> Void) rethrows -> Bool {
        let fired = ObservationFlag()
        withObservationTracking(read) { fired.set() }
        try change()
        return fired.value
    }
}
