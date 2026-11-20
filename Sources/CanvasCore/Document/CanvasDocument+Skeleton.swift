import Foundation

extension CanvasDocument {
    /// Writes an empty document: one page, starter tokens, empty folders and the CLAUDE.md guide.
    static func writeSkeleton(at url: URL) throws {
        let files = DocumentFiles(root: url)
        for folder in [DocumentPath.artboards, DocumentPath.components, DocumentPath.assets] {
            try files.createFolder(folder)
        }
        try files.write(encodeJSON(Manifest.starter), to: DocumentPath.manifest)
        try files.write(encodeJSON(Tokens.starter), to: DocumentPath.tokens)
        try files.write(DocumentGuide.markdown, to: DocumentPath.guide)
    }
}

extension Manifest {
    static let starter = Manifest(currentPage: "p1", mode: "light", pages: [Page(id: "p1", name: "Page 1")], artboards: [])
}

extension Tokens {
    static let starter = Tokens(modes: ["light", "dark"], tokens: [
        "color.bg": .perMode(["light": "#ffffff", "dark": "#0b0b0c"]),
        "color.fg": .perMode(["light": "#0b0b0c", "dark": "#f5f5f7"]),
        "color.accent": .perMode(["light": "#2563eb", "dark": "#60a5fa"]),
        "color.muted": .perMode(["light": "#6b7280", "dark": "#9ca3af"]),
        "font.sans": .single("-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", system-ui, sans-serif"),
        "radius.md": .single("8px"),
        "space.4": .single("16px"),
    ])
}
