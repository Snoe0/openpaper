import XCTest
@testable import CanvasCore

final class DocumentComponentsTests: XCTestCase {
    @MainActor
    func testInvalidComponentNamesAreRejected() throws {
        let document = try makeDocument()

        for name in ["", "Button", "1card", "my_button", "-x", "card.html", "../x"] {
            XCTAssertThrowsError(try document.writeComponent(name: name, html: "<p></p>"), name) {
                XCTAssertEqual($0 as? DocumentError, .invalidName(name))
            }
        }
        XCTAssertEqual(document.componentNames, [])
    }

    @MainActor
    func testWriteReadListAndDeleteComponents() throws {
        let document = try makeDocument()

        try document.writeComponent(name: "pricing-card", html: "<div>{{title}}</div>")
        try document.writeComponent(name: "button", html: "<button><slot></slot></button>")

        XCTAssertEqual(document.componentNames, ["button", "pricing-card"])
        XCTAssertEqual(try document.componentHTML(name: "button"), "<button><slot></slot></button>")
        XCTAssertEqual(try readText("components/pricing-card.html", in: document), "<div>{{title}}</div>")
        XCTAssertEqual(document.allComponents(), [
            "button": "<button><slot></slot></button>",
            "pricing-card": "<div>{{title}}</div>",
        ])

        try document.deleteComponent(name: "button")
        XCTAssertEqual(document.componentNames, ["pricing-card"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.url.appendingPathComponent("components/button.html").path))
        XCTAssertThrowsError(try document.componentHTML(name: "button")) { XCTAssertEqual($0 as? DocumentError, .notFound("button")) }
        XCTAssertThrowsError(try document.deleteComponent(name: "button")) { XCTAssertEqual($0 as? DocumentError, .notFound("button")) }
    }

    func testPropsAreExtractedWithDefaultsAndDeduped() {
        let html = """
        <style>.b{color:red}</style>
        <button class="{{ tone | primary }}">{{label|Click me}}</button>
        <span>{{label|Ignored}} {{count}} {{empty|}}</span><slot></slot>
        """

        XCTAssertEqual(ComponentTemplate.props(in: html), [
            ComponentProp(name: "tone", defaultValue: "primary"),
            ComponentProp(name: "label", defaultValue: "Click me"),
            ComponentProp(name: "count", defaultValue: nil),
            ComponentProp(name: "empty", defaultValue: ""),
        ])
        XCTAssertEqual(ComponentTemplate.props(in: "<p>no props</p>"), [])
    }

    @MainActor
    func testPropsOfAComponent() throws {
        let document = try makeDocument()
        try document.writeComponent(name: "badge", html: "<b>{{text|New}}</b>")

        XCTAssertEqual(try document.props(ofComponent: "badge"), [ComponentProp(name: "text", defaultValue: "New")])
        XCTAssertThrowsError(try document.props(ofComponent: "missing"))
    }

    func testPlaceholderNamesAreASCIIOnly() {
        XCTAssertEqual(ComponentTemplate.props(in: "{{café}} {{ok_1-x|a}} {{日本}}"), [ComponentProp(name: "ok_1-x", defaultValue: "a")])
    }
}
