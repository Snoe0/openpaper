import AppKit

extension NSView {
    /// Device pixels per point where the view is drawn: its window's screen, else the main screen, else 2.
    var screenScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}
