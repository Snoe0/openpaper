import XCTest

@MainActor
final class RuntimeAppearanceTests: XCTestCase {
    private let swatch = #"<div id="d" style="color: var(--c)">x</div>"#
    private let swatchColor = "return getComputedStyle(document.getElementById('d')).color"

    func testSetTokensReplacesTheTokenStylesheet() async throws {
        let page = try await RuntimePage.open(body: swatch, tokens: ":root { --c: rgb(0, 0, 0) }")

        try await page.js("Canvas.setTokens(':root { --c: rgb(10, 20, 30) }')")

        let color = try await page.string(swatchColor)
        let styleCount = try await page.double("return document.querySelectorAll('#canvas-tokens').length")
        XCTAssertEqual(color, "rgb(10, 20, 30)")
        XCTAssertEqual(styleCount, 1)
    }

    func testSetTokensCreatesTheTokenStylesheetWhenMissing() async throws {
        let page = try await RuntimePage.open(body: swatch)
        try await page.js("document.getElementById('canvas-tokens').remove()")

        try await page.js("Canvas.setTokens(':root { --c: rgb(40, 50, 60) }')")

        let color = try await page.string(swatchColor)
        let inHead = try await page.bool("return document.head.querySelector('style#canvas-tokens') !== null")
        XCTAssertEqual(color, "rgb(40, 50, 60)")
        XCTAssertTrue(inHead)
    }

    func testSetModeSwitchesModeScopedTokens() async throws {
        let page = try await RuntimePage.open(
            body: swatch,
            tokens: #":root { --c: rgb(255, 255, 255) } [data-mode="dark"] { --c: rgb(0, 0, 0) }"#
        )

        try await page.js("Canvas.setMode('dark')")

        let mode = try await page.string("return document.documentElement.dataset.mode")
        let color = try await page.string(swatchColor)
        XCTAssertEqual(mode, "dark")
        XCTAssertEqual(color, "rgb(0, 0, 0)")
    }
}
