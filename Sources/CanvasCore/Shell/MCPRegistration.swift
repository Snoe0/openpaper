import Foundation

/// The `claude mcp …` commands that add and remove the `canvas` entry pointing Claude Code at the
/// app's `canvas-mcp` helper.
public struct MCPRegistration: Sendable {
    public static let serverName = "canvas"

    public let helper: URL

    public init(helper: URL) {
        self.helper = helper
    }

    /// `canvas-mcp` as embedded in the app bundle.
    public static func helperURL(inApp bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Helpers/canvas-mcp")
    }

    /// macOS runs a quarantined app from a random read-only path until it's moved; registering that
    /// path would break as soon as the app is moved or relaunched.
    public var isTranslocated: Bool {
        helper.path.contains("/AppTranslocation/")
    }

    // Arguments to `claude`, one argv entry each.
    public var addArguments: [String] { ["mcp", "add", "--scope", "user", Self.serverName, "--", helper.path] }
    public var removeArguments: [String] { ["mcp", "remove", "--scope", "user", Self.serverName] }

    // The commands as you'd type them in a terminal, for the confirm dialogs.
    public var addCommand: String { Self.display(addArguments) }
    public var removeCommand: String { Self.display(removeArguments) }

    private static func display(_ arguments: [String]) -> String {
        (["claude"] + arguments).map(ShellQuote.quote).joined(separator: " ")
    }
}

/// What Claude Code's `canvas` entry looks like.
public enum RegistrationStatus: Equatable, Sendable {
    case notRegistered
    /// It runs this app's helper.
    case connected
    /// It runs another helper, or no local command; `reason` says which.
    case needsReconnect(reason: String)
}

extension CommandResult {
    /// Both streams, for matching messages that may come on either.
    var output: String { stdout + "\n" + stderr }
}

enum ShellQuote {
    /// Leaves plain words alone and single-quotes anything else.
    static func quote(_ word: String) -> String {
        guard word.isEmpty || word.contains(where: { !isPlain($0) }) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func isPlain(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || "-_./=:@%+".contains(character))
    }
}
