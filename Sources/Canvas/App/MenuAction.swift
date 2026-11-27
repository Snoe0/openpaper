import AppKit

/// Runs a closure for a menu item; the item keeps it alive through `representedObject`.
final class MenuAction: NSObject {
    private let run: () -> Void

    private init(_ run: @escaping () -> Void) {
        self.run = run
    }

    static func item(_ title: String, run: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(run)
        let item = NSMenuItem(title: title, action: #selector(runAction), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }

    @objc private func runAction() {
        run()
    }
}
