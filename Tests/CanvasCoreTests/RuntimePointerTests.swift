import XCTest
@testable import CanvasCore

/// `Canvas.elementAt` and `Canvas.describe`: what a right-click on the canvas and `get_element` ask a page.
@MainActor
final class RuntimePointerTests: XCTestCase {
    private let body = """
    <style>body { margin: 0; } .cta { display: block; position: relative; margin: 10px; padding: 4px 8px;
      width: 100px; height: 30px; font: 700 20px/1.5 Georgia; color: rgb(255, 0, 0); background-color: rgb(0, 0, 255); }</style>
    <section class="pricing"><a class="cta" href="#">Buy</a><a>Other</a></section>
    <div style="height: 50px"><x-button label="Hi"></x-button></div>
    """
    private let components = ["button": "<button>{{label}}</button>"]

    func testElementAtReportsTheSourceElementUnderAPoint() async throws {
        let page = try await RuntimePage.open(body: body, components: components)

        let found = try await page.js("return Canvas.elementAt(20, 20)") as? [String: Any]

        let element = try XCTUnwrap(found)
        let box = try XCTUnwrap(element["box"] as? [String: Any])
        let styles = try XCTUnwrap(element["styles"] as? [String: String])
        XCTAssertEqual(element["selector"] as? String, "body > section:nth-of-type(1) > a:nth-of-type(1)")
        XCTAssertEqual(element["outerHTML"] as? String, ##"<a class="cta" href="#">Buy</a>"##)
        XCTAssertEqual(box["x"] as? NSNumber, 10)
        XCTAssertEqual(box["y"] as? NSNumber, 10)
        XCTAssertEqual(box["width"] as? NSNumber, 116, "width plus padding")
        XCTAssertEqual(styles["display"], "block")
        XCTAssertEqual(styles["position"], "relative")
        XCTAssertEqual(styles["font-family"], "Georgia")
        XCTAssertEqual(styles["font-size"], "20px")
        XCTAssertEqual(styles["font-weight"], "700")
        XCTAssertEqual(styles["line-height"], "30px")
        XCTAssertEqual(styles["color"], "rgb(255, 0, 0)")
        XCTAssertEqual(styles["background-color"], "rgb(0, 0, 255)")
        XCTAssertEqual(styles["padding"], "4px 8px")
        XCTAssertEqual(styles["margin"], "10px")
        XCTAssertEqual(styles["width"], "100px")
        XCTAssertEqual(styles["height"], "30px")
    }

    func testElementAtResolvesHitsInsideAComponentToItsHost() async throws {
        let page = try await RuntimePage.open(body: body, components: components)
        let point = try await page.js("""
            const r = document.querySelector('x-button').shadowRoot.querySelector('button').getBoundingClientRect()
            return [r.x + 2, r.y + 2]
        """) as? [NSNumber]
        let (x, y) = try (XCTUnwrap(point?.first), XCTUnwrap(point?.last))

        let element = try await page.js("return Canvas.elementAt(\(x), \(y))") as? [String: Any]

        XCTAssertEqual(element?["selector"] as? String, "body > div:nth-of-type(1) > x-button:nth-of-type(1)")
        XCTAssertEqual(element?["outerHTML"] as? String, #"<x-button label="Hi"></x-button>"#)
    }

    func testElementAtFindsNothingOnThePageBackground() async throws {
        let page = try await RuntimePage.open(body: body, components: components)

        let belowContent = try await page.js("return Canvas.elementAt(200, 280) === null")

        XCTAssertEqual(belowContent as? Bool, true)
    }

    func testDescribeResolvesASelectorAndReportsNoMatch() async throws {
        let page = try await RuntimePage.open(body: body, components: components)

        let found = try await page.js("return Canvas.describe('section.pricing > a.cta')") as? [String: Any]
        let missing = try await page.js("return Canvas.describe('section.pricing > a.gone') === null")

        XCTAssertEqual(found?["selector"] as? String, "body > section:nth-of-type(1) > a:nth-of-type(1)")
        XCTAssertEqual(found?["outerHTML"] as? String, ##"<a class="cta" href="#">Buy</a>"##)
        XCTAssertEqual((found?["styles"] as? [String: String])?["color"], "rgb(255, 0, 0)")
        XCTAssertEqual(found?["matches"] as? NSNumber, 1)
        XCTAssertNil(found?["truncated"])
        XCTAssertEqual(missing as? Bool, true)
    }

    func testDescribeCountsTheMatchesOfAnAmbiguousSelector() async throws {
        let page = try await RuntimePage.open(body: body, components: components)

        let found = try await page.js("return Canvas.describe('section a')") as? [String: Any]

        XCTAssertEqual(found?["outerHTML"] as? String, ##"<a class="cta" href="#">Buy</a>"##, "the first match")
        XCTAssertEqual(found?["matches"] as? NSNumber, 2)
    }

    func testDescribeFlagsAMalformedSelector() async throws {
        let page = try await RuntimePage.open(body: body, components: components)

        let result = try await page.js("return Canvas.describe('a[')") as? [String: Any]

        XCTAssertEqual(result?["invalidSelector"] as? Bool, true)
        XCTAssertThrowsError(try PageElement.decode(runtimeValue: result)) { error in
            XCTAssertEqual(error as? PageElementError, .invalidSelector)
        }
    }

    /// `get_element` answers with at most `PageElement.maxHTMLLength` characters of HTML; a right-click copies all of it.
    func testDescribeCapsLongHTMLButElementAtKeepsItWhole() async throws {
        let long = "<p id=\"long\" style=\"margin:0\">" + String(repeating: "x", count: 30_000) + "</p>"
        let page = try await RuntimePage.open(body: long, components: components)

        let described = try await page.js("return Canvas.describe('#long')") as? [String: Any]
        let atPoint = try await page.js("return Canvas.elementAt(20, 12)") as? [String: Any]

        XCTAssertEqual((described?["outerHTML"] as? String)?.count, PageElement.maxHTMLLength)
        XCTAssertEqual(described?["truncated"] as? Bool, true)
        XCTAssertEqual((atPoint?["outerHTML"] as? String)?.count, long.count)
        XCTAssertNil(atPoint?["truncated"])
    }

    func testWhatDescribeReturnsDecodesAsAPageElement() async throws {
        let page = try await RuntimePage.open(body: body, components: components)

        let found = try await page.js("return Canvas.describe('a.cta')")
        let missing = try await page.js("return Canvas.describe('a.gone')")

        let element = try XCTUnwrap(PageElement.decode(runtimeValue: found))
        XCTAssertEqual(element.selector, "body > section:nth-of-type(1) > a:nth-of-type(1)")
        XCTAssertEqual(element.outerHTML, ##"<a class="cta" href="#">Buy</a>"##)
        XCTAssertEqual(element.box, ElementRect(x: 10, y: 10, width: 116, height: 38))
        XCTAssertEqual(element.styles["font-size"], "20px")
        XCTAssertEqual(element.matches, 1)
        XCTAssertNil(element.truncated)
        XCTAssertNil(try PageElement.decode(runtimeValue: missing))
        XCTAssertThrowsError(try PageElement.decode(runtimeValue: ["selector": 1]))
    }
}
