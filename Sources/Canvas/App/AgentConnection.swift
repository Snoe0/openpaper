import CanvasCore
import Foundation
import Observation

/// The app's link to Claude Code: runs the MCP bridge (the MCP panels offer a manual restart), and
/// checks, adds or repairs the `canvas` MCP entry that points Claude Code at the bundled `canvas-mcp`.
/// Observable for the MCP panels.
@MainActor @Observable
final class AgentConnection {
    /// The bridge's live status; nil until the bridge exists.
    var status: BridgeStatus? { bridge?.status }
    /// Why the bridge couldn't start, if it couldn't.
    private(set) var startupError: String?
    private(set) var isStarting = false
    /// Claude Code's user-scope `canvas` entry as last read from its config; nil until known, or
    /// when the config couldn't be read.
    private(set) var registration: RegistrationStatus?
    /// Projects whose local-scope `canvas` entry overrides the user entry there.
    private(set) var localScopeProjects: [String] = []
    /// Why the entry couldn't be read or changed (unreadable config, claude not installed, …).
    private(set) var registrationProblem: String?
    /// True while the config is read or `claude` is changing the entry.
    private(set) var isRegistering = false

    let entry = MCPRegistration(helper: MCPRegistration.helperURL(inApp: Bundle.main.bundleURL))
    private var bridge: BridgeServer?
    @ObservationIgnored private let connector = AgentConnector()

    /// Creates the bridge for `controller` and starts it; a failure shows in the MCP panel.
    func startBridge(for controller: any CanvasController) async {
        bridge = BridgeServer(controller: controller, bridgeFileURL: Self.bridgeFileURL)
        await start()
    }

    /// `CANVAS_BRIDGE_FILE` moves `bridge.json` (the end-to-end test uses a temp file); canvas-mcp reads the same variable.
    /// Empty counts as unset.
    private static var bridgeFileURL: URL {
        ProcessInfo.processInfo.environment["CANVAS_BRIDGE_FILE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? BridgeServer.defaultBridgeFileURL
    }

    func restartBridge() async {
        bridge?.stop()
        await start()
        await checkRegistration()
    }

    func stopBridge() {
        bridge?.stop()
    }

    /// Reads how Claude Code's `canvas` entry looks from its config file (runs nothing). Called at
    /// launch, after a bridge restart and whenever the app becomes active; skipped mid-change.
    func checkRegistration() async {
        guard !isRegistering else { return }
        try? await register { [connector, entry] in try await connector.status(of: entry) }
    }

    /// Runs `claude mcp add …`, then reads the config to confirm; an entry that already exists is read instead of failing.
    func connectAgent() async throws {
        try await register { [connector, entry] in try await connector.connect(entry) }
    }

    /// Runs `claude mcp remove …` then `claude mcp add …`, replacing an outdated or broken entry, then reads the config to confirm.
    func reconnectAgent() async throws {
        try await register { [connector, entry] in try await connector.reconnect(entry) }
    }

    private func register(_ change: @Sendable () async throws -> ClaudeConfigSummary) async throws {
        isRegistering = true
        defer { isRegistering = false }
        do {
            let summary = try await change()
            registration = summary.userEntry
            localScopeProjects = summary.localScopeProjects
            registrationProblem = nil
        } catch {
            registrationProblem = error.localizedDescription
            throw error
        }
    }

    private func start() async {
        guard let bridge else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            try await bridge.start()
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }
}
