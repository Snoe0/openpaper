import Foundation

/// Reads newline-delimited JSON-RPC from stdin, forwards each message to Canvas in order, and writes
/// each response to stdout as one line. Returns at end of input.
@MainActor
final class StdioProxy {
    /// JSON-RPC "server error" code for when Canvas can't be reached.
    static let unreachableErrorCode = -32000

    private let app: AppConnection

    init(app: AppConnection) {
        self.app = app
    }

    func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.allSatisfy(\.isWhitespace) else { continue }
            if let response = await forward(Data(line.utf8)) { writeLine(response) }
        }
    }

    /// Canvas's response, or a JSON-RPC error when Canvas can't be reached (nil for notifications).
    private func forward(_ message: Data) async -> Data? {
        do {
            return try await app.send(message)
        } catch {
            logLine(error.localizedDescription)
            return Self.errorResponse(to: message, saying: error.localizedDescription)
        }
    }

    private func writeLine(_ data: Data) {
        try? FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
    }

    /// An error response with the request's id; nil for notifications, which get no response.
    static func errorResponse(to message: Data, saying text: String) -> Data? {
        guard let request = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              request["method"] != nil, let id = request["id"], !(id is NSNull) else { return nil }
        let response: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": unreachableErrorCode, "message": text],
        ]
        return try? JSONSerialization.data(withJSONObject: response)
    }
}

/// Logs go to stderr; stdout carries only MCP messages.
func logLine(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("canvas-mcp: \(message)\n".utf8))
}
