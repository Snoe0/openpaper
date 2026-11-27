import Foundation

extension CanvasDocument {
    /// Adds or replaces the given tokens, keeping the rest.
    /// Values can't contain `{`, `}`, `;` or `<`, which could break out of the compiled CSS.
    public func setTokens(_ values: [String: TokenValue]) throws {
        try validateTokenValues(values)
        try updateTokens { $0.tokens.merge(values) { _, new in new } }
    }

    public func removeToken(_ name: String) throws {
        guard tokens.tokens[name] != nil else { throw DocumentError.notFound(name) }
        try updateTokens { $0.tokens[name] = nil }
    }

    /// Replaces the mode list in one change: a document mode that is no longer listed falls back to
    /// the first mode, and artboard overrides naming a removed mode are cleared.
    public func setModes(_ modes: [String]) throws {
        if let problem = Tokens.modesProblem(modes) { throw DocumentError.invalidValue(problem) }
        try update { manifest, tokens in
            tokens.modes = modes
            if !modes.contains(manifest.mode) { manifest.mode = modes[0] }
            for index in manifest.artboards.indices where manifest.artboards[index].mode.map({ !modes.contains($0) }) == true {
                manifest.artboards[index].mode = nil
            }
        }
    }

    /// Sets the document-wide token mode, which must be one of the token modes.
    public func setMode(_ mode: String) throws {
        guard tokens.modes.contains(mode) else { throw DocumentError.notFound(mode) }
        try updateManifest { $0.mode = mode }
    }

    private func validateTokenValues(_ values: [String: TokenValue]) throws {
        for (name, value) in values.sorted(by: { $0.key < $1.key }) where value.strings.contains(where: Self.breaksCSS) {
            throw DocumentError.invalidValue("token \"\(name)\": values can't contain {, }, ; or <")
        }
    }

    private static func breaksCSS(_ value: String) -> Bool {
        value.contains { "{};<".contains($0) }
    }
}

extension Tokens {
    /// Rejects a `tokens.json` whose mode list `modesProblem` finds fault with.
    func validate() throws {
        if let problem = Self.modesProblem(modes) { throw DocumentError.malformed("\(DocumentPath.tokens): \(problem)") }
    }

    /// Why a mode list is unusable; nil when it's fine. There must be at least one mode, and names are
    /// unique and use only the characters token names keep in CSS (letters, digits, `_`, `-`), so a
    /// mode can go into a `[data-mode="…"]` selector as is.
    static func modesProblem(_ modes: [String]) -> String? {
        if modes.isEmpty { return "modes must not be empty" }
        if let bad = modes.first(where: { $0.wholeMatch(of: /[A-Za-z0-9_-]+/) == nil }) {
            return "mode \"\(bad)\" must be made of letters, digits, _ and - only"
        }
        if Set(modes).count != modes.count { return "mode names must be unique" }
        return nil
    }
}

extension TokenValue {
    /// Every value, whatever the mode.
    var strings: [String] {
        switch self {
        case .single(let value): [value]
        case .perMode(let values): Array(values.values)
        }
    }
}
