import XCTest
@testable import CanvasCore

/// External edits arrive through FSEvents, so these tests poll with a timeout.
final class DocumentWatcherTests: XCTestCase {
    @MainActor
    func testExternalArtboardWriteFiresOnce() async throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 100, height: 100, html: "<p>old</p>")
        let recorder = ChangeRecorder(observing: document)
        try await settle()

        try writeExternally("<p>new</p>", to: "artboards/hero.html", in: document)

        let fired = try await eventually { recorder.count(of: .artboard(id: "hero")) > 0 }
        XCTAssertTrue(fired)
        try await settle()
        XCTAssertEqual(recorder.changes, [.artboard(id: "hero")])
        XCTAssertEqual(try document.html(ofArtboard: "hero"), "<p>new</p>")
    }

    @MainActor
    func testInAppWriteDoesNotDoubleFire() async throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 100, height: 100, html: "<p>old</p>")
        try document.writeComponent(name: "card", html: "<div></div>")
        let recorder = ChangeRecorder(observing: document)
        try await settle()

        try document.writeHTML("<p>new</p>", toArtboard: "hero")
        try document.writeComponent(name: "card", html: "<section></section>")
        try document.setTokens(["brand": .single("red")])
        try await settle()

        XCTAssertEqual(recorder.changes, [.artboard(id: "hero"), .component(name: "card"), .tokens])
    }

    @MainActor
    func testExternalTokensEditReloadsAndFires() async throws {
        let document = try makeDocument()
        let recorder = ChangeRecorder(observing: document)
        try await settle()

        try writeExternally(##"{"modes":["light"],"tokens":{"brand":"#f00"}}"##, to: "tokens.json", in: document)

        let reloaded = try await eventually { document.tokens.tokens["brand"] == .single("#f00") }
        XCTAssertTrue(reloaded)
        XCTAssertEqual(document.tokens.modes, ["light"])
        XCTAssertEqual(recorder.changes, [.tokens])
    }

    @MainActor
    func testMalformedManifestKeepsTheLastGoodModel() async throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 100, height: 100, html: "")
        let before = document.manifest
        let recorder = ChangeRecorder(observing: document)
        try await settle()

        try writeExternally("{ \"version\": 1, oops", to: "canvas.json", in: document)
        try await settle()
        XCTAssertEqual(document.manifest, before)
        XCTAssertEqual(recorder.changes, [])

        var renamed = before
        renamed.pages[0].name = "Renamed"
        try writeExternally(String(decoding: try JSONEncoder().encode(renamed), as: UTF8.self), to: "canvas.json", in: document)
        let reloaded = try await eventually { document.currentPage.name == "Renamed" }
        XCTAssertTrue(reloaded)
        XCTAssertEqual(recorder.changes, [.manifest])
    }

    @MainActor
    func testExternalComponentAddAndRemove() async throws {
        let document = try makeDocument()
        let recorder = ChangeRecorder(observing: document)
        try await settle()

        try writeExternally("<b>{{x}}</b>", to: "components/badge.html", in: document)
        let added = try await eventually { document.componentNames == ["badge"] }
        XCTAssertTrue(added)
        XCTAssertEqual(try document.componentHTML(name: "badge"), "<b>{{x}}</b>")

        try FileManager.default.removeItem(at: document.url.appendingPathComponent("components/badge.html"))
        let removed = try await eventually { document.componentNames.isEmpty }
        XCTAssertTrue(removed)
        XCTAssertEqual(recorder.changes, [.component(name: "badge"), .component(name: "badge")])
    }

    @MainActor
    func testExternalArtboardFileWithoutManifestEntryIsIgnored() async throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 100, height: 100, html: "")
        let recorder = ChangeRecorder(observing: document)
        try await settle()

        try writeExternally("<p>orphan</p>", to: "artboards/orphan.html", in: document)
        try await settle()
        try writeExternally("<p>known</p>", to: "artboards/hero.html", in: document)

        let fired = try await eventually { !recorder.changes.isEmpty }
        XCTAssertTrue(fired)
        try await settle()
        XCTAssertEqual(recorder.changes, [.artboard(id: "hero")])
    }

    @MainActor
    func testExternalAssetFiresAssetChange() async throws {
        let document = try makeDocument()
        let recorder = ChangeRecorder(observing: document)
        try await settle()

        try writeExternally("svg", to: "assets/logo.svg", in: document)

        let fired = try await eventually { recorder.count(of: .asset(path: "assets/logo.svg")) > 0 }
        XCTAssertTrue(fired)
        try await settle()
        XCTAssertTrue(recorder.changes.allSatisfy { $0 == .asset(path: "assets/logo.svg") }, "no temp-file events: \(recorder.changes)")
    }

    @MainActor
    func testExternalEditStillFiresWhenReadBeforeTheEventArrives() async throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 100, height: 100, html: "<p>old</p>")
        let recorder = ChangeRecorder(observing: document)
        try await settle()

        try writeExternally("<p>new</p>", to: "artboards/hero.html", in: document)
        XCTAssertEqual(try document.html(ofArtboard: "hero"), "<p>new</p>")
        _ = try ArtboardPage.html(for: document.artboard(id: "hero"), in: document)

        let fired = try await eventually { recorder.count(of: .artboard(id: "hero")) > 0 }
        XCTAssertTrue(fired)
    }

    @MainActor
    func testExternalManifestWithAnEscapingArtboardFileIsRejected() async throws {
        let document = try makeDocument()
        let before = document.manifest
        let recorder = ChangeRecorder(observing: document)
        try await settle()

        var evil = before
        evil.artboards = [Artboard(id: "evil", page: "p1", name: "Evil", file: "../../secret.txt", x: 0, y: 0, width: 1, height: 1)]
        try writeExternally(String(decoding: try JSONEncoder().encode(evil), as: UTF8.self), to: "canvas.json", in: document)
        try await settle()

        XCTAssertEqual(document.manifest, before)
        XCTAssertEqual(recorder.changes, [])
    }

    @MainActor
    func testReleasedDocumentStopsWatching() async throws {
        var document: CanvasDocument? = try makeDocument()
        weak let released = document
        let url = try XCTUnwrap(document?.url)
        var calls = 0
        let subscription = document?.onChange { _ in calls += 1 }
        try await settle()

        document = nil
        XCTAssertNil(released, "the watcher must not keep the document alive")
        try Data(#"{"modes":["light"],"tokens":{}}"#.utf8).write(to: url.appendingPathComponent("tokens.json"), options: .atomic)
        try await settle()

        XCTAssertEqual(calls, 0)
        subscription?.cancel()
    }

    @MainActor
    func testExternalDeleteOfAnUnreadArtboardFileFires() async throws {
        let creator = try makeDocument()
        try creator.addArtboard(name: "Hero", width: 100, height: 100, html: "<p>hero</p>")
        let document = try CanvasDocument.open(at: creator.url)
        let recorder = ChangeRecorder(observing: document)
        try await settle()
        XCTAssertEqual(recorder.changes, [], "late events for files known at open are deduped")

        try FileManager.default.removeItem(at: document.url.appendingPathComponent("artboards/hero.html"))

        let fired = try await eventually { recorder.count(of: .artboard(id: "hero")) > 0 }
        XCTAssertTrue(fired)
    }

    @MainActor
    func testExternalAssetDeleteFires() async throws {
        let document = try makeDocument()
        try Data("png".utf8).write(to: document.url.appendingPathComponent("assets/logo.png"))
        let reopened = try CanvasDocument.open(at: document.url)
        let recorder = ChangeRecorder(observing: reopened)
        try await settle()
        recorder.reset()

        try FileManager.default.removeItem(at: reopened.url.appendingPathComponent("assets/logo.png"))

        let fired = try await eventually { recorder.count(of: .asset(path: "assets/logo.png")) > 0 }
        XCTAssertTrue(fired)
        XCTAssertTrue(recorder.changes.allSatisfy { $0 == .asset(path: "assets/logo.png") }, "\(recorder.changes)")
    }

    @MainActor
    func testExternalComponentWithAnInvalidFileNameIsIgnored() async throws {
        let document = try makeDocument()
        let recorder = ChangeRecorder(observing: document)
        try await settle()

        try writeExternally("<b></b>", to: "components/Bad_Name.html", in: document)
        try await settle()
        try writeExternally("<b></b>", to: "components/good.html", in: document)

        let fired = try await eventually { !recorder.changes.isEmpty }
        XCTAssertTrue(fired)
        try await settle()
        XCTAssertEqual(recorder.changes, [.component(name: "good")])
        XCTAssertEqual(document.componentNames, ["good"])
    }

    @MainActor
    func testAssetEventsAreUniquePerBatch() throws {
        let document = try makeDocument()
        let recorder = ChangeRecorder(observing: document)

        document.handleFileEvents(at: ["assets/a.png", "assets/a.png", "assets/b.png", "assets/a.png"], needsRescan: false)

        XCTAssertEqual(recorder.changes, [.asset(path: "assets/a.png"), .asset(path: "assets/b.png")])
    }

    @MainActor
    func testDroppedEventsTriggerAFullReload() throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Hero", width: 10, height: 10, html: "<p>old</p>")
        try document.addArtboard(name: "Same", width: 10, height: 10, html: "<p>same</p>")
        try document.writeComponent(name: "card", html: "<div></div>")
        try document.writeComponent(name: "badge", html: "<b></b>")
        let recorder = ChangeRecorder(observing: document)
        try writeExternally("<p>new</p>", to: "artboards/hero.html", in: document)
        try writeExternally("<section></section>", to: "components/card.html", in: document)
        try writeExternally("<i></i>", to: "components/new.html", in: document)
        try FileManager.default.removeItem(at: document.url.appendingPathComponent("components/badge.html"))

        document.handleFileEvents(at: [], needsRescan: true)

        XCTAssertEqual(recorder.changes.prefix(2), [.manifest, .tokens])
        XCTAssertEqual(
            Set(recorder.changes.dropFirst(2).map { "\($0)" }),
            Set([DocumentChange.artboard(id: "hero"), .component(name: "card"), .component(name: "new"), .component(name: "badge")].map { "\($0)" })
        )
        XCTAssertEqual(recorder.changes.count, 6)
        XCTAssertEqual(document.componentNames, ["card", "new"])
    }

    /// Lets pending file events arrive (or prove none do).
    @MainActor
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }
}
