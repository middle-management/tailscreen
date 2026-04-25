import AppKit

/// Builds and installs the app's standard NSMenu bar. With only a
/// MenuBarExtra scene (no SwiftUI Window), AppKit auto-hides the menu
/// bar entirely, so users can't find an obvious place for shortcuts
/// like ⌘1–⌘5 (tools), ⌘Z (undo), ⇧⌘⌫ (clear all). Building a real
/// NSMenu and assigning it to `NSApp.mainMenu` makes the menu bar
/// appear whenever any of our windows is key — typically the viewer
/// window or the sharer's annotation panel.
@MainActor
enum AppMenu {
    static func install() {
        let main = NSMenu(title: "MainMenu")

        // ── Application menu (titled by the active app, "Cuple") ──
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Cuple")
        appMenuItem.submenu = appMenu

        appMenu.addItem(.init(title: "About Cuple",
                              action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                              keyEquivalent: ""))
        appMenu.addItem(.separator())

        let hide = NSMenuItem(title: "Hide Cuple",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        appMenu.addItem(hide)

        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.option, .command]
        appMenu.addItem(hideOthers)

        appMenu.addItem(.init(title: "Show All",
                              action: #selector(NSApplication.unhideAllApplications(_:)),
                              keyEquivalent: ""))
        appMenu.addItem(.separator())

        appMenu.addItem(.init(title: "Quit Cuple",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q"))

        // ── File ──
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu

        let disconnect = NSMenuItem(title: "Disconnect",
                                    action: #selector(ViewerCommands.disconnectViewer(_:)),
                                    keyEquivalent: "w")
        disconnect.target = ViewerCommands.shared
        fileMenu.addItem(disconnect)

        // ── Edit ──
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        let undo = NSMenuItem(title: "Undo Annotation",
                              action: #selector(ViewerCommands.undoLastAnnotation(_:)),
                              keyEquivalent: "z")
        undo.target = ViewerCommands.shared
        editMenu.addItem(undo)

        editMenu.addItem(.separator())

        let clearAll = NSMenuItem(title: "Clear All Annotations",
                                  action: #selector(ViewerCommands.clearAllAnnotations(_:)),
                                  keyEquivalent: "\u{8}")  // delete
        clearAll.keyEquivalentModifierMask = [.command, .shift]
        clearAll.target = ViewerCommands.shared
        editMenu.addItem(clearAll)

        // ── Tools ──
        let toolsItem = NSMenuItem()
        let toolsMenu = NSMenu(title: "Tools")
        toolsItem.submenu = toolsMenu

        let toolDefs: [(String, String, Selector)] = [
            ("Pen",       "1", #selector(ViewerCommands.selectPenTool(_:))),
            ("Line",      "2", #selector(ViewerCommands.selectLineTool(_:))),
            ("Arrow",     "3", #selector(ViewerCommands.selectArrowTool(_:))),
            ("Rectangle", "4", #selector(ViewerCommands.selectRectangleTool(_:))),
            ("Oval",      "5", #selector(ViewerCommands.selectOvalTool(_:))),
        ]
        for (title, key, action) in toolDefs {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = ViewerCommands.shared
            toolsMenu.addItem(item)
        }

        // ── Window (standard) ──
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(.init(title: "Minimize",
                                 action: #selector(NSWindow.performMiniaturize(_:)),
                                 keyEquivalent: "m"))
        windowMenu.addItem(.init(title: "Zoom",
                                 action: #selector(NSWindow.performZoom(_:)),
                                 keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(.init(title: "Bring All to Front",
                                 action: #selector(NSApplication.arrangeInFront(_:)),
                                 keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        // Assemble.
        main.addItem(appMenuItem)
        main.addItem(fileItem)
        main.addItem(editItem)
        main.addItem(toolsItem)
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
