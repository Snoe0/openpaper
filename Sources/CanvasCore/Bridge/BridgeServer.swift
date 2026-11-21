import Foundation
import Network

/// The app's MCP endpoint: `POST /mcp` on 127.0.0.1 at a random port, guarded by a random bearer token.
/// `start()` publishes the port and token in `bridge.json` for `canvas-mcp`; `stop()` removes it, as does
/// releasing the server or its listener failing. Networking runs on the main queue, and every tool call
/// runs on the main actor.
///
/// The server holds its controller strongly: it is meant to be created by, and live as long as, the app.
/// Tool calls can interleave while one awaits (e.g. `screenshot`); see `CanvasController`.
@MainActor
public final class BridgeServer {
    public static var defaultBridgeFileURL: URL { BridgeFile.defaultURL }
    /// How long a connection may go without sending a complete request before it's closed.
    public static let defaultIdleTimeout: Duration = .seconds(60)
    /// Connections beyond this many are closed right away.
    public static let defaultMaxConnections = 32

    public let status = BridgeStatus()
    private let handler: MCPHandler
    private let bridgeFileURL: URL
    private let idleTimeout: Duration
    private let maxConnections: Int
    private let token = BridgeServer.makeToken()
    private(set) var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, Error>?
    private var connections: [ObjectIdentifier: BridgeConnection] = [:]

    public init(
        controller: any CanvasController,
        bridgeFileURL: URL = BridgeServer.defaultBridgeFileURL,
        idleTimeout: Duration = BridgeServer.defaultIdleTimeout,
        maxConnections: Int = BridgeServer.defaultMaxConnections
    ) {
        self.bridgeFileURL = bridgeFileURL
        self.idleTimeout = idleTimeout
        self.maxConnections = maxConnections
        handler = MCPHandler(controller: controller, status: status)
    }

    isolated deinit {
        stop()
    }

    /// Starts listening and writes `bridge.json`; does nothing if already started.
    public func start() async throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: Self.loopbackOnly())
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated { self?.listenerChanged(listener, to: state) }
        }
        self.listener = listener
        do {
            let port = try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                listener.start(queue: .main)
            }
            try BridgeFile(port: port, token: token, pid: getpid()).write(to: bridgeFileURL)
            status.port = port
        } catch {
            stop()
            throw error
        }
    }

    /// Stops listening, closes open connections and removes `bridge.json`.
    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in Array(connections.values) { connection.close() }
        BridgeFile.remove(at: bridgeFileURL, ifToken: token)
        status.port = nil
    }

    // MARK: - Listener

    /// What a listener state means while starting: nil to keep waiting, otherwise its port or why it can't listen.
    nonisolated static func startupResult(_ state: NWListener.State, port: NWEndpoint.Port?) -> Result<UInt16, Error>? {
        switch state {
        case .ready: port.map { .success($0.rawValue) } ?? .failure(POSIXError(.EADDRNOTAVAIL))
        case .waiting(let error), .failed(let error): .failure(error)
        case .cancelled: .failure(CancellationError())
        default: nil
        }
    }

    /// Finishes `start()` once the listener is ready or can't be; afterwards, stops the server (clearing
    /// the status and `bridge.json`) if the listener fails or is cancelled by anything other than `stop()`.
    private func listenerChanged(_ listener: NWListener?, to state: NWListener.State) {
        if let startup {
            guard let result = Self.startupResult(state, port: listener?.port) else { return }
            self.startup = nil
            return startup.resume(with: result)
        }
        switch state {
        case .failed, .cancelled:
            if let listener, listener === self.listener { stop() }
        default:
            break
        }
    }

    private nonisolated static func loopbackOnly() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        return parameters
    }

    // MARK: - Connections

    private func accept(_ nwConnection: NWConnection) {
        guard connections.count < maxConnections else { return refuse(nwConnection) }
        let connection = BridgeConnection(
            nwConnection, idleTimeout: idleTimeout,
            screen: { [weak self] request in
                guard let self else { return .notFound }
                return rejection(for: request)
            },
            respond: { [weak self] request in await self?.respond(to: request) ?? .notFound },
            onClose: { [weak self] connection in self?.connections[ObjectIdentifier(connection)] = nil }
        )
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    private func refuse(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.cancel()
    }

    /// The answer to a request that its headers already rule out, or nil when it may go ahead.
    private func rejection(for request: HTTPRequest) -> HTTPResponse? {
        guard request.path == "/mcp" else { return .notFound }
        guard isAuthorized(request) else { return .unauthorized }
        guard request.method == "POST" else { return .methodNotAllowed }
        return nil
    }

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard let body = await handler.handle(request.body) else { return .accepted }
        return .json(body)
    }

    /// `Authorization: Bearer <token>`, with the scheme in any case.
    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let parts = request.header("authorization")?.split(separator: " ", maxSplits: 1),
              parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        return Self.constantTimeEquals(parts[1].trimmingCharacters(in: .whitespaces), token)
    }

    // MARK: - Token

    /// 256 random bits, hex-encoded.
    private nonisolated static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// Compares without returning early, so response timing doesn't reveal how much of a token matched.
    private nonisolated static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
