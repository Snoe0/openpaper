import Foundation

/// Compiles tokens to CSS custom properties: `:root` holds every token in the first mode,
/// then one `[data-mode="…"]` block per mode holds the per-mode tokens.
public enum TokenCompiler {
    public static func css(for tokens: Tokens) -> String {
        let names = tokens.tokens.keys.sorted()
        let fallbackMode = tokens.modes.first
        let root = block(":root", names: names, in: tokens, mode: fallbackMode)
        let perModeNames = names.filter { if case .perMode = tokens.tokens[$0] { true } else { false } }
        let modeBlocks = tokens.modes.map { mode in
            block("[data-mode=\"\(mode.replacingOccurrences(of: "\"", with: "\\\""))\"]", names: perModeNames, in: tokens, mode: mode)
        }
        return ([root] + modeBlocks).joined(separator: "\n")
    }

    /// `color.bg` → `--color-bg`: anything outside `[a-zA-Z0-9-_]` becomes `-`.
    static func variableName(_ token: String) -> String {
        "--" + String(token.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" })
    }

    private static func block(_ selector: String, names: [String], in tokens: Tokens, mode: String?) -> String {
        let declarations = names.compactMap { name -> String? in
            guard let token = tokens.tokens[name],
                  let value = value(of: token, mode: mode, fallbackMode: tokens.modes.first) else { return nil }
            return "\(variableName(name)):\(value);"
        }
        return "\(selector){\(declarations.joined())}"
    }

    /// A per-mode token without a value for `mode` uses the first mode's value.
    private static func value(of token: TokenValue, mode: String?, fallbackMode: String?) -> String? {
        switch token {
        case .single(let value):
            return value
        case .perMode(let values):
            return mode.flatMap { values[$0] } ?? fallbackMode.flatMap { values[$0] }
        }
    }
}
