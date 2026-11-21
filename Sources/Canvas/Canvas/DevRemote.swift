#if DEBUG
import AppKit
import CanvasCore

/// Debug-only dev hook for driving the canvas without Accessibility or Screen Recording permissions. With
/// `CANVAS_REMOTE=/path/prefix` set, `kill -USR1 <pid>` runs the commands in `<prefix>.cmd`, one per line,
/// through real window events:
///   capture | wait <ms> | key <keyCode> [shift] | click <x> <y> [shift] [double] | move <x> <y>
///   drag <x1> <y1> <x2> <y2> | scroll <dx> <dy> [cmd] | tool select|hand|inspect | state | snapshot <artboard-id>
///   write <artboard-id> <html…> | token <name> <value> | miniaturize | deminiaturize
/// Points are in window content coordinates, top-left origin. `capture` writes `<prefix>-<n>.png`;
/// `state` and `snapshot` append to `<prefix>.out` and write `<prefix>-<id>.png`.
@MainActor
enum DevRemote {
    private static var source: (any DispatchSourceSignal)?
    private static var captures = 0

    static func install(for window: NSWindow, canvas: CanvasViewController) {
        guard let prefix = ProcessInfo.processInfo.environment["CANVAS_REMOTE"] else { return }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak window, weak canvas] in
            MainActor.assumeIsolated {
                guard let window, let canvas else { return }
                Task { await run(prefix: prefix, window: window, canvas: canvas) }
            }
        }
        source.resume()
        self.source = source
    }

    private static func run(prefix: String, window: NSWindow, canvas: CanvasViewController) async {
        let script = (try? String(contentsOfFile: prefix + ".cmd", encoding: .utf8)) ?? ""
        for line in script.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            guard let command = words.first else { continue }
            let numbers = words.dropFirst().compactMap(Double.init).map { CGFloat($0) }
            let flags: NSEvent.ModifierFlags = words.contains("shift") ? .shift : words.contains("cmd") ? .command : []
            switch command {
            case "capture":
                captures += 1
                capture(window, to: "\(prefix)-\(captures).png")
            case "wait": try? await Task.sleep(for: .milliseconds(Int(numbers.first ?? 100)))
            case "key": key(UInt16(numbers[0]), flags: flags, in: window)
            case "click": click(at: point(numbers[0], numbers[1], in: window), flags: flags, double: words.contains("double"), in: window)
            case "move": mouse(.mouseMoved, at: point(numbers[0], numbers[1], in: window), in: window)
            case "drag": drag(from: point(numbers[0], numbers[1], in: window), to: point(numbers[2], numbers[3], in: window), in: window)
            case "scroll": scroll(dx: numbers[0], dy: numbers[1], flags: flags, in: window)
            case "write":
                do { try canvas.document?.writeHTML(words.dropFirst(2).joined(separator: " "), toArtboard: words[1]) } catch { append("write failed: \(error)", to: prefix + ".out") }
            case "token": try? canvas.document?.setTokens([words[1]: .single(words[2])])
            case "miniaturize": window.miniaturize(nil)
            case "deminiaturize": window.deminiaturize(nil)
            case "tool": canvas.setTool(["hand": .hand, "inspect": .inspect][words[1]] ?? .select)
            case "state": append(state(of: canvas), to: prefix + ".out")
            case "snapshot":
                let start = ContinuousClock.now
                let png = try? await canvas.snapshotPNG(artboardID: words[1])
                try? png?.write(to: URL(fileURLWithPath: "\(prefix)-\(words[1]).png"))
                append("snapshot \(words[1]): \(png?.count ?? 0) bytes in \(ContinuousClock.now - start)", to: prefix + ".out")
            default: append("unknown command: \(line)", to: prefix + ".out")
            }
        }
    }

    private static func state(of canvas: CanvasViewController) -> String {
        let element = canvas.selection.element.map { "\($0.artboardID) \($0.selector) \($0.rect)" } ?? "none"
        let console = canvas.consoleLogs(artboardID: nil).suffix(3).map { "\($0.artboardID):\($0.level):\($0.message)" }
        return """
        doc=\(canvas.document?.url.path ?? "none")
        zoom=\(canvas.zoom) tool=\(canvas.tool) selected=\(canvas.selection.artboardIDs) element=\(element)
        live=\(canvas.pool.live) paused=\(canvas.pool.paused) crashed=\(canvas.crashedBoards.sorted()) inspected=\(canvas.inspectedID ?? "none")
        console(last 3 of \(canvas.consoleLogs(artboardID: nil).count))=\(console)
        """
    }

    // MARK: - Events

    /// Window content point (top-left origin) → window base coordinates (bottom-left origin).
    private static func point(_ x: CGFloat, _ y: CGFloat, in window: NSWindow) -> CGPoint {
        CGPoint(x: x, y: (window.contentView?.bounds.height ?? 0) - y)
    }

    private static func key(_ code: UInt16, flags: NSEvent.ModifierFlags, in window: NSWindow) {
        let characters = code == 53 ? "\u{1b}" : ""
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            )
            event.map(window.sendEvent)
        }
    }

    private static func click(at point: CGPoint, flags: NSEvent.ModifierFlags, double: Bool, in window: NSWindow) {
        for count in double ? [1, 2] : [1] {
            // Queue the release first: a button tracks the mouse in its own loop until it sees it.
            mouseEvent(.leftMouseUp, at: point, flags: flags, clickCount: count, in: window).map { NSApp.postEvent($0, atStart: false) }
            mouse(.leftMouseDown, at: point, flags: flags, clickCount: count, in: window)
        }
    }

    private static func drag(from start: CGPoint, to end: CGPoint, in window: NSWindow) {
        mouse(.leftMouseDown, at: start, in: window)
        for step in 1...10 {
            let t = CGFloat(step) / 10
            mouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t), in: window)
        }
        mouse(.leftMouseUp, at: end, in: window)
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = [], clickCount: Int = 1, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = [], clickCount: Int = 1, in window: NSWindow) {
        guard let event = mouseEvent(type, at: point, flags: flags, clickCount: clickCount, in: window) else { return }
        if type == .mouseMoved, let view = window.contentView { return view.mouseMoved(with: event) }
        window.sendEvent(event)
    }

    /// A pixel (precise) scroll at the window centre.
    private static func scroll(dx: CGFloat, dy: CGFloat, flags: NSEvent.ModifierFlags, in window: NSWindow) {
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        let frame = window.frame
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: frame.midX, y: screenHeight - frame.midY)
        if flags.contains(.command) { cgEvent.flags = .maskCommand }
        NSEvent(cgEvent: cgEvent).map(window.sendEvent)
    }

    // MARK: - Output

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage` is hidden from the macOS 15 SDK but still captures one's own windows.
    private static func capture(_ window: NSWindow, to path: String) {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3, boundsIgnoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        guard let image = create(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private static func append(_ text: String, to path: String) {
        let line = Data((text + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: line)
        }
    }
}
#endif
