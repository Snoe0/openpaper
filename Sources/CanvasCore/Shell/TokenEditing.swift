import Foundation

/// Reading and editing tokens one mode at a time, as the sidebar's Tokens list does.
extension Tokens {
    public var sortedNames: [String] {
        tokens.keys.sorted()
    }

    /// The value the token compiles to in `mode`: a per-mode token without one uses the first mode's.
    public func value(of name: String, mode: String) -> String? {
        switch tokens[name] {
        case .single(let value): value
        case .perMode(let values): values[mode] ?? modes.first.flatMap { values[$0] }
        case nil: nil
        }
    }

    /// The token after setting its value in `mode` only. A new token gets one value for every
    /// mode; a single value is split per mode (keeping the others) when there are several modes.
    public func editedValue(of name: String, setting value: String, mode: String) -> TokenValue {
        switch tokens[name] {
        case nil:
            return .single(value)
        case .single where modes.count <= 1:
            return .single(value)
        case .single(let old):
            var values = Dictionary(uniqueKeysWithValues: modes.map { ($0, old) })
            values[mode] = value
            return .perMode(values)
        case .perMode(var values):
            values[mode] = value
            return .perMode(values)
        }
    }
}

extension Tokens {
    /// What an in-place edit saves: nothing when the text is what the field showed as editing began
    /// (so a change the agent made meanwhile survives), or when the token has since been deleted
    /// (so it isn't brought back); otherwise the token with `edited` in `mode`.
    public func committedValue(of name: String, edited: String, shownWhenEditingBegan shown: String, mode: String) -> TokenValue? {
        guard edited != shown, tokens[name] != nil else { return nil }
        return editedValue(of: name, setting: edited, mode: mode)
    }
}

public enum TokenName {
    /// The name without surrounding whitespace for a new token; empty names, and names in
    /// `existing`, are rejected.
    public static func validated(_ raw: String, existing: [String]) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DocumentError.invalidValue("a token needs a name") }
        guard !existing.contains(name) else { throw DocumentError.invalidValue("a token named \"\(name)\" already exists; edit its value in the list instead") }
        return name
    }
}
