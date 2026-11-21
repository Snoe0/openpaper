import XCTest

@MainActor
final class RuntimeComponentTests: XCTestCase {
    func testSubstitutesPropsWithDefaultsAndEscapesValues() async throws {
        let page = try await RuntimePage.open(
            body: """
            <x-badge id="a" label="<i>hi</i> &amp; bye"></x-badge>
            <x-badge id="b" variant='ghost" data-evil="1'></x-badge>
            """,
            components: ["badge": #"<span class="{{variant|primary}}">{{label}}</span><b>{{ missing }}</b>"#]
        )

        let shadow = "document.getElementById('a').shadowRoot"
        let className = try await page.string("return \(shadow).querySelector('span').className")
        let label = try await page.string("return \(shadow).querySelector('span').textContent")
        let injected = try await page.bool("return \(shadow).querySelector('i') !== null")
        let missing = try await page.string("return \(shadow).querySelector('b').textContent")
        XCTAssertEqual(className, "primary")
        XCTAssertEqual(label, "<i>hi</i> & bye")
        XCTAssertFalse(injected, "attribute values must be HTML-escaped")
        XCTAssertEqual(missing, "")

        let quoted = "document.getElementById('b').shadowRoot.querySelector('span')"
        let quotedClass = try await page.string("return \(quoted).className")
        let escapedAttribute = try await page.bool("return \(quoted).hasAttribute('data-evil')")
        XCTAssertEqual(quotedClass, #"ghost" data-evil="1"#)
        XCTAssertFalse(escapedAttribute, "quotes must be escaped inside attribute positions")
    }

    func testTrimsWhitespaceAroundPropNameAndDefault() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-chip id="fallback"></x-chip><x-chip id="given" tone="calm"></x-chip>"#,
            components: ["chip": "<span>[{{ tone | primary }}]</span>"]
        )

        let fallback = try await page.string("return document.getElementById('fallback').shadowRoot.querySelector('span').textContent")
        let given = try await page.string("return document.getElementById('given').shadowRoot.querySelector('span').textContent")
        XCTAssertEqual(fallback, "[primary]")
        XCTAssertEqual(given, "[calm]")
    }

    func testProjectsDefaultAndNamedSlots() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-card id="c"><h2 slot="title">Title</h2><p>Body</p></x-card>"#,
            components: ["card": #"<header><slot name="title"></slot></header><main><slot></slot></main>"#]
        )

        let shadow = "document.getElementById('c').shadowRoot"
        let titleSlot = try await page.string(
            "return \(shadow).querySelector('header slot').assignedElements().map(e => e.tagName).join()"
        )
        let defaultSlot = try await page.string(
            "return \(shadow).querySelector('main slot').assignedElements().map(e => e.tagName).join()"
        )
        XCTAssertEqual(titleSlot, "H2")
        XCTAssertEqual(defaultSlot, "P")
    }

    func testRendersComponentsNestedInsideTemplates() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-toolbar id="t" action="Save"></x-toolbar>"#,
            components: [
                "button": "<button>{{label}}</button>",
                "toolbar": #"<nav><x-button label="{{action|Go}}"></x-button></nav>"#,
            ]
        )

        let text = try await page.string(
            "return document.getElementById('t').shadowRoot.querySelector('x-button').shadowRoot.querySelector('button').textContent"
        )
        XCTAssertEqual(text, "Save")
    }

    func testHotUpdateRerendersExistingInstancesAndKeepsOmittedTemplates() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-button id="b" label="Hi"></x-button><x-badge id="g" label="Old"></x-badge>"#,
            components: ["button": "<button>{{label}}</button>", "badge": "<span>{{label}}</span>"]
        )

        try await page.js(#"Canvas.defineComponents({ button: "<a>{{label}}!</a>" })"#)

        let updated = try await page.string("return document.getElementById('b').shadowRoot.innerHTML")
        let kept = try await page.string("return document.getElementById('g').shadowRoot.querySelector('span')?.textContent")
        XCTAssertTrue(updated?.contains("<a>Hi!</a>") == true, "got \(updated ?? "nil")")
        XCTAssertFalse(updated?.contains("<button>") == true)
        XCTAssertEqual(kept, "Old")
    }

    func testAttributeChangeRerenders() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-button id="b" label="Hi"></x-button>"#,
            components: ["button": "<button>{{label}}</button>"]
        )

        try await page.js("document.getElementById('b').setAttribute('label', 'Bye')")

        let rerendered = try await page.waitUntil(
            "document.getElementById('b').shadowRoot.querySelector('button').textContent === 'Bye'"
        )
        XCTAssertTrue(rerendered)
    }

    func testParserAndScriptCreatedInstancesRenderOnce() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-button id="parsed" label="Hi" class="c" data-x="1"></x-button>"#,
            components: ["button": "<button>{{label}}</button>"],
            preamble: renderCounter
        )

        try await page.js("""
            const scripted = document.createElement('x-button')
            scripted.id = 'scripted'
            scripted.setAttribute('label', 'Hi')
            document.body.append(scripted)
        """)
        try await page.sleep(for: .milliseconds(100))

        let renders = try await page.string("return [renders.parsed, renders.scripted].join()")
        XCTAssertEqual(renders, "1,1")
    }

    func testOnlyChangesToUsedPropsRerender() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-pulse id="b" label="Hi"></x-pulse>"#,
            components: ["pulse": "<style>@keyframes s { to { opacity: 0 } } i { animation: s 10s linear infinite }</style><i>{{label}}</i>"],
            preamble: renderCounter
        )
        let inner = "document.getElementById('b').shadowRoot.querySelector('i')"
        try await page.js("window.firstInner = \(inner)")
        try await page.sleep(for: .milliseconds(150))

        try await page.js("""
            const host = document.getElementById('b')
            host.classList.add('on')
            host.dataset.state = 'open'
            host.setAttribute('label', 'Hi')
        """)
        try await page.sleep(for: .milliseconds(100))
        let untouched = try await page.bool("return \(inner) === firstInner && renders.b === 1")
        let animationTime = try await page.double("return firstInner.getAnimations()[0]?.currentTime ?? -1")
        XCTAssertTrue(untouched, "class, data-* and same-value changes must not re-render")
        XCTAssertGreaterThan(animationTime, 150, "the running animation must not restart")

        try await page.js("document.getElementById('b').setAttribute('label', 'Bye')")
        let rerendered = try await page.waitUntil("\(inner).textContent === 'Bye'")
        let renders = try await page.double("return renders.b")
        XCTAssertTrue(rerendered)
        XCTAssertEqual(renders, 2)
    }

    func testPropValuesAreNotExpandedAgain() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-pair id="p" label="{{other}}" other="X"></x-pair>"#,
            components: ["pair": "<span>{{label}}</span><b>{{other}}</b>"]
        )

        let label = try await page.string("return document.getElementById('p').shadowRoot.querySelector('span').textContent")
        XCTAssertEqual(label, "{{other}}")
    }

    func testElementUsedBeforeDefinitionUpgradesOnceDefined() async throws {
        let page = try await RuntimePage.open(body: #"<x-late id="l" name="World"></x-late>"#)

        let before = try await page.bool("return document.getElementById('l').shadowRoot === null")
        try await page.js(#"Canvas.defineComponents({ late: "<p>Hello {{name}}</p>" })"#)
        let after = try await page.string("return document.getElementById('l').shadowRoot.querySelector('p').textContent")

        XCTAssertTrue(before)
        XCTAssertEqual(after, "Hello World")
    }

    func testDefaultsAreEscapedLikePropValues() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-tip id="t"></x-tip>"#,
            components: ["tip": #"<span title="{{hint|say "hi" & <b>bye</b>}}">x</span>"#]
        )

        let span = "document.getElementById('t').shadowRoot.querySelector('span')"
        let title = try await page.string("return \(span).title")
        let injected = try await page.bool("return \(span).hasAttribute('hi') || \(span).querySelector('b') !== null")
        XCTAssertEqual(title, #"say "hi" & <b>bye</b>"#)
        XCTAssertFalse(injected)
    }

    func testComponentThatIncludesItselfStopsAndReportsOnce() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-tree id="t"></x-tree><x-tree></x-tree>"#,
            components: ["tree": "<div><x-tree></x-tree></div>"]
        )

        let depth = try await page.double("""
            let depth = 0
            for (let tree = document.getElementById('t'); tree; tree = tree.shadowRoot?.querySelector('x-tree')) depth++
            return depth
        """)
        let reports = try await page.double("""
            return Canvas.logs.filter(entry => entry.level === 'error' && entry.message.includes('Canvas: <x-tree> includes itself')).length
        """)
        let otherErrors = try await page.double("""
            return Canvas.logs.filter(entry => entry.level === 'error' && !entry.message.includes('includes itself')).length
        """)
        XCTAssertGreaterThan(depth, 1)
        XCTAssertLessThanOrEqual(depth, 10)
        XCTAssertEqual(reports, 1)
        XCTAssertEqual(otherErrors, 0)
    }

    /// A cycle of five never repeats a tag 8 times within 32 levels, so only the overall depth cap stops it.
    func testComponentsIncludingEachOtherStopAtTheOverallDepthCap() async throws {
        let cycle = ["a": "b", "b": "c", "c": "d", "d": "e", "e": "a"]
        let page = try await RuntimePage.open(
            body: #"<x-a id="top"></x-a>"#,
            components: cycle.mapValues { "<div><x-\($0)></x-\($0)></div>" }
        )

        let depth = try await page.double("""
            let depth = 0
            for (let node = document.getElementById('top'); node; node = node.shadowRoot?.querySelector('div > *')) depth++
            return depth
        """)
        let reports = try await page.double("""
            return Canvas.logs.filter(entry => entry.level === 'error' && entry.message.startsWith('Canvas: <x-')).length
        """)
        XCTAssertGreaterThan(depth, 1)
        XCTAssertLessThanOrEqual(depth, 33)
        XCTAssertEqual(reports, 1)
    }

    func testTwoComponentsIncludingEachOtherStopAndReport() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-ping id="top"></x-ping>"#,
            components: ["ping": "<div><x-pong></x-pong></div>", "pong": "<div><x-ping></x-ping></div>"]
        )

        let depth = try await page.double("""
            let depth = 0
            for (let node = document.getElementById('top'); node; node = node.shadowRoot?.querySelector('div > *')) depth++
            return depth
        """)
        let reported = try await page.bool("return Canvas.logs.some(entry => entry.level === 'error' && entry.message.startsWith('Canvas: <x-p'))")
        XCTAssertLessThanOrEqual(depth, 33)
        XCTAssertTrue(reported)
    }

    func testSameComponentNestedThroughSlotsStillRenders() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-box id="outer"><x-box id="inner" label="in"></x-box></x-box>"#,
            components: ["box": "<b>{{label|box}}</b><slot></slot>"]
        )

        let inner = try await page.string("return document.getElementById('inner').shadowRoot.querySelector('b').textContent")
        XCTAssertEqual(inner, "in")
    }

    func testHotUpdateRendersNestedInstancesOnce() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-toolbar id="t"></x-toolbar>"#,
            components: ["button": "<button>b</button>", "toolbar": "<nav><x-button></x-button></nav>"],
            preamble: renderCounter
        )

        let renders = try await page.string("""
            window.renders = {}
            Canvas.defineComponents({ button: '<button>B</button>', toolbar: '<nav><x-button></x-button></nav>' })
            return [renders.t, renders['']].join()
        """)
        XCTAssertEqual(renders, "1,1", "outer once, and only the fresh nested instance once")
    }

    func testTokenCustomPropertiesInheritIntoShadowRoots() async throws {
        let page = try await RuntimePage.open(
            body: #"<x-swatch id="s"></x-swatch>"#,
            components: ["swatch": "<style>p { color: var(--color-brand) }</style><p>x</p>"],
            tokens: ":root { --color-brand: rgb(1, 2, 3) }"
        )

        let color = try await page.string(
            "return getComputedStyle(document.getElementById('s').shadowRoot.querySelector('p')).color"
        )
        XCTAssertEqual(color, "rgb(1, 2, 3)")
    }
}

/// Counts shadow-root renders per host id by instrumenting the `innerHTML` setter before the runtime loads.
private let renderCounter = """
<script>
  window.renders = {}
  const shadowInnerHTML = Object.getOwnPropertyDescriptor(ShadowRoot.prototype, 'innerHTML')
  Object.defineProperty(ShadowRoot.prototype, 'innerHTML', {
    ...shadowInnerHTML,
    set(html) {
      renders[this.host.id] = (renders[this.host.id] || 0) + 1
      shadowInnerHTML.set.call(this, html)
    },
  })
</script>
"""
