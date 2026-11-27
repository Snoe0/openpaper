import XCTest
@testable import CanvasCore

final class BridgeHTTPTests: XCTestCase {
    func testWaitsForTheWholeHeaderAndBody() throws {
        XCTAssertNil(try HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Le".utf8)))
        XCTAssertNil(try HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)))
    }

    func testParsesTheHeadBeforeTheBodyArrives() throws {
        let buffer = Data("POST /mcp HTTP/1.1\r\nAuthorization: Bearer x\r\nContent-Length: 5\r\n\r\nab".utf8)

        let head = try XCTUnwrap(HTTPRequest.parseHead(buffer))

        XCTAssertEqual(head.request.path, "/mcp")
        XCTAssertEqual(head.request.header("authorization"), "Bearer x")
        XCTAssertEqual(head.bodyLength, 5)
        XCTAssertNil(head.complete(in: buffer))
        XCTAssertEqual(head.complete(in: buffer + Data("cde".utf8))?.request.body, Data("abcde".utf8))
    }

    func testParsesMethodPathHeadersAndBody() throws {
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nauthorization:  Bearer abc \r\nContent-Length: 5\r\n\r\nhello"

        let (request, length) = try XCTUnwrap(HTTPRequest.parse(Data(raw.utf8)))

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.header("Authorization"), "Bearer abc")
        XCTAssertEqual(request.body, Data("hello".utf8))
        XCTAssertEqual(length, raw.utf8.count)
        XCTAssertFalse(request.wantsClose)
    }

    func testParsesOnlyTheFirstOfPipelinedRequests() throws {
        let first = "GET / HTTP/1.1\r\nConnection: close\r\n\r\n"
        let buffer = Data((first + "POST /mcp HTTP/1.1\r\nContent-Length: 0\r\n\r\n").utf8)

        let (request, length) = try XCTUnwrap(HTTPRequest.parse(buffer))
        let (second, _) = try XCTUnwrap(HTTPRequest.parse(Data(buffer.dropFirst(length))))

        XCTAssertEqual(request.method, "GET")
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertTrue(request.wantsClose)
        XCTAssertEqual(second.method, "POST")
    }

    func testRejectsMalformedAndOversizedRequests() {
        XCTAssertThrowsError(try HTTPRequest.parse(Data("NONSENSE\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? HTTPRequest.ParseError, .malformed)
        }
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: -3\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? HTTPRequest.ParseError, .malformed)
        }
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? HTTPRequest.ParseError, .malformed)
        }
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 999999999999\r\n\r\n".utf8))) {
            XCTAssertEqual($0 as? HTTPRequest.ParseError, .tooLarge)
        }
        XCTAssertThrowsError(try HTTPRequest.parse(Data(repeating: UInt8(ascii: "a"), count: 70_000))) {
            XCTAssertEqual($0 as? HTTPRequest.ParseError, .tooLarge)
        }
    }

    func testSerializesResponsesWithContentLength() {
        let response = HTTPResponse.json(Data("{}".utf8))

        let text = String(decoding: response.serialized(closing: true), as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"), text)
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"), text)
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"), text)
        XCTAssertTrue(text.contains("Connection: close\r\n"), text)
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{}"), text)
    }

    func testUnauthorizedResponsesNameTheBearerScheme() {
        let text = String(decoding: HTTPResponse.unauthorized.serialized(closing: true), as: UTF8.self)

        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"), text)
        XCTAssertTrue(text.contains("WWW-Authenticate: Bearer\r\n"), text)
    }
}
