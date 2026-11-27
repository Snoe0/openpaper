import Foundation

extension BridgeTools {
    static let artboardTools: [BridgeTool] = [
        BridgeTool(
            name: "create_artboard",
            description: "Add an artboard with its HTML. Without x/y it goes right of the right-most artboard on the page.",
            inputSchema: Schema.object([
                "name": Schema.string("Artboard name, e.g. \"Pricing\"; its id is derived from it."),
                "width": Schema.width,
                "height": Schema.height,
                "html": Schema.html,
                "x": Schema.coordinate("x", "; omit to place automatically"),
                "y": Schema.coordinate("y", "; omit to place automatically"),
                "page": Schema.page,
            ], required: ["name", "width", "height"]),
            run: { call in
                let document = try call.document()
                let board = try document.addArtboard(
                    name: call.string("name"), width: call.number("width"), height: call.number("height"),
                    html: call.optionalString("html") ?? "", page: call.page(in: document).id,
                    x: call.optionalNumber("x"), y: call.optionalNumber("y")
                )
                return try .json(board)
            }
        ),
        BridgeTool(
            name: "read_artboard",
            description: "Read an artboard's HTML.",
            inputSchema: Schema.object(["id": Schema.artboardID], required: ["id"]),
            run: { call in try .text(call.document().html(ofArtboard: call.string("id"))) }
        ),
        BridgeTool(
            name: "write_artboard",
            description: "Replace an artboard's whole HTML.",
            inputSchema: Schema.object(["id": Schema.artboardID, "html": Schema.html], required: ["id", "html"]),
            run: { call in
                let id = try call.string("id")
                try call.document().writeHTML(call.string("html"), toArtboard: id)
                return .text("Wrote artboard \(id).")
            }
        ),
        BridgeTool(
            name: "edit_artboard",
            description: "Replace one exact snippet of an artboard's HTML; old_string must occur exactly once.",
            inputSchema: Schema.object([
                "id": Schema.artboardID,
                "old_string": Schema.string("Exact text to replace, unique in the artboard."),
                "new_string": Schema.string("Replacement text."),
            ], required: ["id", "old_string", "new_string"]),
            run: { call in
                let id = try call.string("id")
                try call.document().editHTML(ofArtboard: id, replacing: call.string("old_string"), with: call.string("new_string"))
                return .text("Edited artboard \(id).")
            }
        ),
        BridgeTool(
            name: "update_artboard",
            description: "Change an artboard's name, position, size or token mode; omitted fields stay as they are.",
            inputSchema: Schema.object([
                "id": Schema.artboardID,
                "name": Schema.string("New name (the id stays the same)."),
                "x": Schema.coordinate("x"),
                "y": Schema.coordinate("y"),
                "width": Schema.width,
                "height": Schema.height,
                "mode": ["type": ["string", "null"], "description": "Token mode for this artboard, or null to follow the document mode."],
            ], required: ["id"]),
            run: { call in
                let document = try call.document()
                let id = try call.string("id")
                try document.updateArtboard(
                    id: id, name: call.optionalString("name"), x: call.optionalNumber("x"), y: call.optionalNumber("y"),
                    width: call.optionalNumber("width"), height: call.optionalNumber("height"), mode: call.nullableString("mode")
                )
                return try .json(document.artboard(id: id))
            }
        ),
        BridgeTool(
            name: "delete_artboard",
            description: "Delete an artboard and its HTML file.",
            inputSchema: Schema.object(["id": Schema.artboardID], required: ["id"]),
            run: { call in
                let id = try call.string("id")
                try call.document().deleteArtboard(id: id)
                return .text("Deleted artboard \(id).")
            }
        ),
        BridgeTool(
            name: "duplicate_artboard",
            description: "Copy an artboard (HTML, size and mode) as \"<name> copy\" next to the others on its page.",
            inputSchema: Schema.object(["id": Schema.artboardID], required: ["id"]),
            run: { call in try .json(call.document().duplicateArtboard(id: call.string("id"))) }
        ),
    ]
}
