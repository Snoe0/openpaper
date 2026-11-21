import AppKit

/// Hides the pointer after `idleDelay` without movement; AppKit shows it again on the next move.
/// One timer, pushed back on every move. `stop()` always leaves the pointer visible.
@MainActor
final class IdleCursorHider {
    static let idleDelay: TimeInterval = 2

    private var timer: Timer?

    isolated deinit {
        timer?.invalidate()
    }

    /// Starts (or pushes back) the idle countdown; call it on every pointer move.
    func pointerMoved() {
        let fireDate = Date(timeIntervalSinceNow: Self.idleDelay)
        if let timer, timer.isValid {
            timer.fireDate = fireDate
        } else {
            timer = Self.scheduleHiding(at: fireDate)
        }
    }

    /// Shows the pointer again, if a countdown ever ran (the timer is kept after it fires).
    func stop() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    private static func scheduleHiding(at fireDate: Date) -> Timer {
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { hideIfActive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private static func hideIfActive() {
        guard NSApp.isActive else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
    }
}
