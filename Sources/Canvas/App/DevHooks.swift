import AppKit
import CanvasCore

#if DEBUG
/// Keeps the Debug-only developer hooks working with tabs: the canvas `DevCanvas` builds from the
/// environment (`CANVAS_DOC`, `CANVAS_DEMO_BOARDS`, `CANVAS_ZOOM`) opens as a tab, and `DevRemote`
/// (`CANVAS_REMOTE`) follows the showing tab.
@MainActor
enum DevHooks {
    static func openFromEnvironment(in workspace: Workspace) {
        let canvas = DevCanvas.fromEnvironment()
        guard canvas.document != nil else { return }
        workspace.adopt(canvas)
    }

    /// DevRemote needs a canvas even on the Dashboard; this empty one stands in (it only holds it weakly).
    private static let noCanvas = CanvasViewController(document: nil)

    /// Points DevRemote at the showing canvas; reinstalling replaces its previous signal handler.
    static func pointRemote(at canvas: CanvasViewController?, in window: NSWindow) {
        DevRemote.install(for: window, canvas: canvas ?? noCanvas)
    }
}
#endif
