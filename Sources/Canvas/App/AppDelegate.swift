import AppKit
import CanvasCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = makeMainMenu()
        window = makeMainWindow()
        showCanvas()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Temporary until the app shell (T6): the canvas fills the window, configured from the environment.
    private func showCanvas() {
        guard let window else { return }
        let canvas = DevCanvas.fromEnvironment()
        canvas.view.frame = window.contentView?.bounds ?? .zero
        window.contentViewController = canvas
        window.makeFirstResponder(canvas.canvasView)
        #if DEBUG
        DevRemote.install(for: window, canvas: canvas)
        #endif
    }

    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Canvas"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Canvas", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        return mainMenu
    }
}
