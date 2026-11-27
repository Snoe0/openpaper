import XCTest

@MainActor
final class RuntimeConsoleTests: XCTestCase {
    func testConsoleErrorIsPostedAndStored() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("console.error('boom', { code: 7 })")

        let posted = try await page.message(ofType: "console")
        let stored = try await page.string("const last = Canvas.logs.at(-1); return [last.level, last.message, typeof last.time].join('|')")
        XCTAssertEqual(posted["level"] as? String, "error")
        XCTAssertEqual(posted["message"] as? String, #"boom {"code":7}"#)
        XCTAssertEqual(stored, #"error|boom {"code":7}|number"#)
    }

    func testThrownErrorsAndUnhandledRejectionsArePostedAndStored() async throws {
        let page = try await RuntimePage.open(body: """
            <script>throw new Error('kaboom')</script>
            <script>Promise.reject(new Error('nope'))</script>
            """)

        let captured = try await page.waitUntil("Canvas.logs.filter(entry => entry.level === 'error').length === 2")
        let messages = page.messages(ofType: "console").compactMap { $0["message"] as? String }
        XCTAssertTrue(captured)
        XCTAssertTrue(messages.contains { $0.contains("kaboom") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.contains("nope") }, "\(messages)")
    }

    func testOriginalConsoleMethodIsStillCalled() async throws {
        let page = try await RuntimePage.open(
            body: "",
            preamble: """
            <script>
              window.originalLogCalls = []
              const nativeLog = console.log
              console.log = (...args) => { originalLogCalls.push(args.join(' ')); return nativeLog.apply(console, args) }
            </script>
            """
        )

        try await page.js("console.log('a', 1); console.log('b')")

        let calls = try await page.string("return originalLogCalls.join('|')")
        XCTAssertEqual(calls, "a 1|b")
        XCTAssertEqual(page.messages(ofType: "console").count, 2)
    }

    func testMessagesAreANoOpWithoutAHandlerAndLogsStillRecord() async throws {
        let page = try await RuntimePage.open(body: "<p id=p>p</p>", installsMessageHandler: false)

        let lastLog = try await page.string("""
            console.error('quiet')
            Canvas.inspect(true)
            document.getElementById('p').click()
            document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
            return Canvas.logs.at(-1).message
        """)
        XCTAssertEqual(lastLog, "quiet")
    }

    func testLongMessagesAreTruncatedTo10000Characters() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("console.log('x'.repeat(25000))")

        let stored = try await page.double("return Canvas.logs.at(-1).message.length")
        let posted = try await page.message(ofType: "console")
        XCTAssertEqual(stored, 10000)
        XCTAssertEqual((posted["message"] as? String)?.count, 10000)
    }

    func testConsoleDebugIsCaptured() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("console.debug('details')")

        let posted = try await page.message(ofType: "console")
        XCTAssertEqual(posted["level"] as? String, "debug")
        XCTAssertEqual(posted["message"] as? String, "details")
    }

    func testLogsKeepTheLast200EntriesAcrossLevels() async throws {
        let page = try await RuntimePage.open(body: "")

        try await page.js("console.info('i'); console.warn('w'); for (let n = 0; n < 250; n++) console.log(String(n))")

        let summary = try await page.string("return [Canvas.logs.length, Canvas.logs[0].message, Canvas.logs.at(-1).message].join()")
        let levels = Set(page.messages(ofType: "console").compactMap { $0["level"] as? String })
        XCTAssertEqual(summary, "200,50,249")
        XCTAssertEqual(levels, ["info", "warn", "log"])
    }
}
