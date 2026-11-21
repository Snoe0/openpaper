import Network
import XCTest
@testable import CanvasCore

final class BridgeServerTests: XCTestCase {
    @MainActor
    func testServesMCPOverLocalhostHTTPWithABearerToken() async throws {
        let bridgeFile = try temporaryBridgeFileURL()
        let server = BridgeServer(controller: MockCanvasController(document: try makeDocument()), bridgeFileURL: bridgeFile)
        try await server.start()
        defer { server.stop() }

        let info = try readBridgeFile(bridgeFile)
        XCTAssertEqual(info.pid, Int(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(info.token.count, 64)
        XCTAssertTrue(info.token.allSatisfy(\.isHexDigit), info.token)
        XCTAssertEqual(server.status.port, info.port)
        XCTAssertTrue(server.status.isListening)
        let permissions = try FileManager.default.attributesOfItem(atPath: bridgeFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        let ping = try await post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, port: info.port, token: info.token)
        XCTAssertEqual(ping.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: ping.body)["result"], [:])

        let tool = try await post(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_pages","arguments":{}}}"#,
            port: info.port, token: info.token
        )
        XCTAssertEqual(tool.status, 200)
        XCTAssertEqual(server.status.lastCall?.name, "list_pages")

        let notification = try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, port: info.port, token: info.token)
        XCTAssertEqual(notification.status, 202)
        XCTAssertTrue(notification.body.isEmpty)

        let noToken = try await post(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, port: info.port, token: nil)
        let wrongToken = try await post(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#, port: info.port, token: "x" + info.token.dropFirst())
        let wrongPath = try await post(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#, port: info.port, path: "/other", token: info.token)
        XCTAssertEqual(noToken.status, 401)
        XCTAssertEqual(wrongToken.status, 401)
        XCTAssertEqual(wrongPath.status, 404)
    }

    @MainActor
    func testRejectsBadRequestsFromTheirHeadersWithoutReadingTheBody() async throws {
        let (server, info) = try await startServer()
        defer { server.stop() }
        let bigBody = "Content-Length: 10000000\r\n\r\n"

        let unauthorized = try await exchange("POST /mcp HTTP/1.1\r\nAuthorization: Bearer nope\r\n" + bigBody, port: info.port)
        XCTAssertEqual(unauthorized.response?.status, 401)
        XCTAssertEqual(unauthorized.response?.headers["www-authenticate"], "Bearer")
        XCTAssertTrue(unauthorized.closed)

        let notFound = try await exchange("POST /elsewhere HTTP/1.1\r\nAuthorization: Bearer \(info.token)\r\n" + bigBody, port: info.port)
        XCTAssertEqual(notFound.response?.status, 404)
        XCTAssertTrue(notFound.closed)

        let wrongMethod = try await exchange("GET /mcp HTTP/1.1\r\nAuthorization: Bearer \(info.token)\r\n\r\n", port: info.port)
        XCTAssertEqual(wrongMethod.response?.status, 405)
        XCTAssertTrue(wrongMethod.closed)

        let tooLarge = try await exchange("POST /mcp HTTP/1.1\r\nAuthorization: Bearer \(info.token)\r\nContent-Length: 99999999999\r\n\r\n", port: info.port)
        XCTAssertEqual(tooLarge.response?.status, 413)
        XCTAssertTrue(tooLarge.closed)

        let malformed = try await exchange("NONSENSE\r\n\r\n", port: info.port)
        XCTAssertEqual(malformed.response?.status, 400)
        XCTAssertTrue(malformed.closed)
    }

    @MainActor
    func testAcceptsTheBearerSchemeInAnyCase() async throws {
        let (server, info) = try await startServer()
        defer { server.stop() }

        let lowercase = try await exchange(rawPing(token: info.token, scheme: "bearer", closing: true), port: info.port)

        XCTAssertEqual(lowercase.response?.status, 200)
    }

    @MainActor
    func testServesSeveralRequestsOnOneConnectionUntilAskedToClose() async throws {
        let (server, info) = try await startServer()
        defer { server.stop() }
        let socket = try RawSocket(port: info.port)

        try socket.send(rawPing(token: info.token))
        let first = try await offMain { try socket.readResponse() }
        try socket.send(rawPing(token: info.token, closing: true))
        let second = try await offMain { try socket.readResponse() }
        let rest = try await offMain { try socket.readUntilClosed() }

        XCTAssertEqual(first?.status, 200)
        XCTAssertNil(first?.headers["connection"])
        XCTAssertEqual(second?.status, 200)
        XCTAssertEqual(second?.headers["connection"], "close")
        XCTAssertTrue(rest.isEmpty)
    }

    @MainActor
    func testClosesConnectionsThatSendNoCompleteRequestInTime() async throws {
        let (server, info) = try await startServer(idleTimeout: .milliseconds(300))
        defer { server.stop() }
        let socket = try RawSocket(port: info.port)
        let started = ContinuousClock.now

        try socket.send("POST /mcp HTTP/1.1\r\n")
        let received = try await offMain { try socket.readUntilClosed() }

        XCTAssertTrue(received.isEmpty)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(15))
    }

    @MainActor
    func testRefusesConnectionsBeyondTheCap() async throws {
        let (server, info) = try await startServer(maxConnections: 2)
        defer { server.stop() }
        let first = try RawSocket(port: info.port)
        let second = try RawSocket(port: info.port)
        for socket in [first, second] {
            try socket.send(rawPing(token: info.token))
            let response = try await offMain { try socket.readResponse() }
            XCTAssertEqual(response?.status, 200)
        }

        let third = try RawSocket(port: info.port)
        try? third.send(rawPing(token: info.token))
        let refused = try await offMain { try third.readUntilClosed() }
        try first.send(rawPing(token: info.token))
        let stillServed = try await offMain { try first.readResponse() }

        XCTAssertTrue(refused.isEmpty, String(decoding: refused, as: UTF8.self))
        XCTAssertEqual(stillServed?.status, 200)
    }

    @MainActor
    func testListensOnLoopbackOnly() async throws {
        guard let address = nonLoopbackIPv4Address() else { throw XCTSkip("no non-loopback IPv4 address") }
        let (server, info) = try await startServer()
        defer { server.stop() }

        XCTAssertThrowsError(try RawSocket(host: address, port: info.port, timeout: 5), "reachable at \(address)")
    }

    @MainActor
    func testStopRemovesTheBridgeFileAndStopsListening() async throws {
        let bridgeFile = try temporaryBridgeFileURL()
        let server = BridgeServer(controller: MockCanvasController(), bridgeFileURL: bridgeFile)
        try await server.start()
        let info = try readBridgeFile(bridgeFile)

        server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: bridgeFile.path))
        XCTAssertNil(server.status.port)
        XCTAssertFalse(server.status.isListening)
        XCTAssertThrowsError(try RawSocket(port: info.port, timeout: 5))
    }

    @MainActor
    func testStopLeavesABridgeFileWrittenByAnotherInstance() async throws {
        let bridgeFile = try temporaryBridgeFileURL()
        let server = BridgeServer(controller: MockCanvasController(), bridgeFileURL: bridgeFile)
        try await server.start()
        let other = #"{"port":1,"token":"someone-else","pid":1}"#
        try Data(other.utf8).write(to: bridgeFile)

        server.stop()

        XCTAssertEqual(try String(contentsOf: bridgeFile, encoding: .utf8), other)
    }

    @MainActor
    func testAListenerThatEndsOnItsOwnStopsTheServerAndItCanRestart() async throws {
        let bridgeFile = try temporaryBridgeFileURL()
        let server = BridgeServer(controller: MockCanvasController(), bridgeFileURL: bridgeFile)
        try await server.start()
        defer { server.stop() }
        let info = try readBridgeFile(bridgeFile)

        server.listener?.cancel()

        let stopped = try await eventually(timeout: .seconds(20)) { server.status.port == nil }
        XCTAssertTrue(stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridgeFile.path))
        try await server.start()
        let restarted = try readBridgeFile(bridgeFile)
        XCTAssertEqual(server.status.port, restarted.port)
        XCTAssertEqual(restarted.token, info.token)
    }

    func testStartupTreatsWaitingOrFailingListenersAsFailures() throws {
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: 4321))

        XCTAssertNil(BridgeServer.startupResult(.setup, port: nil))
        XCTAssertEqual(try BridgeServer.startupResult(.ready, port: port)?.get(), 4321)
        XCTAssertThrowsError(try BridgeServer.startupResult(.waiting(.posix(.EADDRINUSE)), port: nil)?.get())
        XCTAssertThrowsError(try BridgeServer.startupResult(.failed(.posix(.EACCES)), port: nil)?.get())
        XCTAssertThrowsError(try BridgeServer.startupResult(.cancelled, port: nil)?.get())
    }

    @MainActor
    func testReleasingAStartedServerStopsIt() async throws {
        let bridgeFile = try temporaryBridgeFileURL()
        var server: BridgeServer? = BridgeServer(controller: MockCanvasController(), bridgeFileURL: bridgeFile)
        try await server?.start()
        let info = try readBridgeFile(bridgeFile)

        server = nil

        let removed = try await eventually(timeout: .seconds(20)) { !FileManager.default.fileExists(atPath: bridgeFile.path) }
        XCTAssertTrue(removed)
        XCTAssertThrowsError(try RawSocket(port: info.port, timeout: 5))
    }

    // MARK: - Helpers

    @MainActor
    private func startServer(
        idleTimeout: Duration = BridgeServer.defaultIdleTimeout, maxConnections: Int = BridgeServer.defaultMaxConnections
    ) async throws -> (BridgeServer, BridgeFileContents) {
        let bridgeFile = try temporaryBridgeFileURL()
        let server = BridgeServer(
            controller: MockCanvasController(), bridgeFileURL: bridgeFile,
            idleTimeout: idleTimeout, maxConnections: maxConnections
        )
        try await server.start()
        return (server, try readBridgeFile(bridgeFile))
    }
}

/// Sends `request` on a new connection, reads one response, then whether the server closed the connection.
private func exchange(_ request: String, port: UInt16) async throws -> (response: RawResponse?, closed: Bool) {
    let socket = try RawSocket(port: port)
    try socket.send(request)
    return try await offMain {
        let response = try socket.readResponse()
        let closed = (try? socket.readUntilClosed()) != nil
        return (response, closed)
    }
}

// MARK: - Shared helpers

struct BridgeFileContents: Decodable {
    let port: UInt16
    let token: String
    let pid: Int
}

extension XCTestCase {
    /// A not-yet-existing `bridge.json` in a temp folder that doesn't exist yet either.
    func temporaryBridgeFileURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasBridgeTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("Canvas/bridge.json")
    }
}

func readBridgeFile(_ url: URL) throws -> BridgeFileContents {
    try JSONDecoder().decode(BridgeFileContents.self, from: Data(contentsOf: url))
}

/// POSTs `body` to the bridge on localhost.
func post(_ body: String, port: UInt16, path: String = "/mcp", token: String?) async throws -> (status: Int, body: Data) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
}
