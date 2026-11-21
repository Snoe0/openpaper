// End-to-end test: drives the real `canvas-mcp` over stdio JSON-RPC against the real Canvas.app.
//
//   xcrun swift -swift-version 5 Tests/E2E/E2E.swift /path/to/Canvas.app     (or: make e2e)
//
// Isolation: the app runs as a temporary copy re-signed with its own bundle id (`local.canvas.e2e`), so its
// user defaults (recent documents, window frames), caches and saved state never mix with the real app's,
// and `CANVAS_BRIDGE_FILE` keeps `bridge.json` in the temp folder. Everything is removed on exit, even on
// failure or Ctrl-C. Claude Code's config is never read or written: the app gets `CLAUDE_CONFIG_DIR` set to the
// temp folder.
import CoreGraphics
import Foundation
import ImageIO

typealias JSON = [String: Any]

// MARK: - The test, step by step (run at the bottom of the file)

func runEndToEnd() {
    let builtApp = appFromArguments()
    prepareTestAppState()
    let work = makeWorkFolder()
    let app = launchIsolatedCopy(of: builtApp, in: work)
    let mcp = startCanvasMCP(from: app, in: work)

    step("MCP handshake") { checkHandshake(mcp) }
    step("tools/list") { checkToolList(mcp) }
    step("create a document") { createDocument(mcp, in: work) }
    step("set tokens with light and dark modes") { setTokens(mcp) }
    step("write the <x-badge> component") { writeBadge(mcp, version: .blue) }
    let boards = step("create 3 animated artboards") { createBoards(mcp) }
    step("screenshot an artboard") { checkScreenshot(mcp, of: boards[0], shows: Look(badge: .blue, mode: .light)) }
    step("edit an artboard") { editBoard(mcp, boards[1]) }
    step("rewrite the component; instances update") {
        writeBadge(mcp, version: .green)
        checkScreenshot(mcp, of: boards[0], shows: Look(badge: .green, mode: .light))
    }
    step("set_mode dark") {
        setMode(mcp, "dark")
        checkScreenshot(mcp, of: boards[2], shows: Look(badge: .green, mode: .dark))
    }
    step("a board can't navigate away") { checkBoardStaysOnItsPage(mcp) }
    step("a board's scripted link click stays on the board") { checkScriptedClickStaysOnTheBoard(mcp) }
    step("console has no errors") { checkConsoleIsClean(mcp) }
    step("pages round trip") { checkPagesRoundTrip(mcp, boardsOnFirstPage: boards.count) }

    pass()
}

// MARK: - Steps

func checkHandshake(_ mcp: MCPClient) {
    let result = mcp.request("initialize", [
        "protocolVersion": "2025-06-18", "capabilities": [:] as JSON,
        "clientInfo": ["name": "canvas-e2e", "version": "1"],
    ])
    expect((result["serverInfo"] as? JSON)?["name"] as? String == "canvas", "initialize: serverInfo.name isn't \"canvas\": \(result)")
    expect((result["instructions"] as? String)?.contains("# Canvas document") == true, "initialize: instructions lack the document guide")
    mcp.notify("notifications/initialized")
}

func checkToolList(_ mcp: MCPClient) {
    let tools = mcp.request("tools/list")["tools"] as? [JSON] ?? []
    let names = Set(tools.compactMap { $0["name"] as? String })
    let missing = expectedTools.subtracting(names)
    expect(missing.isEmpty, "tools/list is missing: \(missing.sorted().joined(separator: ", "))")
}

let expectedTools: Set = [
    "get_document", "open_document", "create_document", "list_pages", "create_page", "switch_page",
    "create_artboard", "read_artboard", "write_artboard", "edit_artboard", "update_artboard", "delete_artboard",
    "duplicate_artboard", "get_selection", "screenshot", "get_console", "focus_artboard", "list_components",
    "read_component", "write_component", "delete_component", "get_tokens", "set_tokens", "set_mode",
]

func createDocument(_ mcp: MCPClient, in work: URL) {
    let path = work.appendingPathComponent("E2E").path
    let overview = mcp.callJSON("create_document", ["path": path]) as? JSON ?? [:]
    expect((overview["path"] as? String)?.hasSuffix("E2E.canvas") == true, "create_document returned \(overview)")
    expect(FileManager.default.fileExists(atPath: path + ".canvas/canvas.json"), "create_document wrote no canvas.json at \(path).canvas")
}

func setTokens(_ mcp: MCPClient) {
    let summary = mcp.callJSON("set_tokens", ["modes": ["light", "dark"], "tokens": tokens]) as? JSON ?? [:]
    expect(summary["modes"] as? [String] == ["light", "dark"], "set_tokens: modes are \(summary["modes"] ?? "missing")")
    let stored = summary["tokens"] as? JSON ?? [:]
    expect(tokens.keys.allSatisfy { stored[$0] != nil }, "set_tokens: not every token was stored: \(stored.keys.sorted())")
}

let tokens: JSON = [
    "color.bg": ["light": Palette.lightBackground.hex, "dark": Palette.darkBackground.hex],
    "color.fg": ["light": "#17181c", "dark": "#f2f2f4"],
    "color.muted": ["light": "#d9d9de", "dark": "#2a2b31"],
    "color.accent": ["light": Palette.blue.hex, "dark": Palette.blue.hex],
    "color.success": ["light": Palette.green.hex, "dark": Palette.green.hex],
    "font.sans": "-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
    "radius.md": "10px",
]

enum BadgeVersion: String {
    case blue = "accent", green = "success"
}

/// A big, solid, unanimated badge, so screenshots can tell its colour apart from the animated parts.
func writeBadge(_ mcp: MCPClient, version: BadgeVersion) {
    let html = """
    <style>
    :host { display: block; }
    .badge { display: flex; align-items: center; gap: 8px; height: 72px; padding: 0 16px; border-radius: var(--radius-md);
      background: var(--color-\(version.rawValue)); color: #fff; font: 600 16px var(--font-sans); }
    </style>
    <div class="badge" data-version="\(version.rawValue)"><span>{{label|New}}</span><slot></slot></div>
    """
    mcp.callText("write_component", ["name": "badge", "html": html])
    let props = (mcp.callJSON("list_components") as? [JSON])?.first { $0["name"] as? String == "badge" }?["props"] as? [JSON]
    expect(props?.first?["name"] as? String == "label" && props?.first?["default"] as? String == "New",
           "list_components: <x-badge> should have prop label (default \"New\"), got \(String(describing: props))")
    expect(mcp.callText("read_component", ["name": "badge"]).contains("data-version=\"\(version.rawValue)\""), "read_component doesn't return what was written")
}

let boardSize = (width: 320, height: 200)

/// Three boards using the tokens and `<x-badge>` (prop + slot), each with a CSS animation and a rAF loop.
func createBoards(_ mcp: MCPClient) -> [Board] {
    ["Alpha", "Beta", "Gamma"].map { name in
        let created = mcp.callJSON("create_artboard", ["name": name, "width": boardSize.width, "height": boardSize.height, "html": boardHTML(name)]) as? JSON ?? [:]
        guard let id = created["id"] as? String else { fail("create_artboard \(name) returned \(created)") }
        expect(mcp.callText("read_artboard", ["id": id]).contains("<x-badge label=\"\(name)\">"), "read_artboard \(id) doesn't return its HTML")
        return Board(id: id, width: boardSize.width, height: boardSize.height)
    }
}

func boardHTML(_ name: String) -> String {
    """
    <style>
    .board { box-sizing: border-box; width: \(boardSize.width)px; height: \(boardSize.height)px; padding: 24px; display: flex; flex-direction: column; gap: 14px;
      background: var(--color-bg); color: var(--color-fg); font-family: var(--font-sans); }
    h1 { margin: 0; font-size: 18px; }
    .track { height: 6px; border-radius: 3px; background: var(--color-muted); overflow: hidden; }
    .bar { width: 40%; height: 100%; background: var(--color-fg); animation: slide 1.2s ease-in-out infinite alternate; }
    @keyframes slide { from { transform: translateX(-100%); } to { transform: translateX(250%); } }
    </style>
    <div class="board"><h1>\(name)</h1><x-badge label="\(name)">&#9733;</x-badge><div class="track"><div class="bar"></div></div></div>
    <script>
    const title = document.querySelector("h1");
    const tick = (time) => { title.dataset.frame = String(Math.round(time)); requestAnimationFrame(tick); };
    requestAnimationFrame(tick);
    console.info("\(name) ready");
    </script>
    """
}

func editBoard(_ mcp: MCPClient, _ board: Board) {
    mcp.callText("edit_artboard", ["id": board.id, "old_string": "<h1>Beta</h1>", "new_string": "<h1>Beta, edited</h1>"])
    expect(mcp.callText("read_artboard", ["id": board.id]).contains("<h1>Beta, edited</h1>"), "edit_artboard didn't change \(board.id)")
}

func setMode(_ mcp: MCPClient, _ mode: String) {
    mcp.callText("set_mode", ["mode": mode])
    let current = (mcp.callJSON("get_tokens") as? JSON)?["mode"] as? String
    expect(current == mode, "set_mode: get_tokens reports mode \(current ?? "nil"), expected \(mode)")
}

/// A script sending the page elsewhere is cancelled, so the board still renders its own page.
func checkBoardStaysOnItsPage(_ mcp: MCPClient) {
    let html = boardHTML("Delta") + #"<script>location.href = "about:blank";</script>"#
    showsItsOwnPage(mcp, boardNamed: "Delta", html: html)
}

/// Smoke test: a board whose script clicks a web link still renders its own page. It can't catch a regression
/// (canvas and snapshot views ignore the pointer, and a web link never loads in the main frame either way); the
/// button-0 check that tells a script's click from the user's is covered by the NavigationPolicy unit tests and a
/// manual WKWebView measurement. The link goes to a reserved, never-resolving domain, so even a regression
/// would only show an error page instead of reaching a real site.
func checkScriptedClickStaysOnTheBoard(_ mcp: MCPClient) {
    let html = boardHTML("Echo") + #"<a id="out" href="https://example.invalid/">out</a><script>document.getElementById("out").click();</script>"#
    showsItsOwnPage(mcp, boardNamed: "Echo", html: html)
}

/// Creates a board from `html`, checks it screenshots as a normal board (green badge, dark mode), and deletes it.
func showsItsOwnPage(_ mcp: MCPClient, boardNamed name: String, html: String) {
    let created = mcp.callJSON("create_artboard", ["name": name, "width": boardSize.width, "height": boardSize.height, "html": html]) as? JSON ?? [:]
    guard let id = created["id"] as? String else { fail("create_artboard \(name) returned \(created)") }
    checkScreenshot(mcp, of: Board(id: id, width: boardSize.width, height: boardSize.height), shows: Look(badge: .green, mode: .dark))
    mcp.callText("delete_artboard", ["id": id])
}

func checkConsoleIsClean(_ mcp: MCPClient) {
    let log = mcp.callText("get_console", ["limit": 500])
    let errors = log.split(separator: "\n").filter { $0.contains("[error]") }
    expect(errors.isEmpty, "get_console has errors:\n" + errors.joined(separator: "\n"))
    detail(log == "No console messages." ? "no console messages" : "\(log.split(separator: "\n").count) console messages, none are errors")
}

func checkPagesRoundTrip(_ mcp: MCPClient, boardsOnFirstPage: Int) {
    let first = currentPage(mcp)
    expect(first["artboards"] as? Int == boardsOnFirstPage, "list_pages: current page has \(first["artboards"] ?? "?") artboards, expected \(boardsOnFirstPage)")
    let created = mcp.callJSON("create_page", ["name": "Second"]) as? JSON ?? [:]
    guard let secondID = created["id"] as? String else { fail("create_page returned \(created)") }
    expect(currentPage(mcp)["id"] as? String == first["id"] as? String, "create_page switched pages; it shouldn't")
    mcp.callText("switch_page", ["page": "Second"])
    let second = currentPage(mcp)
    expect(second["id"] as? String == secondID && second["artboards"] as? Int == 0, "switch_page Second: current page is \(second)")
    mcp.callText("switch_page", ["page": first["id"] as? String ?? ""])
    expect(currentPage(mcp)["id"] as? String == first["id"] as? String, "switch_page back to \(first["id"] ?? "?") didn't take")
    let pages = mcp.callJSON("list_pages") as? [JSON] ?? []
    expect(pages.count == 2, "list_pages should list 2 pages, got \(pages.count)")
}

func currentPage(_ mcp: MCPClient) -> JSON {
    let pages = mcp.callJSON("list_pages") as? [JSON] ?? []
    guard let current = pages.first(where: { $0["current"] as? Bool == true }) else { fail("list_pages marks no page current: \(pages)") }
    return current
}

// MARK: - Screenshots

struct Board {
    let id: String
    let width: Int
    let height: Int
}

enum Mode {
    case light, dark
}

/// What a board should look like: the badge colour and the background of the mode.
struct Look {
    let badge: BadgeVersion
    let mode: Mode

    var badgeColor: RGB { badge == .blue ? Palette.blue : Palette.green }
    var otherBadgeColor: RGB { badge == .blue ? Palette.green : Palette.blue }
    var background: RGB { mode == .light ? Palette.lightBackground : Palette.darkBackground }
}

enum Palette {
    static let lightBackground = RGB(0xf6, 0xf5, 0xf1)
    static let darkBackground = RGB(0x12, 0x13, 0x16)
    static let blue = RGB(0x25, 0x63, 0xeb)
    static let green = RGB(0x16, 0xa3, 0x4a)
}

/// Screenshots until the board shows `look` (edits land asynchronously). A wrong size or a non-PNG fails at once;
/// a blank image is retried like a mismatch, since the first render can land after the first screenshot.
func checkScreenshot(_ mcp: MCPClient, of board: Board, shows look: Look, attempts: Int = 20) {
    var last = ""
    for attempt in 1...attempts {
        let image = Screenshot(png: mcp.callImage("screenshot", ["id": board.id]), of: board)
        if let problem = image.sizeProblem() { fail("screenshot \(board.id): \(problem)") }
        guard let mismatch = image.blankness() ?? image.mismatch(with: look) else {
            return detail("\(board.id): \(image.width)×\(image.height) PNG, \(look.badge) badge on \(look.mode) background (attempt \(attempt))")
        }
        last = mismatch
        Thread.sleep(forTimeInterval: 0.5)
    }
    fail("screenshot \(board.id) never showed the expected look: \(last)")
}

struct RGB: CustomStringConvertible {
    let r: Int, g: Int, b: Int

    init(_ r: Int, _ g: Int, _ b: Int) {
        (self.r, self.g, self.b) = (r, g, b)
    }

    var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
    var description: String { hex }

    func isClose(to other: RGB, tolerance: Int = 28) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
    }
}

/// A decoded screenshot, redrawn into sRGB so colours compare with the token values.
struct Screenshot {
    let board: Board
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init(png: Data, of board: Board) {
        self.board = board
        guard png.starts(with: [0x89, 0x50, 0x4E, 0x47]),
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("screenshot \(board.id) isn't a PNG") }
        (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { fail("screenshot \(board.id): couldn't decode its pixels") }
        self.pixels = pixels
    }

    /// Nil when the image is the board's size (at any whole scale).
    func sizeProblem() -> String? {
        let scale = width / max(board.width, 1)
        guard scale >= 1, width == board.width * scale, height == board.height * scale else {
            return "it's \(width)×\(height), expected \(board.width)×\(board.height) at a whole scale"
        }
        return nil
    }

    /// Nil when the image isn't blank.
    func blankness() -> String? {
        let corner = color(atX: 0, y: 0)
        let differing = fraction { !$0.isClose(to: corner, tolerance: 8) }
        return differing < 0.02 ? "it's blank (\(Int(differing * 100))% of pixels differ from the corner)" : nil
    }

    /// Nil when the background and badge colours match `look`; otherwise what's off.
    func mismatch(with look: Look) -> String? {
        let background = color(atX: 2, y: 2)
        guard background.isClose(to: look.background) else { return "background is \(background), expected \(look.background)" }
        let badge = fraction { $0.isClose(to: look.badgeColor) }
        let other = fraction { $0.isClose(to: look.otherBadgeColor) }
        guard badge > 0.1, other < 0.01 else {
            return "\(Int(badge * 100))% of pixels are \(look.badgeColor) (want >10%), \(Int(other * 100))% are \(look.otherBadgeColor) (want <1%)"
        }
        return nil
    }

    private func color(atX x: Int, y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    private func fraction(where matches: (RGB) -> Bool) -> Double {
        var count = 0
        for y in 0..<height { for x in 0..<width where matches(color(atX: x, y: y)) { count += 1 } }
        return Double(count) / Double(width * height)
    }
}

// MARK: - MCP client over canvas-mcp's stdio

final class MCPClient {
    private let process: Process
    private let input: FileHandle
    private let output: LineQueue
    private var lastID = 0

    init(process: Process, input: FileHandle, output: LineQueue) {
        (self.process, self.input, self.output) = (process, input, output)
    }

    /// Sends a request and returns its result; any JSON-RPC error fails the test.
    @discardableResult
    func request(_ method: String, _ params: JSON = [:], timeout: TimeInterval = 120) -> JSON {
        lastID += 1
        let id = lastID
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let response = nextResponse(to: id, of: method, timeout: timeout)
        if let error = response["error"] as? JSON { fail("\(method) failed: \(error["message"] ?? error)") }
        guard let result = response["result"] as? JSON else { fail("\(method): response has no result: \(response)") }
        return result
    }

    func notify(_ method: String) {
        send(["jsonrpc": "2.0", "method": method])
    }

    /// Calls a tool and returns its content; a tool error fails the test with the tool's message.
    func call(_ tool: String, _ arguments: JSON = [:]) -> [JSON] {
        let result = request("tools/call", ["name": tool, "arguments": arguments])
        let content = result["content"] as? [JSON] ?? []
        if result["isError"] as? Bool == true {
            fail("tool \(tool) failed: " + content.compactMap { $0["text"] as? String }.joined())
        }
        return content
    }

    @discardableResult
    func callText(_ tool: String, _ arguments: JSON = [:]) -> String {
        call(tool, arguments).compactMap { $0["text"] as? String }.joined()
    }

    func callJSON(_ tool: String, _ arguments: JSON = [:]) -> Any {
        let text = callText(tool, arguments)
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { fail("tool \(tool) didn't return JSON: \(text)") }
        return value
    }

    func callImage(_ tool: String, _ arguments: JSON = [:]) -> Data {
        let image = call(tool, arguments).first { $0["type"] as? String == "image" }
        guard image?["mimeType"] as? String == "image/png", let base64 = image?["data"] as? String,
              let data = Data(base64Encoded: base64) else { fail("tool \(tool) returned no PNG image") }
        return data
    }

    private func send(_ message: JSON) {
        guard process.isRunning else { fail("canvas-mcp exited (status \(process.terminationStatus))") }
        let data = try! JSONSerialization.data(withJSONObject: message)
        do { try input.write(contentsOf: data + Data("\n".utf8)) } catch { fail("couldn't write to canvas-mcp: \(error)") }
    }

    private func nextResponse(to id: Int, of method: String, timeout: TimeInterval) -> JSON {
        while true {
            guard let line = output.next(timeout: timeout) else {
                fail(output.isClosed ? "\(method): canvas-mcp closed its output (see its messages above)"
                                     : "\(method): no response from canvas-mcp within \(Int(timeout)) s")
            }
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON else {
                fail("canvas-mcp wrote a line that isn't JSON: \(line.prefix(200))")
            }
            if message["id"] as? Int == id { return message }
        }
    }
}

/// Lines from a pipe, handed out one at a time; nil once the pipe closes or the wait times out.
final class LineQueue {
    private let lock = NSLock()
    private let available = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var lines: [String] = []
    private(set) var isClosed = false

    init(reading pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; self?.close() } else { self?.append(data) }
        }
    }

    func next(timeout: TimeInterval) -> String? {
        guard available.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }

    private func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var complete: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            complete.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lines += complete
        lock.unlock()
        complete.forEach { _ in available.signal() }
    }

    private func close() {
        lock.lock()
        isClosed = true
        lock.unlock()
        available.signal()
    }
}

// MARK: - Isolation and launch

enum Isolation {
    static let bundleID = "local.canvas.e2e"

    /// Where macOS keeps per-app state for the test copy; all of it is removed on exit.
    static var appStateLocations: [URL] {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return [
            "Preferences/\(bundleID).plist", "Saved Application State/\(bundleID).savedState", "Caches/\(bundleID)",
            "WebKit/\(bundleID)", "HTTPStorages/\(bundleID)", "HTTPStorages/\(bundleID).binarycookies",
        ].map { library.appendingPathComponent($0) }
    }
}

func appFromArguments() -> URL {
    guard CommandLine.arguments.count == 2 else { fail("usage: swift Tests/E2E/E2E.swift /path/to/Canvas.app") }
    let app = URL(fileURLWithPath: CommandLine.arguments[1])
    for part in ["Contents/MacOS/Canvas", "Contents/Helpers/canvas-mcp"] where !FileManager.default.isExecutableFile(atPath: app.appendingPathComponent(part).path) {
        fail("\(app.path) has no \(part). Build it first: make build")
    }
    return app
}

/// A run in progress shares the test bundle id's state, so refuse. Leftovers from an earlier run (WebKit or cfprefsd
/// can recreate some just after clean-up) belong only to the test bundle id, so clear them.
func prepareTestAppState() {
    let running = run("/usr/bin/pgrep", ["-f", "canvas-e2e-.*/Canvas.app/Contents/MacOS/Canvas"]).status == 0
    guard !running else { fail("another E2E run's Canvas is still running (pgrep -f canvas-e2e-). Wait for it or quit it, then retry.") }
    removeAppState()
}

func makeWorkFolder() -> URL {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-e2e-\(UUID().uuidString)", isDirectory: true)
    do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false) } catch { fail("couldn't create \(work.path): \(error)") }
    onCleanUp { try? FileManager.default.removeItem(at: work) }
    onCleanUp(removeAppState)
    return work
}

/// Copies the built app into `work` under the test bundle id, re-signs it ad hoc, and launches its binary with
/// `bridge.json` in `work`. Returns the copy once its bridge is up.
func launchIsolatedCopy(of builtApp: URL, in work: URL) -> URL {
    let app = work.appendingPathComponent("Canvas.app")
    let copied = run("/usr/bin/ditto", [builtApp.path, app.path])
    expect(copied.status == 0, "couldn't copy \(builtApp.path): \(copied.output)")
    onCleanUp { unregisterFromLaunchServices(app) }
    setBundleID(Isolation.bundleID, of: app)
    let signed = run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    expect(signed.status == 0, "couldn't re-sign the test copy: \(signed.output)")

    let process = Process()
    process.executableURL = app.appendingPathComponent("Contents/MacOS/Canvas")
    // CLAUDE_CONFIG_DIR points the app's agent-registration check at `work`, so the real ~/.claude.json is never read.
    process.environment = environment(adding: ["CANVAS_BRIDGE_FILE": bridgeFile(in: work).path, "CLAUDE_CONFIG_DIR": work.path])
    let log = work.appendingPathComponent("app.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    process.standardOutput = try? FileHandle(forWritingTo: log)
    process.standardError = process.standardOutput
    appLog = log
    onCleanUp { stop(process) }
    do { try process.run() } catch { fail("couldn't launch Canvas: \(error)") }
    waitForBridge(in: work, of: process)
    return app
}

func startCanvasMCP(from app: URL, in work: URL) -> MCPClient {
    let process = Process()
    process.executableURL = app.appendingPathComponent("Contents/Helpers/canvas-mcp")
    process.environment = environment(adding: [
        "CANVAS_BRIDGE_FILE": bridgeFile(in: work).path, "CANVAS_NO_LAUNCH": "1", "CANVAS_APP_BUNDLE_ID": Isolation.bundleID,
    ])
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.standardError
    do { try process.run() } catch { fail("couldn't start canvas-mcp: \(error)") }
    onCleanUp {
        try? stdin.fileHandleForWriting.close()
        stop(process)
    }
    return MCPClient(process: process, input: stdin.fileHandleForWriting, output: LineQueue(reading: stdout))
}

func bridgeFile(in work: URL) -> URL {
    work.appendingPathComponent("bridge.json")
}

/// The current environment without Canvas's dev hooks, plus `extra`.
func environment(adding extra: [String: String]) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for key in ["CANVAS_DOC", "CANVAS_DEMO_BOARDS", "CANVAS_ZOOM", "CANVAS_REMOTE"] { environment[key] = nil }
    return environment.merging(extra) { $1 }
}

func setBundleID(_ bundleID: String, of app: URL) {
    let plistURL = app.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plistURL),
          var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { fail("couldn't read \(plistURL.path)") }
    plist["CFBundleIdentifier"] = bundleID
    do {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
    } catch {
        fail("couldn't write \(plistURL.path): \(error)")
    }
}

func waitForBridge(in work: URL, of process: Process, timeout: TimeInterval = 90) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard process.isRunning else { fail("Canvas exited during launch (status \(process.terminationStatus))") }
        if let data = try? Data(contentsOf: bridgeFile(in: work)),
           let bridge = try? JSONSerialization.jsonObject(with: data) as? JSON,
           bridge["pid"] as? Int == Int(process.processIdentifier) { return }
        Thread.sleep(forTimeInterval: 0.25)
    }
    fail("Canvas didn't write \(bridgeFile(in: work).path) within \(Int(timeout)) s. Is CANVAS_BRIDGE_FILE honoured by this build?")
}

func removeAppState() {
    _ = run("/usr/bin/defaults", ["delete", Isolation.bundleID])
    for location in Isolation.appStateLocations { try? FileManager.default.removeItem(at: location) }
}

func unregisterFromLaunchServices(_ app: URL) {
    let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    _ = run(lsregister, ["-u", app.path])
}

/// SIGTERM, then SIGKILL if it hasn't exited within 5 s.
func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

// MARK: - Running commands

@discardableResult
func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

// MARK: - Reporting, failing and cleaning up

var appLog: URL?
private let cleanUpLock = NSLock()
private var cleanUpSteps: [() -> Void] = []
private var cleanedUp = false
private var exitClaimed = false

/// True for the first caller only: exactly one thread (passing or failing) gets to clean up and exit.
func claimExit() -> Bool {
    cleanUpLock.lock()
    defer { cleanUpLock.unlock() }
    let first = !exitClaimed
    exitClaimed = true
    return first
}

func onCleanUp(_ work: @escaping () -> Void) {
    cleanUpLock.lock()
    cleanUpSteps.append(work)
    cleanUpLock.unlock()
}

/// Runs every clean-up step once, newest first.
func cleanUp() {
    cleanUpLock.lock()
    defer { cleanUpLock.unlock() }
    guard !cleanedUp else { return }
    cleanedUp = true
    cleanUpSteps.reversed().forEach { $0() }
}

@discardableResult
func step<Result>(_ name: String, _ work: () -> Result) -> Result {
    print("• \(name)")
    fflush(stdout)
    return work()
}

func detail(_ text: String) {
    print("    \(text)")
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { fail(message()) }
}

/// Reports the first failure only: a signal can fail the run while the main thread is failing too. Only the first
/// caller cleans up and exits; any later one parks, so two threads never call exit() at once.
func fail(_ message: String) -> Never {
    guard claimExit() else { parkForever() }
    FileHandle.standardError.write(Data("\nE2E FAILED: \(message)\n".utf8))
    printAppLogTail()
    cleanUp()
    exit(1)
}

func pass() -> Never {
    guard claimExit() else { parkForever() }
    print("\nE2E PASSED")
    cleanUp()
    exit(0)
}

func parkForever() -> Never {
    while true { sleep(1) }
}

func printAppLogTail() {
    guard let appLog, let text = try? String(contentsOf: appLog, encoding: .utf8), !text.isEmpty else { return }
    let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(30).joined(separator: "\n")
    FileHandle.standardError.write(Data("--- Canvas log (last lines) ---\n\(tail)\n".utf8))
}

/// Ctrl-C, a hang-up or a kill still cleans up; so does running too long.
func cleanUpOnSignalsAndTimeout(after timeout: TimeInterval = 900) {
    for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler { fail("interrupted by signal \(signalNumber)") }
        source.resume()
        signalSources.append(source)
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { fail("the whole run took longer than \(Int(timeout)) s") }
}

var signalSources: [DispatchSourceSignal] = []

cleanUpOnSignalsAndTimeout()
runEndToEnd()
