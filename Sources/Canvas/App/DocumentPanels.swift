import AppKit
import CanvasCore

/// The save and open panels for `.canvas` document folders, shown as sheets.
@MainActor
enum DocumentPanels {
    /// Asks where to create a new document; the answer always ends in `.canvas`.
    static func chooseNewDocumentLocation(in window: NSWindow, then create: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.title = "New Document"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Name:"
        panel.nameFieldStringValue = "Untitled"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            create(DocumentLocation.canvasFolder(url))
        }
    }

    /// Asks for an existing `.canvas` folder.
    static func chooseDocumentToOpen(in window: NSWindow, then open: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Open Document"
        panel.message = "Choose a .canvas document folder."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        let validator = CanvasFolderValidator()
        panel.delegate = validator
        panel.beginSheetModal(for: window) { response in
            withExtendedLifetime(validator) {
                guard response == .OK, let url = panel.url else { return }
                open(url)
            }
        }
    }
}

/// Lets the open panel browse any folder but only open `.canvas` ones.
private final class CanvasFolderValidator: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        guard DocumentLocation.isCanvasFolder(url) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” isn't a Canvas document. Choose a folder ending in .canvas."])
        }
    }
}
