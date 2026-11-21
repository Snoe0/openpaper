import Foundation

/// A JSON-RPC 2.0 error, sent back instead of a result.
struct JSONRPCError: Error, Equatable {
    let code: Int
    let message: String

    static let parseError = JSONRPCError(code: -32700, message: "Parse error: the message isn't valid JSON.")
    static let invalidRequest = JSONRPCError(
        code: -32600, message: "Invalid request: expected a JSON-RPC 2.0 object with \"jsonrpc\": \"2.0\" and a string or integer id."
    )

    static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "Method not found: \(method)")
    }

    static func invalidParams(_ detail: String) -> JSONRPCError {
        JSONRPCError(code: -32602, message: "Invalid params: \(detail)")
    }
}

/// A message that can't be handled: the error, and the id to report it under (null when there's no usable id).
struct JSONRPCRejection: Error {
    let error: JSONRPCError
    let id: JSONValue

    init(_ error: JSONRPCError, id: JSONValue = .null) {
        self.error = error
        self.id = id
    }
}

/// An incoming JSON-RPC message.
enum JSONRPCMessage {
    /// Expects a response.
    case request(id: JSONValue, method: String, params: JSONValue)
    /// Expects nothing back.
    case notification(method: String)
    /// A client's answer to a server request; Canvas never sends any, so it's ignored.
    case response

    init(decoding data: Data) throws(JSONRPCRejection) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw JSONRPCRejection(.parseError) }
        guard let message = value.object else { throw JSONRPCRejection(.invalidRequest) }
        let id = message["id"] ?? .null
        guard Self.isValidID(id) else { throw JSONRPCRejection(.invalidRequest) }
        guard message["jsonrpc"] == "2.0" else { throw JSONRPCRejection(.invalidRequest, id: id) }
        guard let method = message["method"]?.string else {
            guard message["result"] != nil || message["error"] != nil else { throw JSONRPCRejection(.invalidRequest, id: id) }
            self = .response
            return
        }
        guard id != .null else {
            self = .notification(method: method)
            return
        }
        self = .request(id: id, method: method, params: message["params"] ?? [:])
    }

    /// MCP ids are strings or integers; a missing or null id marks a notification.
    private static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .int, .null: true
        default: false
        }
    }

    static func result(_ result: JSONValue, id: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(_ error: JSONRPCError, id: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(error.code), "message": .string(error.message)]]
    }
}
