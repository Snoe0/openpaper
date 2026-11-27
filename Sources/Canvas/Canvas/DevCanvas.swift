#if DEBUG
import AppKit
import CanvasCore

/// Debug-only dev hook: builds a canvas from environment variables, opened as a tab by `DevHooks`.
/// `CANVAS_DOC=/path/X.canvas` opens a document, `CANVAS_DEMO_BOARDS=<n>` makes a temporary one with
/// n animated boards, and `CANVAS_ZOOM=<scale>` sets the first zoom (default: fit).
@MainActor
enum DevCanvas {
    static func fromEnvironment() -> CanvasViewController {
        let environment = ProcessInfo.processInfo.environment
        let canvas = CanvasViewController(document: openDocument(environment))
        canvas.initialZoom = environment["CANVAS_ZOOM"].flatMap(Double.init).map { CGFloat($0) }
        return canvas
    }

    private static func openDocument(_ environment: [String: String]) -> CanvasDocument? {
        do {
            if let path = environment["CANVAS_DOC"] { return try CanvasDocument.open(at: URL(fileURLWithPath: path)) }
            if let count = environment["CANVAS_DEMO_BOARDS"].flatMap(Int.init) { return try demoDocument(boards: count) }
        } catch {
            NSLog("Canvas: couldn't open the document: %@", String(describing: error))
        }
        return nil
    }

    /// A document in a temp folder with `count` 400×300 boards in a grid, each running an infinite
    /// CSS animation and a requestAnimationFrame loop.
    private static func demoDocument(boards count: Int) throws -> CanvasDocument {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasDemo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = try CanvasDocument.create(at: folder.appendingPathComponent("Demo.canvas", isDirectory: true))
        let columns = 6
        for index in 0..<count {
            try document.addArtboard(
                name: "Board \(index + 1)", width: 400, height: 300, html: demoBoardHTML(hue: index * 37 % 360),
                x: Double(index % columns) * 800, y: Double(index / columns) * 700
            )
        }
        return document
    }

    private static func demoBoardHTML(hue: Int) -> String {
        """
        <style>
        .board{width:400px;height:300px;position:relative;overflow:hidden;display:grid;place-items:center;
          background:linear-gradient(135deg,hsl(\(hue),70%,55%),hsl(\((hue + 60) % 360),70%,35%));
          font:600 40px -apple-system,system-ui;color:#fff}
        .orbit{position:absolute;left:180px;top:130px;width:40px;height:40px;border-radius:50%;
          background:rgba(255,255,255,.7);animation:orbit 2s linear infinite}
        @keyframes orbit{from{transform:rotate(0deg) translateX(110px)}to{transform:rotate(360deg) translateX(110px)}}
        </style>
        <div class="board"><div class="orbit"></div><span id="frames">0</span></div>
        <script>
        let frames = 0;
        const tick = () => { document.getElementById("frames").textContent = String(frames++); requestAnimationFrame(tick); };
        requestAnimationFrame(tick);
        </script>
        """
    }
}
#endif
