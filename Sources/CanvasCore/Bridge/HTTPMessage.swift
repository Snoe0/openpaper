import Foundation

/// One HTTP/1.1 request. Bodies need a `Content-Length`; chunked encoding isn't supported.
struct HTTPRequest {
    enum ParseError: Error, Equatable {
        case malformed
        case tooLarge
    }

    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 32 * 1024 * 1024

    var method: String
    /// Without the query string.
    var path: String
    /// Keyed by lowercased name.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var wantsClose: Bool {
        header("connection")?.lowercased() == "close"
    }

    /// Parses the request at the front of `buffer`: nil while it's incomplete, otherwise the request
    /// and how many bytes of `buffer` it used.
    static func parse(_ buffer: Data) throws(ParseError) -> (request: HTTPRequest, length: Int)? {
        try parseHead(buffer)?.complete(in: buffer)
    }

    /// Parses just the request line and headers at the front of `buffer`, so a request can be
    /// judged before its body arrives; nil while they're incomplete.
    static func parseHead(_ buffer: Data) throws(ParseError) -> HTTPHead? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > maxHeaderBytes { throw .tooLarge }
            return nil
        }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let request = try parseRequestLineAndHeaders(head)
        return HTTPHead(
            request: request,
            headLength: buffer.distance(from: buffer.startIndex, to: headerEnd.upperBound),
            bodyLength: try contentLength(of: request)
        )
    }

    /// The request line and headers, e.g. `POST /mcp HTTP/1.1` then `Name: value` lines.
    private static func parseRequestLineAndHeaders(_ head: String) throws(ParseError) -> HTTPRequest {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw .malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = requestLine[1]
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return HTTPRequest(method: String(requestLine[0]), path: String(path), headers: headers, body: Data())
    }

    private static func contentLength(of request: HTTPRequest) throws(ParseError) -> Int {
        guard request.header("transfer-encoding") == nil else { throw .malformed }
        guard let value = request.header("content-length") else { return 0 }
        guard let length = Int(value), length >= 0 else { throw .malformed }
        guard length <= maxBodyBytes else { throw .tooLarge }
        return length
    }
}

/// A request's line and headers, parsed before its body.
struct HTTPHead {
    /// The request, with an empty body.
    var request: HTTPRequest
    var headLength: Int
    var bodyLength: Int

    /// The whole request once `buffer` (which starts with this head) holds its body; nil until then.
    func complete(in buffer: Data) -> (request: HTTPRequest, length: Int)? {
        let length = headLength + bodyLength
        guard buffer.count >= length else { return nil }
        let bodyStart = buffer.index(buffer.startIndex, offsetBy: headLength)
        var request = request
        request.body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: bodyLength)])
        return (request, length)
    }
}

struct HTTPResponse {
    var status: Int
    var reason: String
    var contentType: String?
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ body: Data) -> HTTPResponse {
        HTTPResponse(status: 200, reason: "OK", contentType: "application/json", body: body)
    }

    static let accepted = HTTPResponse(status: 202, reason: "Accepted")
    static let badRequest = HTTPResponse(status: 400, reason: "Bad Request")
    static let unauthorized = HTTPResponse(status: 401, reason: "Unauthorized", headers: ["WWW-Authenticate": "Bearer"])
    static let notFound = HTTPResponse(status: 404, reason: "Not Found")
    static let methodNotAllowed = HTTPResponse(status: 405, reason: "Method Not Allowed")
    static let payloadTooLarge = HTTPResponse(status: 413, reason: "Payload Too Large")

    func serialized(closing: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        if closing { head += "Connection: close\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}
