import XCTest
@testable import CanvasCore

/// `Canvas.settled()`: what an off-screen snapshot waits for before it takes its picture.
@MainActor
final class RuntimeSettledTests: XCTestCase {
    private let keyframes = """
    <style>
      @keyframes fade-in { from { opacity: 0; } to { opacity: 1; } }
      @keyframes spin { to { transform: rotate(1turn); } }
    </style>
    """

    func testWaitsForAFadeInToFinish() async throws {
        let page = try await RuntimePage.open(body: keyframes)

        let result = try await page.js("""
            const box = document.createElement('div')
            box.style.animation = 'fade-in 1s linear'
            document.body.append(box)
            const start = performance.now()
            await Canvas.settled()
            return { elapsed: performance.now() - start, opacity: getComputedStyle(box).opacity }
        """) as? [String: Any]

        let elapsed = try XCTUnwrap((result?["elapsed"] as? NSNumber)?.doubleValue)
        XCTAssertGreaterThanOrEqual(elapsed, 900)
        XCTAssertEqual(result?["opacity"] as? String, "1")
    }

    func testWaitsForATransitionToFinish() async throws {
        let page = try await RuntimePage.open(body: """
            <style>#box { opacity: 0; transition: opacity 1s linear; } #box.shown { opacity: 1; }</style>
            <div id="box"></div>
            """)

        let elapsed = try await page.double("""
            requestAnimationFrame(() => document.getElementById('box').classList.add('shown'))
            \(settledDuration)
        """)

        XCTAssertGreaterThanOrEqual(elapsed, 900)
    }

    func testWaitsForAnAnimationThatStartsWhenAnotherEnds() async throws {
        let page = try await RuntimePage.open(body: keyframes)

        let elapsed = try await page.double("""
            const box = document.createElement('div')
            box.style.animation = 'fade-in 1s linear'
            box.addEventListener('animationend', () => { box.style.animation = 'spin 1s linear' }, { once: true })
            document.body.append(box)
            \(settledDuration)
        """)

        XCTAssertGreaterThanOrEqual(elapsed, 1800)
    }

    func testIgnoresAnimationsThatLoopForever() async throws {
        let page = try await RuntimePage.open(body: keyframes + #"<div style="animation: spin 1s linear infinite"></div>"#)

        let elapsed = try await page.double(settledDuration)

        XCTAssertLessThan(elapsed, 1000)
    }

    func testGivesUpOnALongAnimationAfterThreeSeconds() async throws {
        let page = try await RuntimePage.open(body: keyframes + #"<div style="animation: fade-in 10s linear"></div>"#)

        let elapsed = try await page.double(settledDuration)

        XCTAssertGreaterThanOrEqual(elapsed, 2800)
        XCTAssertLessThan(elapsed, 4500)
    }

    func testWaitsForAnimationsInsideComponents() async throws {
        let page = try await RuntimePage.open(
            body: "<x-card></x-card>",
            components: ["card": keyframes + #"<div style="animation: fade-in 1s linear"></div>"#]
        )

        let elapsed = try await page.double("""
            const card = document.querySelector('x-card').shadowRoot.querySelector('div')
            const animation = card.getAnimations()[0]
            animation.currentTime = 0
            \(settledDuration)
        """)

        XCTAssertGreaterThanOrEqual(elapsed, 900)
    }

    func testCancelledAnimationsDoNotHoldItUp() async throws {
        let page = try await RuntimePage.open(body: keyframes + #"<div id="box" style="animation: fade-in 10s linear"></div>"#)

        let elapsed = try await page.double("""
            setTimeout(() => { document.getElementById('box').style.animation = 'none' }, 100)
            \(settledDuration)
        """)

        XCTAssertLessThan(elapsed, 1000)
    }

    /// How long `Canvas.settled()` takes, in milliseconds.
    private let settledDuration = """
        const start = performance.now()
        await Canvas.settled()
        return performance.now() - start
    """
}
