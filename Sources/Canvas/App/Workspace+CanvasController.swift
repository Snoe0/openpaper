import AppKit
import CanvasCore

/// The bridge works on whichever document tab is showing.
extension Workspace: CanvasController {
    var activeDocument: CanvasDocument? {
        activeTab?.document
    }

    var selection: CanvasSelection {
        activeCanvas?.selection ?? CanvasSelection()
    }

    /// Holds on to the canvas it started with, so switching or closing tabs mid-snapshot can't pull
    /// it away; a board deleted meanwhile throws.
    func screenshot(artboardID: String) async throws -> Data {
        guard let canvas = activeCanvas else { throw WorkspaceError.noDocument }
        return try await canvas.snapshotPNG(artboardID: artboardID)
    }

    func consoleLogs(artboardID: String?) -> [ConsoleEntry] {
        activeCanvas?.consoleLogs(artboardID: artboardID) ?? []
    }

    func focus(artboardID: String) {
        activeCanvas?.focus(artboardID: artboardID)
    }
}
