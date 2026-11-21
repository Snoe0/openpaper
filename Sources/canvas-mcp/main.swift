// canvas-mcp: the stdio MCP server Claude Code launches. It pipes every JSON-RPC message to the
// running Canvas app's localhost bridge and writes the app's responses back.
// Deliberately dependency-free: Foundation only, no CanvasCore.
import Foundation

let version = "0.1.0"

if CommandLine.arguments.dropFirst().contains("--version") {
    print("canvas-mcp \(version)")
    exit(0)
}

await StdioProxy(app: AppConnection(settings: .fromEnvironment())).run()
exit(0)
