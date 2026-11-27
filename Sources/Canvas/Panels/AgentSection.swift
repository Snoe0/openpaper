import AppKit
import CanvasCore
import Observation

/// The MCP panel: live bridge status (listening port, connected client, last tool call), whether
/// Claude Code has Canvas registered, the button that connects or reconnects it, and "Restart
/// bridge" once the listener has stopped.
@MainActor
final class AgentSection: PanelSection {
    private let agent: AgentConnection
    private let status = Theme.label("")
    private let dot = FillView(Theme.tertiaryText)
    private let claude = InfoRow("Claude")
    private let client = InfoRow("Client")
    private let lastCall = InfoRow("Last call")
    private let problem = Theme.label("", size: Theme.smallSize, color: Theme.negative)
    private lazy var connectButton = Theme.button("Connect agent…", target: self, action: #selector(connectClicked))
    private lazy var restartButton = Theme.button("Restart bridge", target: self, action: #selector(restartClicked))
    private var isObserving = false

    init(agent: AgentConnection) {
        self.agent = agent
        super.init(title: "Agent")
        problem.maximumNumberOfLines = 4
        problem.lineBreakMode = .byWordWrapping
        problem.preferredMaxLayoutWidth = Theme.panelWidth - 2 * Theme.inset
        dot.layer?.cornerRadius = 3
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        addContent(Theme.column([
            Theme.row([dot, status], spacing: 6), client, lastCall, claude, problem,
            Theme.row([connectButton, restartButton]),
        ], spacing: 8))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !isObserving else { return }
        isObserving = true
        observe()
    }

    // MARK: - Status

    /// Renders now and again whenever anything it read changes.
    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        let bridge = agent.status
        showListener(port: bridge?.port)
        client.show(bridge?.client.map { "\($0.name) \($0.version)" } ?? "None yet", color: bridge?.client == nil ? Theme.tertiaryText : Theme.text)
        showLastCall(bridge?.lastCall)
        showRegistration()
        problem.stringValue = agent.startupError.map { "Bridge couldn't start: \($0)" } ?? ""
        problem.isHidden = agent.startupError == nil
        restartButton.isHidden = bridge?.isListening != false || agent.isStarting
    }

    private func showListener(port: UInt16?) {
        if let port {
            status.stringValue = "Listening on port \(port)"
        } else {
            status.stringValue = agent.isStarting ? "Starting bridge…" : "Bridge stopped"
        }
        status.textColor = port == nil ? Theme.secondaryText : Theme.text
        dot.color = port == nil ? (agent.isStarting ? Theme.tertiaryText : Theme.negative) : Theme.positive
    }

    private func showLastCall(_ call: ToolCallRecord?) {
        guard let call else { return lastCall.show("None yet", color: Theme.tertiaryText) }
        let time = call.date.formatted(date: .omitted, time: .standard)
        lastCall.show("\(call.name) · \(time)" + (call.succeeded ? "" : " · failed"), color: call.succeeded ? Theme.text : Theme.negative)
        lastCall.toolTip = call.errorMessage
    }

    /// The Claude row and the button: Connect, Reconnect, or nothing once connected.
    private func showRegistration() {
        let busy = agent.isRegistering
        claude.toolTip = nil
        switch agent.registration {
        case .connected:
            claude.show("Connected", color: Theme.positive)
        case .needsReconnect(let reason):
            claude.show("Needs reconnecting", color: Theme.negative)
            claude.toolTip = reason
        case .notRegistered:
            claude.show("Not connected", color: Theme.secondaryText)
        case nil:
            claude.show(busy ? "Checking…" : "Unknown", color: Theme.tertiaryText)
            claude.toolTip = agent.registrationProblem
        }
        connectButton.isHidden = agent.registration == .connected
        connectButton.isEnabled = !busy
        connectButton.title = busy ? "Working…" : isReconnect ? "Reconnect…" : "Connect agent…"
    }

    private var isReconnect: Bool {
        if case .needsReconnect = agent.registration { true } else { false }
    }

    // MARK: - Actions

    @objc private func restartClicked() {
        Task { await agent.restartBridge() }
    }

    /// Confirms with the exact commands, then runs them.
    @objc private func connectClicked() {
        let reconnect = isReconnect
        let alert = commandAlert(
            reconnect ? "Reconnect Claude Code to Canvas?" : "Connect Claude Code to Canvas?",
            reconnect
                ? "Claude Code's \"canvas\" entry is outdated or broken. Canvas will replace it for all your projects by running:"
                : "Canvas will add itself as an MCP server for all your Claude Code projects by running:",
            commands: reconnect ? [agent.entry.removeCommand, agent.entry.addCommand] : [agent.entry.addCommand]
        )
        alert.addButton(withTitle: reconnect ? "Reconnect" : "Connect")
        alert.addButton(withTitle: "Cancel")
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.run(reconnect: reconnect)
        }
    }

    private func run(reconnect: Bool) {
        Task {
            do {
                if reconnect { try await agent.reconnectAgent() } else { try await agent.connectAgent() }
                present(resultAlert())
            } catch {
                let commands = reconnect ? [agent.entry.removeCommand, agent.entry.addCommand] : [agent.entry.addCommand]
                present(commandAlert("Couldn't connect Claude Code", error.localizedDescription + "\n\nYou can run this yourself in Terminal:", commands: commands))
            }
        }
    }

    /// What the config says after Connect or Reconnect: "connected" only when it shows our helper.
    private func resultAlert() -> NSAlert {
        switch agent.registration {
        case .connected:
            return commandAlert("Claude Code is connected", "Start a new Claude Code session to use Canvas." + localScopeNote(), commands: [])
        case .needsReconnect(let reason):
            return commandAlert("Claude Code already has a \"canvas\" entry", "\(reason) Use Reconnect to point it at this copy of Canvas.", commands: [])
        case .notRegistered, nil:
            return commandAlert(
                "Couldn't confirm the connection",
                "claude finished, but Claude Code's settings don't show Canvas's entry. Check with `claude mcp list`, or try again.",
                commands: []
            )
        }
    }

    /// Mentions projects whose local-scope entry overrides the user entry.
    private func localScopeNote() -> String {
        let projects = agent.localScopeProjects
        guard !projects.isEmpty else { return "" }
        return "\n\nIn \(projects.joined(separator: ", ")), a local-scope \"canvas\" entry overrides this one; remove it there with `claude mcp remove --scope local canvas`."
    }

    /// Shows the alert as a sheet on this panel's window, or the main window if the panel has gone.
    private func present(_ alert: NSAlert, then handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        guard let window = window ?? NSApp.mainWindow else {
            let response = alert.runModal()
            handler?(response)
            return
        }
        alert.beginSheetModal(for: window, completionHandler: handler)
    }

    /// An alert that shows commands as selectable text, so they can be copied.
    private func commandAlert(_ message: String, _ information: String, commands: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        guard !commands.isEmpty else { return alert }
        let text = NSTextField(wrappingLabelWithString: commands.joined(separator: "\n"))
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: Theme.smallSize, weight: .regular)
        text.preferredMaxLayoutWidth = 320
        text.frame.size = text.fittingSize
        alert.accessoryView = text
        return alert
    }
}
