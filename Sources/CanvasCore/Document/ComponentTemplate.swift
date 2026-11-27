import Foundation

/// A component template: HTML with optional `<style>`, `{{prop}}` / `{{prop|default}}` placeholders and `<slot>`s.
public enum ComponentTemplate {
    /// Props in order of first appearance; a repeated prop keeps its first default.
    public static func props(in html: String) -> [ComponentProp] {
        let placeholder = /\{\{\s*([A-Za-z_][A-Za-z0-9_-]*)\s*(?:\|([^}]*))?\}\}/
        var seen = Set<String>()
        return html.matches(of: placeholder).compactMap { match in
            let name = String(match.output.1)
            guard seen.insert(name).inserted else { return nil }
            let defaultValue = match.output.2.map { $0.trimmingCharacters(in: .whitespaces) }
            return ComponentProp(name: name, defaultValue: defaultValue)
        }
    }

    /// Component names become `x-<name>` tags, so they must be lowercase, start with a letter, and use only `a-z0-9-`.
    static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z][a-z0-9-]*/) != nil
    }

    /// "button.html" → "button"; nil for anything that isn't a valid component file.
    static func name(ofFile fileName: String) -> String? {
        guard fileName.hasSuffix(".html") else { return nil }
        let name = String(fileName.dropLast(".html".count))
        return isValidName(name) ? name : nil
    }
}
