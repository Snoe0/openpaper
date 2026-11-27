import Foundation

extension BridgeTools {
    static let documentTools: [BridgeTool] = [
        BridgeTool(
            name: "get_document",
            description: "Overview of the open document: its folder path, mode, pages with their artboards, and components.",
            inputSchema: Schema.object(),
            run: { call in try .json(DocumentOverview(call.document())) }
        ),
        BridgeTool(
            name: "open_document",
            description: "Open an existing .canvas document folder in Canvas and make it the active document.",
            inputSchema: Schema.object(["path": Schema.string("Absolute path of the .canvas folder.")], required: ["path"]),
            run: { call in try .json(DocumentOverview(call.controller.openDocument(at: call.absolutePath()))) }
        ),
        BridgeTool(
            name: "create_document",
            description: "Create a new, empty .canvas document folder and make it the active document.",
            inputSchema: Schema.object(
                ["path": Schema.string("Absolute path of the new folder; \".canvas\" is appended if missing.")],
                required: ["path"]
            ),
            run: { call in try .json(DocumentOverview(call.controller.createDocument(at: canvasFolder(call.absolutePath())))) }
        ),
    ]

    static let pageTools: [BridgeTool] = [
        BridgeTool(
            name: "list_pages",
            description: "List the document's pages with their artboard counts, marking the current page.",
            inputSchema: Schema.object(),
            run: { call in try .json(pageSummaries(of: call.document())) }
        ),
        BridgeTool(
            name: "create_page",
            description: "Add a page to the document (without switching to it).",
            inputSchema: Schema.object(["name": Schema.string("Page name.")], required: ["name"]),
            run: { call in try .json(call.document().addPage(name: call.string("name"))) }
        ),
        BridgeTool(
            name: "switch_page",
            description: "Show another page in Canvas; it becomes the default page for other tools.",
            inputSchema: Schema.object(["page": Schema.string("Page id or name.")], required: ["page"]),
            run: { call in
                let document = try call.document()
                let page = try call.requiredPage(in: document)
                try document.switchPage(id: page.id)
                return .text("Switched to page \"\(page.name)\" (\(page.id)).")
            }
        ),
    ]

    /// `path`, with the `.canvas` extension added when it's missing.
    private static func canvasFolder(_ url: URL) -> URL {
        url.pathExtension == "canvas" ? url : url.appendingPathExtension("canvas")
    }

    private static func pageSummaries(of document: CanvasDocument) -> [PageSummary] {
        document.manifest.pages.map { page in
            PageSummary(
                id: page.id, name: page.name,
                current: page.id == document.currentPage.id,
                artboards: document.artboards(onPage: page.id).count
            )
        }
    }
}

/// What `get_document` (and opening or creating one) returns.
struct DocumentOverview: Encodable {
    struct PageArtboards: Encodable {
        let id: String
        let name: String
        let artboards: [Artboard]
    }

    let name: String
    let path: String
    let mode: String
    let modes: [String]
    let currentPage: String
    let pages: [PageArtboards]
    let components: [String]

    @MainActor
    init(_ document: CanvasDocument) {
        name = document.name
        path = document.url.path
        mode = document.manifest.mode
        modes = document.tokens.modes
        currentPage = document.currentPage.id
        pages = document.manifest.pages.map { page in
            PageArtboards(id: page.id, name: page.name, artboards: document.artboards(onPage: page.id))
        }
        components = document.componentNames
    }
}

private struct PageSummary: Encodable {
    let id: String
    let name: String
    let current: Bool
    let artboards: Int
}
