import AppKit

/// A borderless black window over a whole screen, above the menu bar and Dock. It can become key
/// (borderless windows can't by default), so the page gets the keyboard, and it hides while another
/// app is active, so it never floats over other apps.
final class PresentationWindow: NSWindow {
    let stage = PresentationStage()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        hidesOnDeactivate = true
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        contentView = stage
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Covers the menu bar area too; AppKit would otherwise push the window below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func cover(_ screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }
}
