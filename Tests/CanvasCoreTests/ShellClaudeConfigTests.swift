import XCTest
@testable import CanvasCore

final class ShellClaudeConfigTests: XCTestCase {
    private let helper = URL(fileURLWithPath: "/Applications/Canvas.app/Contents/Helpers/canvas-mcp")

    private func summary(_ json: String, helper: URL? = nil) -> ClaudeConfigSummary? {
        ClaudeConfig.summary(of: Data(json.utf8), helper: helper ?? self.helper)
    }

    private func status(_ json: String, helper: URL? = nil) -> RegistrationStatus? {
        summary(json, helper: helper)?.userEntry
    }

    private func temporaryFolder() throws -> URL {
        let folder = try temporaryDocumentURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Location

    func testTheConfigIsTheUsersClaudeJSON() {
        XCTAssertEqual(ClaudeConfig.defaultURL(home: "/Users/me", environment: [:]).path, "/Users/me/.claude.json")
    }

    func testClaudeConfigDirMovesTheConfig() {
        XCTAssertEqual(ClaudeConfig.defaultURL(home: "/Users/me", environment: ["CLAUDE_CONFIG_DIR": "/Users/me/alt"]).path, "/Users/me/alt/.claude.json")
        XCTAssertEqual(ClaudeConfig.defaultURL(home: "/Users/me", environment: ["CLAUDE_CONFIG_DIR": ""]).path, "/Users/me/.claude.json")
    }

    // MARK: - Reading

    func testAMissingFileIsNotRegistered() throws {
        let missing = try temporaryFolder().appendingPathComponent(".claude.json")

        XCTAssertEqual(try ClaudeConfig.read(at: missing, helper: helper), ClaudeConfigSummary(userEntry: .notRegistered, localScopeProjects: []))
    }

    func testAFileThatCantBeReadIsUnreadableNotUnregistered() throws {
        let folderInTheWay = try temporaryFolder().appendingPathComponent(".claude.json")
        try FileManager.default.createDirectory(at: folderInTheWay, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ClaudeConfig.read(at: folderInTheWay, helper: helper)) { error in
            XCTAssertEqual(error as? AgentConnectError, .unreadableConfig)
        }
    }

    func testAnOversizedFileIsUnreadable() throws {
        let file = try temporaryFolder().appendingPathComponent(".claude.json")
        try Data(#"{"mcpServers":{}}"#.utf8).write(to: file)

        XCTAssertThrowsError(try ClaudeConfig.read(at: file, helper: helper, maxBytes: 8)) { error in
            XCTAssertEqual(error as? AgentConnectError, .unreadableConfig)
        }
        XCTAssertEqual(try ClaudeConfig.read(at: file, helper: helper, maxBytes: 1024).userEntry, .notRegistered)
        XCTAssertEqual(ClaudeConfig.maxBytes, 64 << 20)
    }

    func testAnUnparseableFileIsUnreadable() throws {
        let file = try temporaryFolder().appendingPathComponent(".claude.json")
        try Data("{ broken".utf8).write(to: file)

        XCTAssertThrowsError(try ClaudeConfig.read(at: file, helper: helper)) { error in
            XCTAssertEqual(error as? AgentConnectError, .unreadableConfig)
        }
    }

    // MARK: - Parsing

    func testAMissingEntryIsNotRegistered() {
        XCTAssertEqual(status("{}"), .notRegistered)
        XCTAssertEqual(status(#"{"mcpServers":{"other":{"command":"/x"}}}"#), .notRegistered)
        XCTAssertEqual(summary("{}")?.hasUserEntry, false)
    }

    func testAnEntryRunningOurHelperIsConnected() {
        let json = #"{"mcpServers":{"canvas":{"type":"stdio","command":"/Applications/Canvas.app/Contents/Helpers/canvas-mcp","args":[]}}}"#

        XCTAssertEqual(status(json), .connected)
        XCTAssertEqual(summary(json)?.hasUserEntry, true)
    }

    func testPathsAreComparedAfterResolvingSymlinksAndDots() throws {
        let folder = try temporaryFolder()
        let real = folder.appendingPathComponent("Real/Canvas.app/Contents/Helpers/canvas-mcp")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: real)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Link"), withDestinationURL: folder.appendingPathComponent("Real"))
        let viaLink = folder.appendingPathComponent("Link/Canvas.app/Contents/../Contents/Helpers/canvas-mcp").path

        XCTAssertEqual(status(#"{"mcpServers":{"canvas":{"command":"\#(viaLink)"}}}"#, helper: real), .connected)
    }

    func testAnEntryForAnotherHelperNeedsReconnecting() {
        XCTAssertEqual(status(#"{"mcpServers":{"canvas":{"command":"/Old/canvas-mcp"}}}"#), .needsReconnect(reason: "It points at /Old/canvas-mcp."))
    }

    func testAnEntryWithoutALocalCommandNeedsReconnecting() {
        XCTAssertEqual(status(#"{"mcpServers":{"canvas":{"type":"http","url":"http://x"}}}"#), .needsReconnect(reason: "Its entry doesn't run a local command."))
    }

    func testAnUnreadableConfigIsUnknownNeverConnected() {
        XCTAssertNil(summary("not json"))
        XCTAssertNil(summary(#"["a"]"#))
        XCTAssertNil(summary(#"{"mcpServers":[]}"#))
        XCTAssertNil(summary(#"{"mcpServers":{"canvas":"/Applications/Canvas.app/Contents/Helpers/canvas-mcp"}}"#))
    }

    func testFindsProjectsWithALocalScopeEntry() {
        let json = #"{"projects":{"/b":{"mcpServers":{}},"/a":{"mcpServers":{"canvas":{"command":"/x"}}},"/c":{}}}"#

        XCTAssertEqual(summary(json)?.localScopeProjects, ["/a"])
        XCTAssertEqual(summary("{}")?.localScopeProjects, [])
    }
}
