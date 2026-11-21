import Foundation

/// Checks, adds and repairs Claude Code's `canvas` entry. Checking only reads Claude Code's config
/// file; adding and repairing find `claude` through the user's interactive login shell (GUI apps don't
/// get the shell's PATH), falling back to where Claude Code usually installs it, then run
/// `claude mcp …` with that PATH. Every command has a deadline.
public struct AgentConnector: Sendable {
    public static let lookupTimeout: Duration = .seconds(20)
    public static let commandTimeout: Duration = .seconds(30)

    private let runner: any CommandRunning
    private let environment: [String: String]
    private let shell: URL
    private let home: String
    private let configURL: URL
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        runner: any CommandRunning = ProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shell: URL = ClaudeLookup.shell(forUserShell: ClaudeLookup.userShell),
        home: String = NSHomeDirectory(),
        configURL: URL? = nil,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.runner = runner
        self.environment = environment
        self.shell = shell
        self.home = home
        self.configURL = configURL ?? ClaudeConfig.defaultURL(home: home, environment: environment)
        self.isExecutable = isExecutable
    }

    /// Reads Claude Code's config; runs nothing.
    public func status(of registration: MCPRegistration) async throws -> ClaudeConfigSummary {
        try await readConfig(for: registration)
    }

    /// Runs `claude mcp add …`, then reports what the config now says. An entry that already exists
    /// isn't a failure: the config is read instead.
    public func connect(_ registration: MCPRegistration) async throws -> ClaudeConfigSummary {
        try refuseTranslocated(registration)
        let claude = try await findClaude()
        let result = try await claude.run(registration.addArguments, step: "claude mcp add", with: self)
        if !result.output.contains("already exists") { try Self.check(result) }
        return try await readConfig(for: registration)
    }

    /// Replaces the entry: `claude mcp remove --scope user canvas` when the user scope has one, then
    /// `claude mcp add …`, then reports what the config now says. An entry only in local scope is
    /// reported rather than guessed at.
    public func reconnect(_ registration: MCPRegistration) async throws -> ClaudeConfigSummary {
        try refuseTranslocated(registration)
        let config = try await readConfig(for: registration)
        if !config.hasUserEntry, !config.localScopeProjects.isEmpty {
            throw AgentConnectError.registeredInLocalScope(projects: config.localScopeProjects)
        }
        let claude = try await findClaude()
        if config.hasUserEntry { try Self.check(try await claude.run(registration.removeArguments, step: "claude mcp remove", with: self)) }
        try Self.check(try await claude.run(registration.addArguments, step: "claude mcp add", with: self))
        return try await readConfig(for: registration)
    }

    // MARK: - Steps

    /// Reads and parses the config once, on a background thread.
    private func readConfig(for registration: MCPRegistration) async throws -> ClaudeConfigSummary {
        let (url, helper) = (configURL, registration.helper)
        return try await Task.detached(priority: .userInitiated) { try ClaudeConfig.read(at: url, helper: helper) }.value
    }

    private func refuseTranslocated(_ registration: MCPRegistration) throws {
        if registration.isTranslocated { throw AgentConnectError.appTranslocated }
    }

    /// The login shell's answer, else the first known install location.
    private func findClaude() async throws -> Claude {
        var lookupTimedOut = false
        do {
            let found = ClaudeLookup.parse(try await runner.run(shell, ClaudeLookup.arguments, environment: nil, timeout: Self.lookupTimeout).stdout)
            if let claude = found.claude { return Claude(executable: claude, environment: environment(searchPath: found.searchPath)) }
        } catch is CommandTimedOut {
            lookupTimedOut = true
        }
        guard let path = ClaudeLookup.fallbackPaths(home: home).first(where: isExecutable) else {
            throw lookupTimedOut ? AgentConnectError.timedOut(step: "finding claude") : AgentConnectError.claudeNotFound
        }
        let folder = (path as NSString).deletingLastPathComponent
        return Claude(executable: URL(fileURLWithPath: path), environment: environment(searchPath: ([folder] + [environment["PATH"]].compactMap { $0 }).joined(separator: ":")))
    }

    /// The app's environment with `searchPath` as PATH, so `claude` finds what it needs (e.g. node).
    private func environment(searchPath: String?) -> [String: String] {
        var environment = environment
        if let searchPath { environment["PATH"] = searchPath }
        return environment
    }

    fileprivate func run(_ executable: URL, _ arguments: [String], environment: [String: String], step: String) async throws -> CommandResult {
        do {
            return try await runner.run(executable, arguments, environment: environment, timeout: Self.commandTimeout)
        } catch is CommandTimedOut {
            throw AgentConnectError.timedOut(step: step)
        }
    }

    private static func check(_ result: CommandResult) throws {
        guard result.status == 0 else { throw failure(result) }
    }

    private static func failure(_ result: CommandResult) -> AgentConnectError {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(status: result.status, output: stderr.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : stderr)
    }
}

/// `claude` as found, with the environment to run it in.
private struct Claude {
    let executable: URL
    let environment: [String: String]

    func run(_ arguments: [String], step: String, with connector: AgentConnector) async throws -> CommandResult {
        try await connector.run(executable, arguments, environment: environment, step: step)
    }
}

/// Asks the user's shell where `claude` is and what its PATH is.
public enum ClaudeLookup {
    /// An interactive login shell, so both the login files and `.zshrc` / `.bashrc` set PATH. A fixed
    /// script: nothing is interpolated into it. Markers pick the answer out of whatever the shell prints.
    /// An interactive shell may take over the terminal's foreground process group; if a dev run started
    /// from a terminal has to SIGKILL it at the deadline, that terminal can be left without its foreground.
    public static let arguments = ["-ilc", #"printf '\nCANVAS_CLAUDE=%s\nCANVAS_PATH=%s\n' "$(command -v claude)" "$PATH""#]

    /// Shells that understand `-ilc` and `command -v`.
    private static let posixShells: Set<String> = ["sh", "bash", "zsh", "ksh", "dash"]

    /// The user's login shell, from the user database.
    public static var userShell: String? {
        getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) }
    }

    /// The user's shell when it is POSIX-like, else zsh (e.g. for fish).
    public static func shell(forUserShell path: String?) -> URL {
        guard let path, posixShells.contains((path as NSString).lastPathComponent) else { return URL(fileURLWithPath: "/bin/zsh") }
        return URL(fileURLWithPath: path)
    }

    /// Where Claude Code installs `claude`, in the order they are tried when the shell can't say.
    public static func fallbackPaths(home: String) -> [String] {
        ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    /// `claude` is only found as an absolute path (not as an alias or function).
    public static func parse(_ output: String) -> (claude: URL?, searchPath: String?) {
        let lines = output.split(separator: "\n").map(String.init)
        let value = { (marker: String) in lines.last { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) } }
        let claude = value("CANVAS_CLAUDE=").flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        let searchPath = value("CANVAS_PATH=").flatMap { $0.isEmpty ? nil : $0 }
        return (claude, searchPath)
    }
}

public enum AgentConnectError: Error, Equatable {
    case claudeNotFound
    case commandFailed(status: Int32, output: String)
    case timedOut(step: String)
    case unreadableConfig
    case appTranslocated
    case registeredInLocalScope(projects: [String])
}

extension AgentConnectError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            "Couldn't find the claude command in your shell or the usual install locations. Install Claude Code, or run the command yourself in Terminal."
        case .commandFailed(let status, let output):
            "claude failed (exit \(status))" + (output.isEmpty ? "." : ":\n\(output)")
        case .timedOut(let step):
            "Stopped \(step) because it took too long."
        case .unreadableConfig:
            "Couldn't read Claude Code's settings (~/.claude.json), so Canvas can't tell whether it's connected."
        case .appTranslocated:
            "macOS is running Canvas from a temporary location. Move Canvas to your Applications folder, open it from there, then connect again."
        case .registeredInLocalScope(let projects):
            "Claude Code has a \"canvas\" entry only in local scope, for \(projects.joined(separator: ", ")). Run `claude mcp remove --scope local canvas` in that project, then connect again."
        }
    }
}
