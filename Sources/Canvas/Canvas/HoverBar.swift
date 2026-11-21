import AppKit

/// The small bar above the hovered or selected board: play/pause, restart, and the token mode.
@MainActor
final class HoverBar: NSView {
    var onTogglePlay: (() -> Void)?
    var onRestart: (() -> Void)?
    var onCycleMode: (() -> Void)?

    private let playButton = HoverBar.button(symbol: "pause.fill", label: "Pause")
    private let restartButton = HoverBar.button(symbol: "arrow.counterclockwise", label: "Restart")
    private let modeButton = HoverBar.button(symbol: nil, label: "Switch mode")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.96).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        playButton.target = self
        playButton.action = #selector(togglePlay)
        restartButton.target = self
        restartButton.action = #selector(restart)
        modeButton.target = self
        modeButton.action = #selector(cycleMode)
        let stack = NSStackView(views: [playButton, restartButton, modeButton])
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the board's state; a nil mode hides the mode button (fewer than two modes), and restart
    /// only shows on a live board.
    func show(isPaused: Bool, mode: String?, canRestart: Bool) {
        playButton.image = NSImage(systemSymbolName: isPaused ? "play.fill" : "pause.fill", accessibilityDescription: isPaused ? "Play" : "Pause")
        playButton.toolTip = isPaused ? "Play" : "Pause"
        modeButton.title = mode ?? ""
        modeButton.isHidden = mode == nil
        restartButton.isHidden = !canRestart
    }

    @objc private func togglePlay() { onTogglePlay?() }
    @objc private func restart() { onRestart?() }
    @objc private func cycleMode() { onCycleMode?() }

    private static func button(symbol: String?, label: String) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = NSColor(white: 0.85, alpha: 1)
        button.toolTip = label
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
        }
        return button
    }
}
