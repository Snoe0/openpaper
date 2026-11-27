import Foundation
import Network

/// One client connection. Reads HTTP requests in order and answers each before reading the next (keep-alive).
/// `screen` judges a request from its headers alone, so a rejected one is answered and the connection closed
/// without reading its body. Closes on errors, on `Connection: close`, when the client hangs up, or when no
/// complete request arrives within `idleTimeout`. Runs on the main queue, so network callbacks are main-actor isolated.
@MainActor
final class BridgeConnection {
    typealias Screen = @MainActor (HTTPRequest) -> HTTPResponse?
    typealias Responder = @MainActor (HTTPRequest) async -> HTTPResponse

    private static let readSize = 64 * 1024

    private let connection: NWConnection
    private let idleTimeout: Duration
    private let screen: Screen
    private let respond: Responder
    private let onClose: @MainActor (BridgeConnection) -> Void
    private var buffer = Data()
    private var idleTimer: Task<Void, Never>?
    private var isResponding = false
    private var clientFinished = false
    private var isClosed = false

    init(
        _ connection: NWConnection, idleTimeout: Duration,
        screen: @escaping Screen, respond: @escaping Responder, onClose: @escaping @MainActor (BridgeConnection) -> Void
    ) {
        self.connection = connection
        self.idleTimeout = idleTimeout
        self.screen = screen
        self.respond = respond
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(to: state) }
        }
        connection.start(queue: .main)
        armIdleTimer()
        receive()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        idleTimer?.cancel()
        connection.cancel()
        onClose(self)
    }

    private func stateChanged(to state: NWConnection.State) {
        switch state {
        case .failed, .cancelled: close()
        default: break
        }
    }

    // MARK: - Reading

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated { self?.received(data, clientFinished: isComplete || error != nil) }
        }
    }

    private func received(_ data: Data?, clientFinished: Bool) {
        if let data { buffer.append(data) }
        if clientFinished { self.clientFinished = true }
        serveNextRequest()
    }

    private func readMore() {
        clientFinished ? close() : receive()
    }

    /// Answers the next request in the buffer once complete; rejects it as soon as its headers allow.
    private func serveNextRequest() {
        guard !isClosed, !isResponding else { return }
        do throws(HTTPRequest.ParseError) {
            guard let head = try HTTPRequest.parseHead(buffer) else { return readMore() }
            if let rejection = screen(head.request) { return send(rejection, closing: true) }
            guard let (request, length) = head.complete(in: buffer) else { return readMore() }
            buffer = Data(buffer.dropFirst(length))
            idleTimer?.cancel()
            isResponding = true
            Task { await answer(request) }
        } catch .tooLarge {
            send(.payloadTooLarge, closing: true)
        } catch {
            send(.badRequest, closing: true)
        }
    }

    /// Closes the connection unless a complete request arrives within `idleTimeout`.
    private func armIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self, idleTimeout] in
            try? await Task.sleep(for: idleTimeout)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    // MARK: - Writing

    private func answer(_ request: HTTPRequest) async {
        let response = await respond(request)
        send(response, closing: request.wantsClose || clientFinished)
    }

    private func send(_ response: HTTPResponse, closing: Bool) {
        guard !isClosed else { return }
        isResponding = true
        connection.send(content: response.serialized(closing: closing), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.sent(closing: closing) }
        })
    }

    private func sent(closing: Bool) {
        isResponding = false
        guard !closing else { return close() }
        armIdleTimer()
        serveNextRequest()
    }
}
