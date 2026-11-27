import XCTest
@testable import CanvasCore

final class ShellAgentConnectorTests: XCTestCase {
    private let helper = URL(fileURLWithPath: "/Applications/Canvas.app/Contents/Helpers/canvas-mcp")
    private var registration: MCPRegistration { MCPRegistration(helper: helper) }
    private let found = CommandResult(status: 0, stdout: "hi from .zshrc\nCANVAS_CLAUDE=/opt/bin/claude\nCANVAS_PATH=/opt/bin:/usr/bin\n", stderr: "")
    private let notFound = CommandResult(status: 0, stdout: "CANVAS_CLAUDE=\nCANVAS_PATH=/usr/bin\n", stderr: "")
    private let ok = CommandResult(status: 0, stdout: "Done", stderr: "")
    private let ours = #"{"mcpServers":{"canvas":{"type":"stdio","command":"/Applications/Canvas.app/Contents/Helpers/canvas-mcp","args":[]}}}"#
    private let old = #"{"mcpServers":{"canvas":{"type":"stdio","command":"/Old/canvas-mcp","args":[]}}}"#

    /// A connector whose Claude config file holds `config` (nil: no file).
    private func connector(_ runner: FakeRunner, config: String? = nil, executables: Set<String> = []) throws -> AgentConnector {
        let configURL = try temporaryDocumentURL().deletingLastPathComponent().appendingPathComponent(".claude.json")
        try config.map { try Data($0.utf8).write(to: configURL) }
        return AgentConnector(
            runner: runner, environment: ["PATH": "/usr/bin", "HOME": "/Users/me"],
            shell: URL(fileURLWithPath: "/bin/zsh"), home: "/Users/me", configURL: configURL, isExecutable: { executables.contains($0) }
        )
    }

    // MARK: - Commands

    func testTheHelperLivesInTheAppBundle() {
        let app = URL(fileURLWithPath: "/Applications/Canvas.app")

        XCTAssertEqual(MCPRegistration.helperURL(inApp: app).path, "/Applications/Canvas.app/Contents/Helpers/canvas-mcp")
    }

    func testCommandsAreArgvArrays() {
        let registration = MCPRegistration(helper: URL(fileURLWithPath: "/My Apps/Canvas.app/Contents/Helpers/canvas-mcp"))

        XCTAssertEqual(registration.addArguments, ["mcp", "add", "--scope", "user", "canvas", "--", "/My Apps/Canvas.app/Contents/Helpers/canvas-mcp"])
        XCTAssertEqual(registration.removeArguments, ["mcp", "remove", "--scope", "user", "canvas"])
    }

    func testTheDisplayedCommandsQuoteOnlyWhatNeedsIt() {
        XCTAssertEqual(registration.addCommand, "claude mcp add --scope user canvas -- /Applications/Canvas.app/Contents/Helpers/canvas-mcp")
        XCTAssertEqual(registration.removeCommand, "claude mcp remove --scope user canvas")
        XCTAssertEqual(
            MCPRegistration(helper: URL(fileURLWithPath: "/Bob's Apps/canvas-mcp")).addCommand,
            "claude mcp add --scope user canvas -- '/Bob'\\''s Apps/canvas-mcp'"
        )
    }

    func testAHelperInsideATranslocatedAppIsRecognised() {
        XCTAssertTrue(MCPRegistration(helper: URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Canvas.app/Contents/Helpers/canvas-mcp")).isTranslocated)
        XCTAssertFalse(registration.isTranslocated)
    }

    // MARK: - Finding claude

    func testTheLookupRunsAFixedScriptInAnInteractiveLoginShell() {
        XCTAssertEqual(ClaudeLookup.arguments.first, "-ilc")
        XCTAssertEqual(ClaudeLookup.arguments.count, 2)
        XCTAssertTrue(ClaudeLookup.arguments[1].contains("command -v claude"))
    }

    func testTheLookupUsesTheUsersShellUnlessItIsntPOSIX() {
        XCTAssertEqual(ClaudeLookup.shell(forUserShell: "/bin/bash").path, "/bin/bash")
        XCTAssertEqual(ClaudeLookup.shell(forUserShell: "/opt/homebrew/bin/zsh").path, "/opt/homebrew/bin/zsh")
        XCTAssertEqual(ClaudeLookup.shell(forUserShell: "/opt/homebrew/bin/fish").path, "/bin/zsh")
        XCTAssertEqual(ClaudeLookup.shell(forUserShell: nil).path, "/bin/zsh")
    }

    func testTheLookupSkipsShellNoise() {
        let found = ClaudeLookup.parse("Welcome back!\nCANVAS_CLAUDE=/Users/me/.local/bin/claude\nCANVAS_PATH=/Users/me/.local/bin:/usr/bin\n")

        XCTAssertEqual(found.claude?.path, "/Users/me/.local/bin/claude")
        XCTAssertEqual(found.searchPath, "/Users/me/.local/bin:/usr/bin")
    }

    func testAnAliasOrMissingCommandIsNotFound() {
        XCTAssertNil(ClaudeLookup.parse("CANVAS_CLAUDE=alias claude='npx claude'\nCANVAS_PATH=/usr/bin\n").claude)
        XCTAssertNil(ClaudeLookup.parse("CANVAS_CLAUDE=\nCANVAS_PATH=/usr/bin\n").claude)
        XCTAssertNil(ClaudeLookup.parse("").claude)
    }

    func testFallbackLocationsAreTriedInOrder() {
        XCTAssertEqual(ClaudeLookup.fallbackPaths(home: "/Users/me"), [
            "/Users/me/.local/bin/claude", "/Users/me/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ])
    }

    func testWhenTheShellCantFindClaudeAKnownLocationIsUsed() async throws {
        let runner = FakeRunner([.success(notFound), .success(ok)])

        _ = try await connector(runner, executables: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]).connect(registration)

        let calls = await runner.calls
        XCTAssertEqual(calls[1].executable.path, "/opt/homebrew/bin/claude")
        XCTAssertEqual(calls[1].environment?["PATH"], "/opt/homebrew/bin:/usr/bin")
    }

    func testALookupThatTimesOutStillFallsBack() async throws {
        let runner = FakeRunner([.failure(CommandTimedOut()), .success(ok)])

        let result = try await connector(runner, config: ours, executables: ["/Users/me/.local/bin/claude"]).connect(registration)

        XCTAssertEqual(result.userEntry, .connected)
    }

    func testALookupThatTimesOutWithNoFallbackSaysSo() async throws {
        let connector = try connector(FakeRunner([.failure(CommandTimedOut())]))

        await assertThrows(AgentConnectError.timedOut(step: "finding claude")) { try await connector.connect(self.registration) }
    }

    func testClaudeNotFoundAnywhereIsAClearError() async throws {
        let connector = try connector(FakeRunner([.success(notFound)]))

        await assertThrows(AgentConnectError.claudeNotFound) { try await connector.connect(self.registration) }
        XCTAssertTrue(AgentConnectError.claudeNotFound.localizedDescription.contains("claude"))
    }

    // MARK: - Status

    func testStatusReadsTheConfigWithoutRunningClaude() async throws {
        let runner = FakeRunner([])

        let connected = try await connector(runner, config: ours).status(of: registration)
        let outdated = try await connector(runner, config: old).status(of: registration)
        let missing = try await connector(runner).status(of: registration)

        XCTAssertEqual(connected.userEntry, .connected)
        XCTAssertEqual(outdated.userEntry, .needsReconnect(reason: "It points at /Old/canvas-mcp."))
        XCTAssertEqual(missing.userEntry, .notRegistered)
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testConnectorsReadTheConfigFromClaudeConfigDir() async throws {
        let folder = try temporaryDocumentURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(ours.utf8).write(to: folder.appendingPathComponent(".claude.json"))
        let connector = AgentConnector(runner: FakeRunner([]), environment: ["CLAUDE_CONFIG_DIR": folder.path], home: "/nonexistent")

        let result = try await connector.status(of: registration)

        XCTAssertEqual(result.userEntry, .connected)
    }

    func testAnUnreadableConfigIsAnErrorNotAState() async throws {
        let connector = try connector(FakeRunner([]), config: "{ broken")

        await assertThrows(AgentConnectError.unreadableConfig) { try await connector.status(of: self.registration) }
    }

    // MARK: - Connecting

    func testConnectAddsTheHelperThenReportsWhatTheConfigSays() async throws {
        let runner = FakeRunner([.success(found), .success(ok)])

        let confirmed = try await connector(runner, config: ours).connect(registration)
        let unconfirmed = try await connector(FakeRunner([.success(found), .success(ok)])).connect(registration)

        XCTAssertEqual(confirmed.userEntry, .connected)
        XCTAssertEqual(unconfirmed.userEntry, .notRegistered)
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments), [ClaudeLookup.arguments, registration.addArguments])
        XCTAssertEqual(calls[1].executable.path, "/opt/bin/claude")
        XCTAssertEqual(calls[1].environment?["PATH"], "/opt/bin:/usr/bin")
        XCTAssertEqual(calls[1].environment?["HOME"], "/Users/me")
    }

    func testAnAlreadyExistingEntryIsReadFromTheConfigRatherThanReportedAsAFailure() async throws {
        let exists = CommandResult(status: 1, stdout: "", stderr: "MCP server canvas already exists in user config\n")
        let runner = FakeRunner([.success(found), .success(exists)])

        let result = try await connector(runner, config: old).connect(registration)

        XCTAssertEqual(result.userEntry, .needsReconnect(reason: "It points at /Old/canvas-mcp."))
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments), [ClaudeLookup.arguments, registration.addArguments])
    }

    func testConnectReportsStderrWhenTheCommandFails() async throws {
        let connector = try connector(FakeRunner([.success(found), .success(CommandResult(status: 2, stdout: "", stderr: "Invalid scope\n"))]))

        await assertThrows(AgentConnectError.commandFailed(status: 2, output: "Invalid scope")) { try await connector.connect(self.registration) }
        XCTAssertTrue(AgentConnectError.commandFailed(status: 2, output: "Invalid scope").localizedDescription.contains("Invalid scope"))
    }

    func testATranslocatedAppRefusesToConnect() async throws {
        let runner = FakeRunner([])
        let translocated = MCPRegistration(helper: URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Canvas.app/Contents/Helpers/canvas-mcp"))
        let connector = try connector(runner)

        await assertThrows(AgentConnectError.appTranslocated) { try await connector.connect(translocated) }
        await assertThrows(AgentConnectError.appTranslocated) { try await connector.reconnect(translocated) }
        XCTAssertTrue(AgentConnectError.appTranslocated.localizedDescription.contains("Applications"))
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - Reconnecting

    func testReconnectRemovesTheUserEntryThenAdds() async throws {
        let runner = FakeRunner([.success(found), .success(ok), .success(ok)])

        _ = try await connector(runner, config: old).reconnect(registration)

        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments), [ClaudeLookup.arguments, registration.removeArguments, registration.addArguments])
    }

    func testReconnectWithoutAnEntryOnlyAdds() async throws {
        let runner = FakeRunner([.success(found), .success(ok)])

        _ = try await connector(runner).reconnect(registration)

        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments), [ClaudeLookup.arguments, registration.addArguments])
    }

    func testReconnectExplainsAnEntryOnlyInLocalScope() async throws {
        let local = #"{"projects":{"/Users/me/site":{"mcpServers":{"canvas":{"command":"/Old/canvas-mcp"}}}}}"#
        let runner = FakeRunner([])
        let connector = try connector(runner, config: local)

        await assertThrows(AgentConnectError.registeredInLocalScope(projects: ["/Users/me/site"])) { try await connector.reconnect(self.registration) }
        let message = AgentConnectError.registeredInLocalScope(projects: ["/Users/me/site"]).localizedDescription
        XCTAssertTrue(message.contains("/Users/me/site"))
        XCTAssertTrue(message.contains("local scope"))
        XCTAssertTrue(message.contains("claude mcp remove --scope local canvas"))
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testReconnectStopsWhenRemovingFails() async throws {
        let runner = FakeRunner([.success(found), .success(CommandResult(status: 1, stdout: "", stderr: "permission denied"))])
        let connector = try connector(runner, config: old)

        await assertThrows(AgentConnectError.commandFailed(status: 1, output: "permission denied")) { try await connector.reconnect(self.registration) }
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2)
    }

    // MARK: - Deadlines

    func testATimeoutNamesTheStep() async throws {
        let connector = try connector(FakeRunner([.success(found), .failure(CommandTimedOut())]))

        await assertThrows(AgentConnectError.timedOut(step: "claude mcp add")) { try await connector.connect(self.registration) }
        XCTAssertTrue(AgentConnectError.timedOut(step: "claude mcp add").localizedDescription.contains("claude mcp add"))
    }

    func testEachStepHasADeadline() async throws {
        let runner = FakeRunner([.success(found), .success(ok)])

        _ = try await connector(runner).connect(registration)

        let timeouts = await runner.calls.map(\.timeout)
        XCTAssertEqual(timeouts, [AgentConnector.lookupTimeout, AgentConnector.commandTimeout])
        XCTAssertEqual(AgentConnector.lookupTimeout, .seconds(20))
        XCTAssertEqual(AgentConnector.commandTimeout, .seconds(30))
    }

    // MARK: - Helpers

    private func assertThrows<T>(_ expected: AgentConnectError, file: StaticString = #filePath, line: UInt = #line, _ body: @escaping () async throws -> T) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as AgentConnectError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}

/// Answers each command with the next canned result (or error) and records what was run.
private actor FakeRunner: CommandRunning {
    struct Call: Sendable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]?
        var timeout: Duration
    }

    private var results: [Result<CommandResult, any Error>]
    private(set) var calls: [Call] = []

    init(_ results: [Result<CommandResult, any Error>]) {
        self.results = results
    }

    func run(_ executable: URL, _ arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments, environment: environment, timeout: timeout))
        guard !results.isEmpty else { throw CommandTimedOut() }
        return try results.removeFirst().get()
    }
}
