import Foundation

/// A blocking TCP client for sending hand-written HTTP to the bridge. Reads block (up to `timeout`),
/// so call them through `offMain` while the main actor serves the bridge.
final class RawSocket: @unchecked Sendable {
    private let descriptor: Int32
    private var pending = Data()

    init(host: String = "127.0.0.1", port: UInt16, timeout: Int = 20) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.lastError() }
        var receiveTimeout = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let error = Self.lastError()
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(descriptor)
    }

    func send(_ text: String) throws {
        let data = Data(text.utf8)
        let sent = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        guard sent == data.count else { throw Self.lastError() }
    }

    /// The next response (head plus `Content-Length` body), or nil if the server closed the connection first.
    func readResponse() throws -> RawResponse? {
        while true {
            if let response = RawResponse.take(from: &pending) { return response }
            guard let chunk = try readChunk() else { return nil }
            pending.append(chunk)
        }
    }

    /// Everything until the server closes the connection; throws if it stays open past the timeout.
    func readUntilClosed() throws -> Data {
        var all = pending
        pending = Data()
        while let chunk = try readChunk() { all.append(chunk) }
        return all
    }

    private func readChunk() throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count > 0 { return Data(buffer[0..<count]) }
        if count == 0 || errno == ECONNRESET { return nil }
        throw Self.lastError()
    }

    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

struct RawResponse: Sendable {
    let status: Int
    /// Keyed by lowercased name.
    let headers: [String: String]
    let body: Data

    /// Removes one complete response from the front of `buffer`, if there is one.
    static func take(from buffer: inout Data) -> RawResponse? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let status = Int(lines[0].split(separator: " ")[1]) ?? 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.distance(from: headEnd.upperBound, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(headEnd.upperBound, offsetBy: length)
        let response = RawResponse(status: status, headers: headers, body: Data(buffer[headEnd.upperBound..<bodyEnd]))
        buffer = Data(buffer[bodyEnd...])
        return response
    }
}

/// Runs blocking work on a background thread, keeping the main actor free to serve the bridge.
func offMain<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await Task.detached(operation: work).value
}

/// A POST of a JSON-RPC ping, optionally asking the server to close the connection afterwards.
func rawPing(token: String, scheme: String = "Bearer", closing: Bool = false) -> String {
    let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
    return "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: \(scheme) \(token)\r\n"
        + (closing ? "Connection: close\r\n" : "")
        + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
}

/// A non-loopback IPv4 address of this machine, if it has one.
func nonLoopbackIPv4Address() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
    defer { freeifaddrs(interfaces) }
    for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
              interface.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
              interface.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        return String(cString: host)
    }
    return nil
}
