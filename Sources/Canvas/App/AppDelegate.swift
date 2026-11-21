import AppKit
import CanvasCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let agent = AgentConnection()
    private lazy var workspace = Workspace(agent: agent)
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let windowController = MainWindowController(workspace: workspace, agent: agent)
        self.windowController = windowController
        NSApp.mainMenu = MainMenu.make(openRecentDelegate: windowController)
        DevHooks.openFromEnvironment(in: workspace)
        windowController.showWindow(nil)
        NSApp.activate()
        startBridge()
    }

    /// Claude Code's config may have changed while Canvas was in the background.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await agent.checkRegistration() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        agent.stopBridge()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Startup failures show in the MCP panels, which offer a restart. Then reads whether Claude Code
    /// already has Canvas registered.
    private func startBridge() {
        Task {
            await agent.startBridge(for: workspace)
            await agent.checkRegistration()
        }
    }
}
