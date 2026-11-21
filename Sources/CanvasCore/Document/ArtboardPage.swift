import Foundation

/// The full HTML document a WKWebView loads for one artboard: reset, tokens, runtime, components, then the body.
/// There is no `<base>`: the page is served at the document root (`canvas://doc/__artboard__<id>.html`),
/// so `assets/x.png` resolves to the document's assets and `#fragment` links stay on the page.
public enum ArtboardPage {
    @MainActor
    public static func html(for artboard: Artboard, in document: CanvasDocument) throws -> String {
        let body = try document.html(ofArtboard: artboard.id)
        let mode = artboard.effectiveMode(in: document.manifest)
        return """
        <!doctype html><html data-mode="\(attributeEscaped(mode))"><head><meta charset="utf-8">
        <style id="canvas-reset">html,body{margin:0;padding:0}html{width:\(cssNumber(artboard.width))px;height:\(cssNumber(artboard.height))px;overflow:hidden}</style>
        <style id="canvas-tokens">\(closingTagsEscaped(TokenCompiler.css(for: document.tokens)))</style>
        <script id="canvas-runtime">\(RuntimeScript.source)</script>
        <script id="canvas-components">window.Canvas&&Canvas.defineComponents(\(scriptSafeJSON(document.allComponents())))</script>
        </head><body>\(body)</body></html>
        """
    }

    /// JSON that can sit inside a `<script>` element without ending it or tripping the HTML parser.
    static func scriptSafeJSON(_ value: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return closingTagsEscaped(json)
            .replacingOccurrences(of: "<!--", with: "\\u003c!--")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func closingTagsEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "</", with: #"<\/"#)
    }

    private static func attributeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    /// 1440 → "1440", 900.5 → "900.5"; never traps, however big the value.
    static func cssNumber(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

/// The page-side runtime (`runtime.js` in the CanvasCore bundle); empty if it isn't bundled.
public enum RuntimeScript {
    public static var source: String { bundled }

    private static let bundled: String = {
        guard let url = CanvasCore.bundle.url(forResource: "runtime", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()
}
