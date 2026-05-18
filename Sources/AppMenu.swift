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
    private static var installed = false
    /// Tokens from the most recent `wireActivationPolicy` registration.
    /// Reassigned (not appended to) on each call: the old tokens are
    /// removed first, then a fresh batch is stored, so this slot is
    /// bounded by the number of notification names we observe — never
    /// grows across calls.
    private static var activationObservers: [NSObjectProtocol] = []
    /// Target for the About menu item. Needs to be an NSObject instance
    /// so AppKit can dispatch the selector; AppMenu itself is an enum.
    private static let aboutTarget = AboutPanelTarget()

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        install()
        wireActivationPolicy()
    }

    /// Without this, Tailscreen stays at `.accessory` activation policy (the
    /// MenuBarExtra default). When the viewer/sharer window becomes key
    /// macOS keeps showing whatever `.regular` app's menu bar was last
    /// up — observed: "Zed" sitting above a Tailscale Screen Share
    /// window. Promote to `.regular` while any of our windows is key,
    /// drop back to `.accessory` when they aren't, so the Dock icon
    /// stays absent in the idle state.
    private static func wireActivationPolicy() {
        let nc = NotificationCenter.default
        // Idempotent: tear down any prior registration so a repeat call
        // (today guarded by `installed`, but defensively bounded here)
        // can't accumulate stale observers leaking closures onto the
        // notification center. Empty == "nothing to remove".
        for obs in activationObservers { nc.removeObserver(obs) }
        activationObservers.removeAll()
        let updatePolicy: @Sendable @MainActor () -> Void = {
            let hasVisibleWindow = NSApp.windows.contains { w in
                w.isVisible && w.canBecomeKey
            }
            let target: NSApplication.ActivationPolicy = hasVisibleWindow ? .regular : .accessory
            if NSApp.activationPolicy() != target {
                NSApp.setActivationPolicy(target)
                if target == .regular {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        var fresh: [NSObjectProtocol] = []
        fresh.reserveCapacity(names.count)
        for n in names {
            let obs = nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                Task { @MainActor in updatePolicy() }
            }
            fresh.append(obs)
        }
        activationObservers = fresh
    }

    static func install() {
        let main = NSMenu(title: "MainMenu")

        // ── Application menu (titled by the active app, "Tailscreen") ──
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Tailscreen")
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(
            title: "About Tailscreen",
            action: #selector(AboutPanelTarget.showAboutPanel(_:)),
            keyEquivalent: "")
        aboutItem.target = aboutTarget
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let hide = NSMenuItem(
            title: "Hide Tailscreen",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        appMenu.addItem(hide)

        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.option, .command]
        appMenu.addItem(hideOthers)

        appMenu.addItem(
            .init(
                title: "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                keyEquivalent: ""))
        appMenu.addItem(.separator())

        appMenu.addItem(
            .init(
                title: "Quit Tailscreen",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))

        // ── File ──
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu

        let disconnect = NSMenuItem(
            title: "Disconnect",
            action: #selector(ViewerCommands.disconnectViewer(_:)),
            keyEquivalent: "w")
        disconnect.target = ViewerCommands.shared
        fileMenu.addItem(disconnect)

        let micItem = NSMenuItem(
            title: "Microphone",
            action: #selector(ViewerCommands.toggleMicrophone(_:)),
            keyEquivalent: "")
        micItem.target = ViewerCommands.shared
        fileMenu.addItem(micItem)

        // ── Edit ──
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        let undo = NSMenuItem(
            title: "Undo Annotation",
            action: #selector(ViewerCommands.undoLastAnnotation(_:)),
            keyEquivalent: "z")
        undo.target = ViewerCommands.shared
        editMenu.addItem(undo)

        editMenu.addItem(.separator())

        let clearAll = NSMenuItem(
            title: "Clear All Annotations",
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
            ("Pen", "1", #selector(ViewerCommands.selectPenTool(_:))),
            ("Line", "2", #selector(ViewerCommands.selectLineTool(_:))),
            ("Arrow", "3", #selector(ViewerCommands.selectArrowTool(_:))),
            ("Rectangle", "4", #selector(ViewerCommands.selectRectangleTool(_:))),
            ("Oval", "5", #selector(ViewerCommands.selectOvalTool(_:))),
            ("Click", "6", #selector(ViewerCommands.selectClickTool(_:))),
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
        windowMenu.addItem(
            .init(
                title: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"))
        windowMenu.addItem(
            .init(
                title: "Zoom",
                action: #selector(NSWindow.performZoom(_:)),
                keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            .init(
                title: "Bring All to Front",
                action: #selector(NSApplication.arrangeInFront(_:)),
                keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        // ── Help ──
        // ⇧⌘/ is the standard macOS "show help" shortcut — `/` is
        // shift-slash on a US layout, so we register "/" with command
        // and let the system add shift in the display.
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu

        let shortcutsHelp = NSMenuItem(
            title: "Keyboard Shortcuts",
            action: #selector(ViewerCommands.toggleShortcutsOverlay(_:)),
            keyEquivalent: "?")
        shortcutsHelp.keyEquivalentModifierMask = [.command]
        shortcutsHelp.target = ViewerCommands.shared
        helpMenu.addItem(shortcutsHelp)
        NSApp.helpMenu = helpMenu

        // Assemble.
        main.addItem(appMenuItem)
        main.addItem(fileItem)
        main.addItem(editItem)
        main.addItem(toolsItem)
        main.addItem(windowItem)
        main.addItem(helpItem)

        NSApp.mainMenu = main
    }
}

/// Backing object for the "About Tailscreen" menu item. The standard
/// about panel without options is essentially blank in dev builds (no
/// Info.plist) and sparse in release builds. Supplying an options dict
/// gives users the version, a short description, project link, and
/// license + copyright in one place.
@MainActor
private final class AboutPanelTarget: NSObject {
    @objc func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: Self.options())
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func options() -> [NSApplication.AboutPanelOptionKey: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = (info["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = info["CFBundleVersion"] as? String

        var opts: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Tailscreen",
            .applicationVersion: shortVersion,
            .credits: creditsAttributedString(),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Robert Sköld. MIT-licensed open source.",
        ]
        // Only surface the build number when it differs from the marketing
        // version — release.yml currently sets both to the same string, and
        // showing "1.2.0 (1.2.0)" is just noise.
        if let build, build != shortVersion {
            opts[.version] = build
        }
        return opts
    }

    private static func creditsAttributedString() -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 6

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: body,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]

        let credits = NSMutableAttributedString()
        credits.append(
            NSAttributedString(
                string: "Low-latency, encrypted peer-to-peer screen sharing over Tailscale.\n",
                attributes: baseAttrs))
        credits.append(
            NSAttributedString(
                string:
                    "Captures with ScreenCaptureKit, encodes H.264/HEVC with VideoToolbox, renders with Metal, and tunnels via tsnet ephemeral nodes — no manual device registration.\n",
                attributes: baseAttrs))

        let projectURL = URL(string: "https://github.com/middle-management/tailscreen")!
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .font: body,
            .foregroundColor: NSColor.linkColor,
            .link: projectURL,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .paragraphStyle: para,
        ]
        credits.append(
            NSAttributedString(
                string: "github.com/middle-management/tailscreen",
                attributes: linkAttrs))

        return credits
    }
}
