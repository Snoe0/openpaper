import XCTest
@testable import CanvasCore

/// Runs the built `canvas-mcp` binary, found next to the test bundle in the build products folder.
final class BridgeCLITests: XCTestCase {
    func testPrintsItsVersion() async throws {
        let run = try await runCLI(["--version"], input: "", environment: [:])

        XCTAssertEqual(run.status, 0)
        XCTAssertEqual(run.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "canvas-mcp \(CanvasCore.version)")
    }

    @MainActor
    func testPipesStdioMessagesToTheRunningApp() async throws {
        let bridgeFile = try temporaryBridgeFileURL()
        let server = BridgeServer(controller: MockCanvasController(document: try makeDocument()), bridgeFileURL: bridgeFile)
        try await server.start()
        defer { server.stop() }

        let run = try await runCLI([], input: """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cli-test","version":"1"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}

        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_artboard","arguments":{"name":"Hero","width":10,"height":10}}}

        """, environment: ["CANVAS_BRIDGE_FILE": bridgeFile.path, "CANVAS_NO_LAUNCH": "1"])

        XCTAssertEqual(run.status, 0, run.stderr)
        let lines = run.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, run.stdout)
        let responses = try lines.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(responses.first?["id"], 1)
        XCTAssertEqual(responses.first?["result"]?["serverInfo"]?["name"], "canvas")
        XCTAssertEqual(responses.last?["id"], 2)
        XCTAssertEqual(responses.last?["result"]?["isError"], false)
        XCTAssertEqual(server.status.client?.name, "cli-test")
        XCTAssertEqual(server.status.lastCall?.name, "create_artboard")
    }

    func testRepliesWithAnErrorWhenCanvasIsNotRunning() async throws {
        let missing = try temporaryBridgeFileURL()

        let run = try await runCLI([], input: """
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":"a","method":"ping"}

        """, environment: ["CANVAS_BRIDGE_FILE": missing.path, "CANVAS_NO_LAUNCH": "1"])

        XCTAssertEqual(run.status, 0, run.stderr)
        let lines = run.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, run.stdout)
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(lines[0].utf8))
        XCTAssertEqual(response["id"], "a")
        XCTAssertNotNil(response["error"]?["code"]?.int)
        XCTAssertTrue(response["error"]?["message"]?.string?.contains("Canvas") == true, run.stdout)
    }

    @MainActor
    func testTreatsABridgeFileOfADeadProcessAsNotRunning() async throws {
        let (server, info, bridgeFile) = try await startServer()
        defer { server.stop() }
        try writeBridgeFile(port: info.port, token: info.token, pid: deadProcessID(), to: bridgeFile)

        let run = try await runCLI([], input: pingLine, environment: ["CANVAS_BRIDGE_FILE": bridgeFile.path, "CANVAS_NO_LAUNCH": "1"])

        let message = try errorMessage(in: run)
        XCTAssertTrue(message.contains("isn't running"), message)
        XCTAssertNil(server.status.lastCall)
    }

    @MainActor
    func testReportsARejectedTokenAsSuch() async throws {
        let (server, info, bridgeFile) = try await startServer()
        defer { server.stop() }
        try writeBridgeFile(port: info.port, token: "wrong", pid: ProcessInfo.processInfo.processIdentifier, to: bridgeFile)

        let run = try await runCLI([], input: pingLine, environment: ["CANVAS_BRIDGE_FILE": bridgeFile.path])

        let message = try errorMessage(in: run)
        XCTAssertTrue(message.contains("token"), message)
    }

    func testFailsFastWhenCanvasCannotBeLaunched() async throws {
        let missing = try temporaryBridgeFileURL()
        let started = ContinuousClock.now

        let run = try await runCLI([], input: pingLine + pingLine, environment: [
            "CANVAS_BRIDGE_FILE": missing.path, "CANVAS_APP_BUNDLE_ID": "invalid.canvas.test.missing-app",
        ])

        let lines = run.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, run.stdout)
        for line in lines {
            let response = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            let message = response["error"]?["message"]?.string ?? ""
            XCTAssertTrue(message.contains("Couldn't launch Canvas"), message)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(14), "no 15 s launch wait, and none for the second message")
        XCTAssertEqual(run.stderr.components(separatedBy: "launching it").count - 1, 1, run.stderr)
    }

    // MARK: - Helpers

    private let pingLine = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n"

    @MainActor
    private func startServer() async throws -> (BridgeServer, BridgeFileContents, URL) {
        let bridgeFile = try temporaryBridgeFileURL()
        let server = BridgeServer(controller: MockCanvasController(), bridgeFileURL: bridgeFile)
        try await server.start()
        return (server, try readBridgeFile(bridgeFile), bridgeFile)
    }

    private func writeBridgeFile(port: UInt16, token: String, pid: Int32, to url: URL) throws {
        try Data(#"{"port":\#(port),"token":"\#(token)","pid":\#(pid)}"#.utf8).write(to: url)
    }

    /// The id of a process that has exited.
    private func deadProcessID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    /// The error message of the single response canvas-mcp printed.
    private func errorMessage(in run: CLIRun) throws -> String {
        XCTAssertEqual(run.status, 0, run.stderr)
        let lines = run.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, run.stdout)
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(lines.first).utf8))
        return try XCTUnwrap(response["error"]?["message"]?.string, run.stdout)
    }
}

// MARK: - Running canvas-mcp

private struct CLIRun {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func canvasMCPURL() throws -> URL {
    let url = Bundle(for: BridgeCLITests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("canvas-mcp")
    guard FileManager.default.isExecutableFile(atPath: url.path) else {
        throw XCTSkip("canvas-mcp isn't built next to the test bundle at \(url.path)")
    }
    return url
}

/// Runs canvas-mcp with `input` on stdin until it exits, without blocking the main actor (which serves the bridge).
/// A watchdog kills it after `timeout`, so a hung CLI fails the test instead of hanging it.
private func runCLI(
    _ arguments: [String], input: String, environment: [String: String], timeout: Duration = .seconds(90)
) async throws -> CLIRun {
    let process = Process()
    process.executableURL = try canvasMCPURL()
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let watchdog = killAfter(timeout, processID: process.processIdentifier)

    try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try stdin.fileHandleForWriting.close()
    async let output = readToEnd(stdout.fileHandleForReading)
    async let errors = readToEnd(stderr.fileHandleForReading)
    let (out, err) = try await (output, errors)
    watchdog.cancel()
    if await watchdog.value { XCTFail("canvas-mcp didn't exit within \(timeout)") }
    while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    return CLIRun(status: process.terminationStatus, stdout: out, stderr: err)
}

/// Kills the process after `timeout` unless cancelled first; true when it had to.
private func killAfter(_ timeout: Duration, processID: Int32) -> Task<Bool, Never> {
    Task.detached {
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return false }
        kill(processID, SIGKILL)
        return true
    }
}

private func readToEnd(_ handle: FileHandle) async throws -> String {
    let data = try await Task.detached { try handle.readToEnd() ?? Data() }.value
    return String(decoding: data, as: UTF8.self)
}
