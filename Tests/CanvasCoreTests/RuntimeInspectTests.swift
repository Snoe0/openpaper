import XCTest

@MainActor
final class RuntimeInspectTests: XCTestCase {
    private let article = """
    <main><p>One</p><p id="two" class="x" onclick="window.pageClicked = true">Two <b>bold</b></p></main>
    <a id="link" href="#moved">go</a>
    <div><x-button label="Hi"></x-button></div>
    """
    private let components = ["button": "<button>{{label}}</button>"]

    func testClickPostsSelectForTheElementWithoutReachingPageHandlers() async throws {
        let page = try await RuntimePage.open(body: article, components: components)
        try await page.js("Canvas.inspect(true)")

        try await page.dispatchMouse("click", on: "document.getElementById('two')")

        let select = try await page.message(ofType: "select")
        let outerHTML = try await page.string("return document.getElementById('two').outerHTML")
        let rect = try XCTUnwrap(select["rect"] as? [String: Any])
        let pageClicked = try await page.bool("return window.pageClicked === true")
        XCTAssertEqual(select["selector"] as? String, "#two")
        XCTAssertEqual(select["tag"] as? String, "p")
        XCTAssertEqual(select["outerHTML"] as? String, outerHTML)
        XCTAssertEqual(select["text"] as? String, "Two bold")
        XCTAssertGreaterThan((rect["width"] as? NSNumber)?.doubleValue ?? 0, 0)
        XCTAssertFalse(pageClicked, "the page must not see clicks while inspecting")
    }

    func testSelectorIsAUniquePathFromBody() async throws {
        let page = try await RuntimePage.open(body: article, components: components)
        try await page.js("Canvas.inspect(true)")

        try await page.dispatchMouse("click", on: "document.querySelector('main p')")

        let select = try await page.message(ofType: "select")
        let selector = try XCTUnwrap(select["selector"] as? String)
        let resolves = try await page.bool("return document.querySelector(\(jsString(selector))) === document.querySelector('main p')")
        XCTAssertEqual(selector, "body > main:nth-of-type(1) > p:nth-of-type(1)")
        XCTAssertTrue(resolves)
    }

    func testClickOnLinkDoesNotNavigate() async throws {
        let page = try await RuntimePage.open(body: article, components: components)
        try await page.js("Canvas.inspect(true)")

        try await page.js("document.getElementById('link').click()")
        try await page.sleep(for: .milliseconds(100))

        let select = try await page.message(ofType: "select")
        let hash = try await page.string("return location.hash")
        XCTAssertEqual(select["tag"] as? String, "a")
        XCTAssertEqual(hash, "")
    }

    func testClickInsideComponentResolvesToTheHost() async throws {
        let page = try await RuntimePage.open(body: article, components: components)
        try await page.js("Canvas.inspect(true)")

        try await page.dispatchMouse("click", on: "document.querySelector('x-button').shadowRoot.querySelector('button')")

        let select = try await page.message(ofType: "select")
        XCTAssertEqual(select["tag"] as? String, "x-button")
        XCTAssertEqual(select["selector"] as? String, "body > div:nth-of-type(1) > x-button:nth-of-type(1)")
        XCTAssertEqual(select["outerHTML"] as? String, #"<x-button label="Hi"></x-button>"#)
    }

    func testHoverOverlayFollowsThePointerAndInspectOffRemovesIt() async throws {
        let page = try await RuntimePage.open(body: article, components: components, preamble: shadowRootRecorder)
        try await page.js("Canvas.inspect(true)")

        try await page.dispatchMouse("mousemove", on: "document.getElementById('two')")
        let overlayMatchesTarget = try await page.bool("""
            \(overlayBox)
            const box = overlayBox()
            const overlay = box.getBoundingClientRect()
            const target = document.getElementById('two').getBoundingClientRect()
            return getComputedStyle(box.getRootNode().host).pointerEvents === 'none'
              && Math.abs(overlay.top - target.top) < 1 && Math.abs(overlay.width - target.width) < 1
        """)
        XCTAssertTrue(overlayMatchesTarget)

        try await page.js("Canvas.inspect(false)")
        let onlyHeadAndBody = try await page.double("return document.documentElement.children.length")
        try await page.js("document.getElementById('link').click()")
        let hash = try await page.string("return location.hash")
        XCTAssertEqual(onlyHeadAndBody, 2)
        XCTAssertEqual(hash, "#moved", "clicks behave normally once inspect is off")
        XCTAssertTrue(page.messages(ofType: "select").isEmpty)
    }

    func testOverlayLivesInAClosedShadowRootAuthorCSSCannotRestyle() async throws {
        let page = try await RuntimePage.open(
            body: """
            <style>* { outline: 0 !important; background: lime !important; display: block !important; opacity: 0 !important }</style>
            <p id="target">target</p>
            """,
            preamble: shadowRootRecorder
        )
        try await page.js("Canvas.inspect(true)")
        try await page.dispatchMouse("mousemove", on: "document.getElementById('target')")

        let styles = try await page.string("""
            \(overlayBox)
            const box = overlayBox()
            const host = box.getRootNode().host
            const boxStyle = getComputedStyle(box)
            return [host.shadowRoot === null, getComputedStyle(host).opacity, boxStyle.outlineColor, boxStyle.outlineStyle].join('|')
        """)
        XCTAssertEqual(styles, "true|1|rgb(59, 130, 246)|solid")
    }

    func testOverlayFollowsTheHoveredElementOnScroll() async throws {
        let page = try await RuntimePage.open(
            body: #"<div style="height: 2000px"><p id="target" style="margin-top: 200px">target</p></div>"#,
            preamble: shadowRootRecorder
        )
        try await page.js("Canvas.inspect(true)")
        try await page.dispatchMouse("mousemove", on: "document.getElementById('target')")

        try await page.js("window.scrollTo(0, 150)")

        let followed = try await page.waitUntil("""
            (() => {
              \(overlayBox)
              const overlay = overlayBox().getBoundingClientRect()
              const target = document.getElementById('target').getBoundingClientRect()
              return scrollY === 150 && Math.abs(overlay.top - target.top) < 1
            })()
            """)
        XCTAssertTrue(followed)
    }

    func testInspectOnTwiceKeepsOneOverlayAndOneSelectPerClick() async throws {
        let page = try await RuntimePage.open(body: article, components: components)
        try await page.js("Canvas.inspect(true); Canvas.inspect(true)")

        try await page.dispatchMouse("click", on: "document.getElementById('two')")
        try await page.sleep(for: .milliseconds(100))

        let extraChildren = try await page.double("return document.documentElement.children.length - 2")
        XCTAssertEqual(extraChildren, 1)
        XCTAssertEqual(page.messages(ofType: "select").count, 1)
    }

    func testSelectTruncatesOuterHTMLAndText() async throws {
        let page = try await RuntimePage.open(body: """
            <p id="long"></p>
            <script>document.getElementById('long').textContent = 'x'.repeat(30000)</script>
            """)
        try await page.js("Canvas.inspect(true)")

        try await page.dispatchMouse("click", on: "document.getElementById('long')")

        let select = try await page.message(ofType: "select")
        XCTAssertEqual((select["outerHTML"] as? String)?.count, 20000)
        XCTAssertEqual((select["text"] as? String)?.count, 2000)
    }

    func testSelectorFallsBackToNthOfTypePathForDuplicateIds() async throws {
        let page = try await RuntimePage.open(body: #"<p id="dup">a</p><p id="dup">b</p>"#)
        try await page.js("Canvas.inspect(true)")

        try await page.dispatchMouse("click", on: "document.querySelectorAll('p')[1]")

        let select = try await page.message(ofType: "select")
        XCTAssertEqual(select["selector"] as? String, "body > p:nth-of-type(2)")
    }

    func testPressHandlersOnThePageDoNotRunWhileInspecting() async throws {
        let page = try await RuntimePage.open(body: """
            <button id="b" onmousedown="window.pressed = (window.pressed || []).concat('mouse')"
              onpointerdown="window.pressed = (window.pressed || []).concat('pointer')">b</button>
            """)
        try await page.js("Canvas.inspect(true)")

        try await page.dispatchMouse("mousedown", on: "document.getElementById('b')")
        try await page.dispatchMouse("pointerdown", on: "document.getElementById('b')", eventClass: "PointerEvent")

        let pressed = try await page.string("return (window.pressed || []).join()")
        XCTAssertEqual(pressed, "")
    }

    func testEscapePostsInspectExit() async throws {
        let page = try await RuntimePage.open(body: article, components: components)
        try await page.js("Canvas.inspect(true)")

        try await page.js("document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))")

        _ = try await page.message(ofType: "inspectExit")
    }
}

private func jsString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
    return data.map { String(decoding: $0, as: UTF8.self) } ?? "''"
}

/// Records every shadow root (closed ones too) by wrapping `attachShadow` before the runtime loads.
private let shadowRootRecorder = """
<script>
  window.shadowRootsSeen = []
  const attachShadow = Element.prototype.attachShadow
  Element.prototype.attachShadow = function (init) {
    const root = attachShadow.call(this, init)
    shadowRootsSeen.push(root)
    return root
  }
</script>
"""

/// JS defining `overlayBox()`: the highlight box inside the runtime's overlay host on `<html>`.
private let overlayBox = """
const overlayBox = () => shadowRootsSeen
  .find(root => root.host.parentElement === document.documentElement)
  .querySelector('div')
"""
