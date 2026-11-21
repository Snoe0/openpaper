import Foundation

/// What Claude Code's config says about Canvas: the user-scope `canvas` entry, and the projects that
/// have a local-scope one (which overrides the user entry inside those projects).
public struct ClaudeConfigSummary: Equatable, Sendable {
    public var userEntry: RegistrationStatus
    public var localScopeProjects: [String]

    public init(userEntry: RegistrationStatus, localScopeProjects: [String]) {
        self.userEntry = userEntry
        self.localScopeProjects = localScopeProjects
    }

    public var hasUserEntry: Bool {
        userEntry != .notRegistered
    }

    static let empty = ClaudeConfigSummary(userEntry: .notRegistered, localScopeProjects: [])
}

/// Reads Claude Code's own config (`.claude.json`) to see how the `canvas` MCP entry looks,
/// without running `claude`: `claude mcp get` health-checks the entry, which starts `canvas-mcp`.
/// Read-only. User-scope entries live in the top-level `mcpServers`; local-scope ones under
/// `projects.<path>.mcpServers`.
public enum ClaudeConfig {
    /// Bigger files count as unreadable rather than being loaded.
    public static let maxBytes = 64 << 20

    /// `$CLAUDE_CONFIG_DIR/.claude.json` when that is set, else `~/.claude.json`.
    public static func defaultURL(home: String, environment: [String: String]) -> URL {
        let folder = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home
        return URL(fileURLWithPath: folder).appendingPathComponent(".claude.json")
    }

    /// Reads and parses the file once. No file means nothing is registered; any other problem
    /// (unreadable, too big, not understood) throws `unreadableConfig`, never a guessed state.
    public static func read(at url: URL, helper: URL, maxBytes: Int = maxBytes) throws -> ClaudeConfigSummary {
        let data: Data
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= maxBytes else { throw AgentConnectError.unreadableConfig }
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .empty
        } catch {
            throw AgentConnectError.unreadableConfig
        }
        guard let summary = summary(of: data, helper: helper) else { throw AgentConnectError.unreadableConfig }
        return summary
    }

    /// Nil when the config can't be understood.
    public static func summary(of data: Data, helper: URL) -> ClaudeConfigSummary? {
        guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userEntry = userEntry(in: config, helper: helper) else { return nil }
        return ClaudeConfigSummary(userEntry: userEntry, localScopeProjects: localScopeProjects(in: config))
    }

    private static func userEntry(in config: [String: Any], helper: URL) -> RegistrationStatus? {
        guard let servers = config["mcpServers"] else { return .notRegistered }
        guard let servers = servers as? [String: Any] else { return nil }
        guard let entry = servers[MCPRegistration.serverName] else { return .notRegistered }
        guard let entry = entry as? [String: Any] else { return nil }
        guard let command = entry["command"] as? String, !command.isEmpty else {
            return .needsReconnect(reason: "Its entry doesn't run a local command.")
        }
        return samePath(command, helper.path) ? .connected : .needsReconnect(reason: "It points at \(command).")
    }

    private static func localScopeProjects(in config: [String: Any]) -> [String] {
        guard let projects = config["projects"] as? [String: Any] else { return [] }
        return projects.compactMap { path, project in
            let servers = (project as? [String: Any])?["mcpServers"] as? [String: Any]
            return servers?[MCPRegistration.serverName] == nil ? nil : path
        }.sorted()
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        let canonical = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path }
        return canonical(lhs) == canonical(rhs)
    }
}
