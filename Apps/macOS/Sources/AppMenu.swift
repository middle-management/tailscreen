import AppKit

/// Builds and installs the app's standard NSMenu bar. SwiftUI's scenes
/// install their own minimal mainMenu (Tailscreen / View / Window / Help)
/// and re-assert it across scene updates; building a real NSMenu and
/// assigning it to `NSApp.mainMenu` gives shortcuts like ⌘1–⌘5 (tools),
/// ⌘Z (undo), ⇧⌘⌫ (clear all) an obvious, discoverable home. The app runs
/// at `.regular` activation policy (docked main window + Dock icon — set
/// once in `AppEntry`), so the menu bar is visible whenever Tailscreen is
/// frontmost.
@MainActor
enum AppMenu {
    private static var installed = false
    /// Target for the About menu item. Needs to be an NSObject instance
    /// so AppKit can dispatch the selector; AppMenu itself is an enum.
    private static let aboutTarget = AboutPanelTarget()

    static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        install()
    }

    /// Re-apply `NSApp.mainMenu`. Called from the app delegate's
    /// `applicationDidBecomeActive` to recover from SwiftUI's
    /// scene machinery resetting the menu after a scene update.
    static func reinstall() {
        install()
    }

    static func install() {
        let main = NSMenu(title: "MainMenu")

        // ── Application menu (titled by the active app, "Tailscreen") ──
        // Each top-level menu sets its parent NSMenuItem.title explicitly:
        // macOS 15+ ("Liquid Glass") derives the menu-bar label from the
        // item's title rather than falling back to the submenu's title,
        // so items left at the empty default silently disappear from the
        // bar (their submenus and shortcuts still exist, just unreachable).
        let appMenuItem = NSMenuItem(title: "Tailscreen", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Tailscreen")
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(
            title: L("About Tailscreen"),
            action: #selector(AboutPanelTarget.showAboutPanel(_:)),
            keyEquivalent: "")
        aboutItem.target = aboutTarget
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        // ⌘, — the standard macOS Settings shortcut. SwiftUI's `Settings`
        // scene would normally supply this item, but we own `NSApp.mainMenu`
        // outright, so we add it by hand and route it through ViewerCommands
        // (the shared NSMenu target) into `AppState.presentSettings()`.
        let settings = NSMenuItem(
            title: L("Settings…"),
            action: #selector(ViewerCommands.openSettings(_:)),
            keyEquivalent: ",")
        settings.target = ViewerCommands.shared
        appMenu.addItem(settings)
        appMenu.addItem(.separator())

        let hide = NSMenuItem(
            title: L("Hide Tailscreen"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        appMenu.addItem(hide)

        let hideOthers = NSMenuItem(
            title: L("Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.option, .command]
        appMenu.addItem(hideOthers)

        appMenu.addItem(
            .init(
                title: L("Show All"),
                action: #selector(NSApplication.unhideAllApplications(_:)),
                keyEquivalent: ""))
        appMenu.addItem(.separator())

        appMenu.addItem(
            .init(
                title: L("Quit Tailscreen"),
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))

        // ── File ──
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu

        let disconnect = NSMenuItem(
            title: L("Disconnect"),
            action: #selector(ViewerCommands.disconnectViewer(_:)),
            keyEquivalent: "w")
        disconnect.target = ViewerCommands.shared
        fileMenu.addItem(disconnect)

        // Mirrors the global mic-toggle hotkey (⌃⌥M unless remapped in
        // Settings → Keyboard Shortcuts), exactly as Stop Remote Control
        // below mirrors the panic-revoke chord. A menu key equivalent only
        // fires while Tailscreen is frontmost — the global registration
        // covers the rest — but printing it here is what makes the shortcut
        // *findable*: the menu is the first place a Mac user looks, and it
        // is also what feeds Help-menu search, VoiceOver, and remapping in
        // System Settings → Keyboard Shortcuts. Registered and undocumented
        // is the same as not registered.
        //
        // The chord comes from the live AppState when one exists (it always
        // does after `AppState.init` assigns `ViewerCommands.shared.appState`
        // — chord edits call `reinstall()` through that same AppState); the
        // persisted store covers the first install racing launch, and the
        // two can't disagree because AppState saves before reinstalling. An
        // unmappable stored key leaves the equivalent empty rather than
        // printing a chord that won't fire.
        let micChord = ViewerCommands.shared.appState?.micHotkeyChord ?? HotkeyChordStore.loadMic()
        let micItem = NSMenuItem(
            title: L("Microphone"),
            action: #selector(ViewerCommands.toggleMicrophone(_:)),
            keyEquivalent: "")
        if let equivalent = micChord.menuKeyEquivalent {
            micItem.keyEquivalent = equivalent.key
            micItem.keyEquivalentModifierMask = equivalent.mask
        }
        micItem.target = ViewerCommands.shared
        fileMenu.addItem(micItem)

        fileMenu.addItem(.separator())

        // Sharer-side panic revoke, mirroring the global hotkey (⌃⌥. unless
        // remapped). Disabled (via ViewerCommands validation) unless a
        // viewer holds control. Same chord sourcing as the mic item above.
        let revokeChord =
            ViewerCommands.shared.appState?.revokeHotkeyChord ?? HotkeyChordStore.loadRevoke()
        let stopControl = NSMenuItem(
            title: L("Stop Remote Control"),
            action: #selector(ViewerCommands.stopRemoteControl(_:)),
            keyEquivalent: "")
        if let equivalent = revokeChord.menuKeyEquivalent {
            stopControl.keyEquivalent = equivalent.key
            stopControl.keyEquivalentModifierMask = equivalent.mask
        }
        stopControl.target = ViewerCommands.shared
        fileMenu.addItem(stopControl)

        // Viewer-side counterpart: release the control *we* hold on someone
        // else's Mac (or cancel a pending request). Deliberately the same
        // chord as the sharer-side revoke above — one muscle memory for
        // "stop remote control" in either role, so it follows the same
        // remappable chord — with the two validations disjoint by state so
        // they never both enable. The chord is also intercepted inside
        // `RemoteControlInputView`, where every other keystroke is
        // forwarded to the sharer.
        let releaseControl = NSMenuItem(
            title: L("Release Remote Control"),
            action: #selector(ViewerCommands.releaseRemoteControl(_:)),
            keyEquivalent: "")
        if let equivalent = revokeChord.menuKeyEquivalent {
            releaseControl.keyEquivalent = equivalent.key
            releaseControl.keyEquivalentModifierMask = equivalent.mask
        }
        releaseControl.target = ViewerCommands.shared
        fileMenu.addItem(releaseControl)

        // ── Edit ──
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        let undo = NSMenuItem(
            title: L("Undo Annotation"),
            action: #selector(ViewerCommands.undoLastAnnotation(_:)),
            keyEquivalent: "z")
        undo.target = ViewerCommands.shared
        editMenu.addItem(undo)

        editMenu.addItem(.separator())

        let clearAll = NSMenuItem(
            title: L("Clear All Annotations"),
            action: #selector(ViewerCommands.clearAllAnnotations(_:)),
            keyEquivalent: "\u{8}")  // delete
        clearAll.keyEquivalentModifierMask = [.command, .shift]
        clearAll.target = ViewerCommands.shared
        editMenu.addItem(clearAll)

        // ── View ──
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu

        let actualSize = NSMenuItem(
            title: L("Actual Size"),
            action: #selector(ViewerCommands.viewerZoomActualSize(_:)),
            keyEquivalent: "0")
        actualSize.target = ViewerCommands.shared
        viewMenu.addItem(actualSize)

        let zoomHalf = NSMenuItem(
            title: L("Zoom to 50%"),
            action: #selector(ViewerCommands.viewerZoomHalf(_:)),
            keyEquivalent: "-")
        zoomHalf.target = ViewerCommands.shared
        viewMenu.addItem(zoomHalf)

        let zoomDouble = NSMenuItem(
            title: L("Zoom to 200%"),
            action: #selector(ViewerCommands.viewerZoomDouble(_:)),
            keyEquivalent: "+")
        zoomDouble.target = ViewerCommands.shared
        viewMenu.addItem(zoomDouble)

        viewMenu.addItem(.separator())

        // Continuous content zoom (⌥⌘+ / ⌥⌘-) — magnifies a region of
        // the received video inside the current window, unlike the
        // window-sizing presets above. Pinch / ⌥-scroll on the viewer
        // window do the same anchored at the cursor. ⌥⌘ (not ⇧⌘): "+"
        // is already a shifted character, so ⇧⌘+ would collide with
        // the "Zoom to 200%" preset's plain ⌘+ above.
        let contentZoomIn = NSMenuItem(
            title: L("Zoom In"),
            action: #selector(ViewerCommands.viewerContentZoomIn(_:)),
            keyEquivalent: "+")
        contentZoomIn.keyEquivalentModifierMask = [.command, .option]
        contentZoomIn.target = ViewerCommands.shared
        viewMenu.addItem(contentZoomIn)

        let contentZoomOut = NSMenuItem(
            title: L("Zoom Out"),
            action: #selector(ViewerCommands.viewerContentZoomOut(_:)),
            keyEquivalent: "-")
        contentZoomOut.keyEquivalentModifierMask = [.command, .option]
        contentZoomOut.target = ViewerCommands.shared
        viewMenu.addItem(contentZoomOut)

        viewMenu.addItem(.separator())

        // ⌃⌘F — the standard macOS full-screen chord, aimed at the viewer
        // window (the SwiftUI hub scene manages its own). Validation flips
        // the title between Enter and Exit and requires the viewer window
        // to be on screen.
        let fullScreen = NSMenuItem(
            title: L("Enter Full Screen"),
            action: #selector(ViewerCommands.toggleViewerFullScreen(_:)),
            keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        fullScreen.target = ViewerCommands.shared
        viewMenu.addItem(fullScreen)

        // ── Tools ──
        let toolsItem = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        let toolsMenu = NSMenu(title: "Tools")
        toolsItem.submenu = toolsMenu

        let toolDefs: [(String, String, Selector)] = [
            (L("Pen"), "1", #selector(ViewerCommands.selectPenTool(_:))),
            (L("Line"), "2", #selector(ViewerCommands.selectLineTool(_:))),
            (L("Arrow"), "3", #selector(ViewerCommands.selectArrowTool(_:))),
            (L("Rectangle"), "4", #selector(ViewerCommands.selectRectangleTool(_:))),
            (L("Oval"), "5", #selector(ViewerCommands.selectOvalTool(_:))),
            (L("Click"), "6", #selector(ViewerCommands.selectClickTool(_:)))
        ]
        for (title, key, action) in toolDefs {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = ViewerCommands.shared
            toolsMenu.addItem(item)
        }

        // ── Window (standard) ──
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu

        // Re-open the docked main window after the user closed it —
        // otherwise the only ways back are the Dock icon and the menubar
        // popover's "Open Tailscreen" row. "Tailscreen" is a brand noun,
        // deliberately unlocalized.
        let mainWindow = NSMenuItem(
            title: "Tailscreen",
            action: #selector(ViewerCommands.showMainWindow(_:)),
            keyEquivalent: "")
        mainWindow.target = ViewerCommands.shared
        windowMenu.addItem(mainWindow)
        windowMenu.addItem(.separator())

        windowMenu.addItem(
            .init(
                title: L("Minimize"),
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"))
        windowMenu.addItem(
            .init(
                title: L("Zoom"),
                action: #selector(NSWindow.performZoom(_:)),
                keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            .init(
                title: L("Bring All to Front"),
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
            title: L("Keyboard Shortcuts"),
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
        main.addItem(viewItem)
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

        let copyright = L("© 2026 Robert Sköld. MIT-licensed open source.")
        var opts: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Tailscreen",
            .applicationVersion: shortVersion,
            .credits: creditsAttributedString(),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright
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
            .paragraphStyle: para
        ]

        let credits = NSMutableAttributedString()
        credits.append(
            NSAttributedString(
                string: L("Low-latency, encrypted peer-to-peer screen sharing over Tailscale.\n"),
                attributes: baseAttrs))
        credits.append(
            NSAttributedString(
                string:
                    L(
                        "Captures with ScreenCaptureKit, encodes H.264/HEVC with VideoToolbox, renders with Metal, and tunnels via tsnet ephemeral nodes — no manual device registration.\n"
                    ),
                attributes: baseAttrs))

        let projectURL = URL(string: "https://github.com/middle-management/tailscreen")!
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .font: body,
            .foregroundColor: NSColor.linkColor,
            .link: projectURL,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .paragraphStyle: para
        ]
        credits.append(
            NSAttributedString(
                string: "github.com/middle-management/tailscreen",
                attributes: linkAttrs))

        return credits
    }
}
