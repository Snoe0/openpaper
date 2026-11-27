import AppKit

/// The menu bar. Commands go to the first responder, so they reach `MainWindowController`
/// (or a text field, for Edit) through the responder chain.
@MainActor
enum MainMenu {
    static func make(openRecentDelegate: NSMenuDelegate) -> NSMenu {
        let menu = NSMenu()
        for submenu in [appMenu(), fileMenu(openRecentDelegate: openRecentDelegate), editMenu(), viewMenu(), windowMenu()] {
            let item = NSMenuItem()
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Canvas")
        menu.addItem(withTitle: "About Canvas", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Canvas", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(command("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Canvas", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu(openRecentDelegate: NSMenuDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(command("New Document…", #selector(MainWindowController.newDocument(_:)), "n"))
        menu.addItem(command("Open…", #selector(MainWindowController.openDocument(_:)), "o"))
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Open Recent")
        recent.submenu?.delegate = openRecentDelegate
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(command("Close Tab", #selector(MainWindowController.closeTab(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(command("Undo", Selector(("undo:")), "z"))
        menu.addItem(command("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(command("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(command("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(command("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(command("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(command("Zoom In", #selector(MainWindowController.zoomIn(_:)), "="))
        menu.addItem(command("Zoom Out", #selector(MainWindowController.zoomOut(_:)), "-"))
        menu.addItem(command("Actual Size", #selector(MainWindowController.actualSize(_:)), "0"))
        menu.addItem(command("Zoom to Fit", #selector(MainWindowController.zoomToFit(_:)), shownShortcut: "⇧1"))
        menu.addItem(command("Zoom to Selection", #selector(MainWindowController.zoomToSelection(_:)), shownShortcut: "⇧2"))
        menu.addItem(.separator())
        menu.addItem(command("Hide Sidebar", #selector(MainWindowController.toggleSidebar(_:)), "s", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(command("Present", #selector(MainWindowController.presentArtboard(_:)), "\r"))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(command("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        return menu
    }

    /// A command whose shortcut the canvas handles itself, by key code, while it has focus: Shift with
    /// a digit arrives as "!" or "@", which a menu key equivalent can't match, so the menu only shows it.
    private static func command(_ title: String, _ action: Selector, shownShortcut: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 200)]
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: title, attributes: [.font: font, .paragraphStyle: style])
        text.append(NSAttributedString(string: "\t" + shownShortcut, attributes: [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = text
        return item
    }

    private static func command(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
