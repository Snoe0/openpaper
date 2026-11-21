import AppKit

/// After a key closes something, eats that key's auto-repeats until any other key event (its
/// release included), so a held Esc doesn't go on to act on the window underneath.
@MainActor
final class KeyRepeatSwallower {
    private var monitor: Any?

    isolated deinit {
        stop()
    }

    func swallowRepeats(ofKey keyCode: UInt16) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let isRepeat = event.keyCode == keyCode && event.type == .keyDown && event.isARepeat
            if !isRepeat { MainActor.assumeIsolated { self?.stop() } }
            return isRepeat ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
