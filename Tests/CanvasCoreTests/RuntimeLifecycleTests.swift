import XCTest
@testable import CanvasCore

@MainActor
final class RuntimeLifecycleTests: XCTestCase {
    func testPostsReadyOnDOMContentLoaded() async throws {
        let page = try await RuntimePage.open(body: "<p>hi</p>")

        _ = try await page.message(ofType: "ready")
    }

    /// `ArtboardPage` inlines the runtime in a `<script>` element, which the first `</script` would end.
    func testRuntimeSourceCanBeInlinedInAScriptElement() {
        let source = RuntimeScript.source

        XCTAssertFalse(source.isEmpty)
        XCTAssertNil(source.range(of: "</script", options: .caseInsensitive))
    }

    func testOnlyCanvasLeaksIntoTheGlobalScope() async throws {
        let page = try await RuntimePage.open(
            body: """
            <script>window.globalsBefore = Object.getOwnPropertyNames(window)</script>
            \(try runtimeScript())
            <script>
              window.leaked = Object.getOwnPropertyNames(window)
                .filter(name => !globalsBefore.includes(name) && name !== 'globalsBefore')
                .join()
            </script>
            """,
            inlinesRuntime: false
        )

        let leaked = try await page.string("return leaked")
        XCTAssertEqual(leaked, "Canvas")
    }

    func testCanvasIsAReadOnlyNonConfigurableGlobal() async throws {
        let page = try await RuntimePage.open(body: "")

        let descriptor = try await page.string("""
            const original = window.Canvas
            try { window.Canvas = {} } catch {}
            const { writable, configurable, enumerable } = Object.getOwnPropertyDescriptor(window, 'Canvas')
            return [writable, configurable, enumerable, window.Canvas === original].join()
        """)
        XCTAssertEqual(descriptor, "false,false,true,true")
    }

    func testLoadingTheRuntimeTwiceDoesNotWrapTwice() async throws {
        let page = try await RuntimePage.open(
            body: "",
            head: """
            <script>window.firstWrappers = [requestAnimationFrame, setTimeout, setInterval, console.log, window.Canvas]</script>
            <script>\(try runtimeSource())</script>
            """
        )

        let sameWrappers = try await page.bool("""
            const current = [requestAnimationFrame, setTimeout, setInterval, console.log, window.Canvas]
            return current.every((wrapper, index) => wrapper === firstWrappers[index])
        """)
        try await page.js("console.log('once')")
        try await page.sleep(for: .milliseconds(100))
        XCTAssertTrue(sameWrappers)
        XCTAssertEqual(page.messages(ofType: "ready").count, 1)
        XCTAssertEqual(page.messages(ofType: "console").count, 1)
    }
}
