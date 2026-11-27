import Foundation
import Observation

/// What the bridge is doing, for the app's MCP panel.
@MainActor @Observable
public final class BridgeStatus {
    /// The localhost port the server listens on, or nil while stopped.
    public internal(set) var port: UInt16?
    /// The MCP client that last initialized a session, or nil if none has yet.
    public internal(set) var client: BridgeClientInfo?
    public internal(set) var lastCall: ToolCallRecord?

    public var isListening: Bool { port != nil }

    public init() {}
}

public struct BridgeClientInfo: Equatable, Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct ToolCallRecord: Equatable, Sendable {
    public var name: String
    public var date: Date
    public var succeeded: Bool
    /// What the agent was told when the call failed.
    public var errorMessage: String?

    public init(name: String, date: Date, succeeded: Bool, errorMessage: String? = nil) {
        self.name = name
        self.date = date
        self.succeeded = succeeded
        self.errorMessage = errorMessage
    }
}
