import XCTest
@testable import CanvasCore

final class DocumentTokensTests: XCTestCase {
    func testTokenCompilerEmitsRootThenOneBlockPerMode() {
        let tokens = Tokens(modes: ["light", "dark"], tokens: [
            "radius.md": .single("8px"),
            "color.bg": .perMode(["light": "#fff", "dark": "#000"]),
            "color.fg": .perMode(["light": "#111"]),
            "space 4/x": .single("16px"),
        ])

        XCTAssertEqual(TokenCompiler.css(for: tokens), """
        :root{--color-bg:#fff;--color-fg:#111;--radius-md:8px;--space-4-x:16px;}
        [data-mode="light"]{--color-bg:#fff;--color-fg:#111;}
        [data-mode="dark"]{--color-bg:#000;--color-fg:#111;}
        """)
    }

    func testTokenCompilerIsDeterministic() {
        let values = (0..<50).map { ("t\($0)", TokenValue.perMode(["a": "\($0)", "b": "x"])) }
        let tokens = Tokens(modes: ["a", "b"], tokens: Dictionary(uniqueKeysWithValues: values))

        XCTAssertEqual(TokenCompiler.css(for: tokens), TokenCompiler.css(for: Tokens(modes: ["a", "b"], tokens: Dictionary(uniqueKeysWithValues: values.reversed()))))
        XCTAssertTrue(TokenCompiler.css(for: tokens).hasPrefix(":root{--t0:0;--t1:1;--t10:10;"))
    }

    func testTokenNamesKeepDashesAndUnderscores() {
        let tokens = Tokens(modes: ["light"], tokens: ["Brand_2-x.y": .single("1")])
        XCTAssertTrue(TokenCompiler.css(for: tokens).hasPrefix(":root{--Brand_2-x-y:1;}"))
    }

    func testTokensDecodeStringsAndPerModeObjects() throws {
        let json = ##"{"modes":["light","dark"],"tokens":{"a":"1px","b":{"light":"#fff","dark":"#000"}}}"##

        let tokens = try JSONDecoder().decode(Tokens.self, from: Data(json.utf8))

        XCTAssertEqual(tokens, Tokens(modes: ["light", "dark"], tokens: ["a": .single("1px"), "b": .perMode(["light": "#fff", "dark": "#000"])]))
        let roundTripped = try JSONDecoder().decode(Tokens.self, from: JSONEncoder().encode(tokens))
        XCTAssertEqual(roundTripped, tokens)
    }

    @MainActor
    func testSetTokensMergesAndRemoveTokenDeletes() throws {
        let document = try makeDocument()

        try document.setTokens(["color.bg": .single("#123"), "brand": .perMode(["light": "red", "dark": "pink"])])
        XCTAssertEqual(document.tokens.tokens["color.bg"], .single("#123"))
        XCTAssertEqual(document.tokens.tokens["brand"], .perMode(["light": "red", "dark": "pink"]))
        XCTAssertNotNil(document.tokens.tokens["radius.md"])

        try document.removeToken("brand")
        XCTAssertNil(document.tokens.tokens["brand"])
        XCTAssertThrowsError(try document.removeToken("brand")) { XCTAssertEqual($0 as? DocumentError, .notFound("brand")) }

        XCTAssertEqual(try CanvasDocument.open(at: document.url).tokens, document.tokens)
    }

    @MainActor
    func testModes() throws {
        let document = try makeDocument()

        try document.setMode("dark")
        XCTAssertEqual(document.manifest.mode, "dark")
        XCTAssertThrowsError(try document.setMode("sepia")) { XCTAssertEqual($0 as? DocumentError, .notFound("sepia")) }

        try document.setModes(["light", "sepia"])
        XCTAssertEqual(document.tokens.modes, ["light", "sepia"])
        XCTAssertEqual(document.manifest.mode, "light", "a removed document mode falls back to the first mode")
        try document.setMode("sepia")
        XCTAssertEqual(document.manifest.mode, "sepia")

        XCTAssertThrowsError(try document.setModes([]))
        XCTAssertEqual(try CanvasDocument.open(at: document.url).manifest.mode, "sepia")
    }

    @MainActor
    func testSetModesIsOneChangeThatClearsStaleOverrides() throws {
        let document = try makeDocument()
        try document.addArtboard(name: "Dark", width: 10, height: 10, html: "")
        try document.addArtboard(name: "Light", width: 10, height: 10, html: "")
        try document.updateArtboard(id: "dark", mode: .some("dark"))
        try document.updateArtboard(id: "light", mode: .some("light"))
        try document.setMode("dark")
        let recorder = ChangeRecorder(observing: document)

        try document.setModes(["light", "sepia"])

        XCTAssertEqual(recorder.changes, [.tokens, .manifest])
        XCTAssertNil(try document.artboard(id: "dark").mode)
        XCTAssertEqual(try document.artboard(id: "light").mode, "light")
        XCTAssertEqual(document.manifest.mode, "light")
        XCTAssertEqual(try CanvasDocument.open(at: document.url).manifest, document.manifest)
    }

    @MainActor
    func testSetModesRejectsBadModeNames() throws {
        let document = try makeDocument()
        let before = document.tokens

        for modes in [["a\\"], ["light", ""], ["light", "light"], ["dark mode"], ["x\"]{}"]] {
            XCTAssertThrowsError(try document.setModes(modes), "\(modes)") {
                guard case DocumentError.invalidValue = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertEqual(document.tokens, before)
        try document.setModes(["Light_1", "high-contrast"])
        XCTAssertEqual(document.tokens.modes, ["Light_1", "high-contrast"])
    }

    @MainActor
    func testOpenRejectsTokensWithBadModeNames() throws {
        let document = try makeDocument()

        for modes in [#"["a\\"]"#, #"["light",""]"#, #"["dark","dark"]"#, "[]"] {
            try writeExternally(#"{"modes":\#(modes),"tokens":{}}"#, to: "tokens.json", in: document)

            XCTAssertThrowsError(try CanvasDocument.open(at: document.url), modes) {
                guard case DocumentError.malformed(let detail) = $0 else { return XCTFail("\($0)") }
                XCTAssertTrue(detail.contains("tokens.json"), detail)
            }
        }
    }

    @MainActor
    func testSetTokensRejectsValuesThatCouldBreakTheCSS() throws {
        let document = try makeDocument()
        let before = document.tokens

        for value: TokenValue in [.single("red;}"), .single("{"), .single("a}b"), .single("</style>"), .perMode(["light": "x", "dark": "y;"])] {
            XCTAssertThrowsError(try document.setTokens(["bad": value]), "\(value)") {
                guard case DocumentError.invalidValue = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertEqual(document.tokens, before)
        try document.setTokens(["ok": .single("rgb(0 0 0 / 50%)"), "font": .single("\"Inter\", sans-serif")])
    }
}
