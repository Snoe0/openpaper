import Foundation

/// Talks to the running Canvas app through the port and token it publishes in `bridge.json`,
/// launching the app first when it isn't running.
@MainActor
final class AppConnection {
    struct Settings {
        var bridgeFile: URL
        var mayLaunch: Bool
        var appBundleID: String

        /// `CANVAS_BRIDGE_FILE` overrides the bridge file location, `CANVAS_NO_LAUNCH` turns off launching,
        /// and `CANVAS_APP_BUNDLE_ID` names the app to launch when this helper isn't inside Canvas.app.
        static func fromEnvironment() -> Settings {
            let environment = ProcessInfo.processInfo.environment
            return Settings(
                bridgeFile: environment["CANVAS_BRIDGE_FILE"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? defaultBridgeFile,
                mayLaunch: environment["CANVAS_NO_LAUNCH"] == nil,
                appBundleID: environment["CANVAS_APP_BUNDLE_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "local.canvas.app"
            )
        }

        /// Must match `BridgeFile.defaultURL` in CanvasCore (the app isn't sandboxed, so it's the real home folder).
        static var defaultBridgeFile: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Canvas/bridge.json")
        }
    }

    enum Failure: LocalizedError {
        case notRunning(launched: Bool)
        case launchFailed(bundleID: String)
        case unauthorized
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .notRunning(launched: true):
                "Canvas isn't running and didn't start in time. Open the Canvas app, then try again."
            case .notRunning(launched: false):
                "Canvas isn't running. Open the Canvas app, then try again."
            case .launchFailed(let bundleID):
                "Couldn't launch Canvas (\(bundleID)). Open the Canvas app, then try again."
            case .unauthorized:
                "Canvas rejected the token in bridge.json. Quit and reopen Canvas, then try again."
            case .httpStatus(let status):
                "Canvas answered with HTTP status \(status)."
            }
        }
    }

    private struct Bridge: Decodable {
        let port: Int
        let token: String
        let pid: Int32
    }

    static let launchTimeout: Duration = .seconds(15)
    /// After a failed launch, messages fail right away for this long instead of launching again.
    static let launchCooldown: Duration = .seconds(30)
    static let requestTimeout: TimeInterval = 300
    static let probeTimeout: TimeInterval = 3

    private let settings: Settings
    private let session = URLSession(configuration: .ephemeral)
    private var bridge: Bridge?
    private var failedLaunch: (at: ContinuousClock.Instant, error: Error)?

    init(settings: Settings) {
        self.settings = settings
    }

    /// Posts one message to Canvas and returns its response body, or nil when there's none (notifications).
    func send(_ message: Data) async throws -> Data? {
        do {
            return try await post(message, to: connectedBridge())
        } catch where Self.wasNotDelivered(error) {
            // Canvas restarted (new port or token) since we connected: reconnect and send it once more.
            bridge = nil
            return try await post(message, to: connectedBridge())
        }
    }

    // MARK: - Connecting

    private func connectedBridge() async throws -> Bridge {
        if let bridge { return bridge }
        if let reachable = try await reachableBridge() { return remember(reachable) }
        guard settings.mayLaunch else { throw Failure.notRunning(launched: false) }
        if let failedLaunch, ContinuousClock.now - failedLaunch.at < Self.launchCooldown { throw failedLaunch.error }
        do {
            try launchCanvas()
            return remember(try await waitForCanvas())
        } catch {
            failedLaunch = (.now, error)
            throw error
        }
    }

    private func remember(_ bridge: Bridge) -> Bridge {
        self.bridge = bridge
        failedLaunch = nil
        return bridge
    }

    /// The bridge from `bridge.json` if its app is alive and answers a ping. Throws `.unauthorized` when
    /// the app answers but rejects the token, since relaunching wouldn't help.
    private func reachableBridge() async throws -> Bridge? {
        guard let data = try? Data(contentsOf: settings.bridgeFile),
              let bridge = try? JSONDecoder().decode(Bridge.self, from: data),
              kill(bridge.pid, 0) == 0 else { return nil }
        let ping = Data(#"{"jsonrpc":"2.0","id":"canvas-mcp-probe","method":"ping"}"#.utf8)
        do {
            _ = try await post(ping, to: bridge, timeout: Self.probeTimeout)
            return bridge
        } catch Failure.unauthorized {
            throw Failure.unauthorized
        } catch {
            return nil
        }
    }

    private func waitForCanvas() async throws -> Bridge {
        let deadline = ContinuousClock.now + Self.launchTimeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            if let bridge = try await reachableBridge() { return bridge }
        }
        throw Failure.notRunning(launched: true)
    }

    /// Opens the Canvas.app this helper is bundled in (`Canvas.app/Contents/Helpers/canvas-mcp`), else the app by bundle id.
    private func launchCanvas() throws {
        logLine("Canvas isn't running; launching it.")
        if let app = bundlingApp(), open([app.path]) { return }
        guard open(["-b", settings.appBundleID]) else { throw Failure.launchFailed(bundleID: settings.appBundleID) }
    }

    private func bundlingApp() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    /// Runs `/usr/bin/open` with `arguments`; true when it succeeded.
    private func open(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardOutput = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            logLine("couldn't run open: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - HTTP

    private func post(_ message: Data, to bridge: Bridge, timeout: TimeInterval = requestTimeout) async throws -> Data? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(bridge.port)/mcp")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = message
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bridge.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data.isEmpty ? nil : data
        case 202: return nil
        case 401: throw Failure.unauthorized
        case let status: throw Failure.httpStatus(status)
        }
    }

    /// Errors after which the message certainly never reached Canvas, so sending it again is safe.
    private static func wasNotDelivered(_ error: Error) -> Bool {
        if case Failure.unauthorized = error { return true }
        return (error as? URLError)?.code == .cannotConnectToHost
    }
}
