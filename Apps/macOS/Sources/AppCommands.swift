import AppKit
import SwiftUI

/// The app's menu bar, declared through SwiftUI `Commands` instead of a
/// hand-built `NSMenu`.
///
/// A hand-built menu had to be reinstalled on every activation because
/// SwiftUI's scene machinery re-asserts its own minimal menu across scene
/// updates — and while sharing, the popover re-renders about once a second
/// with no activation edge to trigger a re-fix, so Settings/File/Tools would
/// silently vanish mid-session. Declaring the menu here closes that hole by
/// construction: the menu SwiftUI re-asserts *is* this one.
///
/// Enabling/checkmarks are `.disabled(_:)`/`Toggle` driven off `appState` —
/// the canvas model's changes forward into `appState.objectWillChange`
/// (`ensureViewer`), so tool checkmarks and Undo/Clear stay live.
struct AppCommands: Commands {
    @ObservedObject var appState: AppState

    /// Toolbar/canvas order — mirrors `ViewerCommands.toolbarSelectedTool`.
    private static let tools: [(title: String, tool: AnnotationTool, key: Character)] = [
        (L("Pen"), .pen, "1"),
        (L("Line"), .line, "2"),
        (L("Arrow"), .arrow, "3"),
        (L("Rectangle"), .rectangle, "4"),
        (L("Oval"), .oval, "5"),
        (L("Click"), .click, "6")
    ]

    var body: some Commands {
        // ── Tailscreen (app menu) ──
        CommandGroup(replacing: .appInfo) {
            Button(L("About Tailscreen")) {
                AboutPanel.show()
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button(L("Settings…")) {
                appState.presentSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        // ── File ──
        // No New Window: the hub is a single re-openable window, and the
        // viewer window is created by connecting, not ⌘N.
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .saveItem) {
            // ⌘W acts on a session: disconnect while viewing, or close the
            // ended-state viewer window. No plain Close item.
            Button(L("Disconnect")) {
                NotificationCenter.default.post(
                    name: .tailscreenDisconnectRequested, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(
                appState.connectionState != .viewing && !appState.viewerSessionIsOver)

            // Mirrors the global mic-toggle hotkey (⌃⌥M unless remapped).
            // Printing it here makes the shortcut findable via Help-menu
            // search, VoiceOver, and System Settings → Keyboard Shortcuts.
            Button(appState.isMicOn ? L("Mute Microphone") : L("Unmute Microphone")) {
                NotificationCenter.default.post(
                    name: .tailscreenToggleMicrophone, object: nil)
            }
            .keyboardShortcut(appState.micHotkeyChord.swiftUIShortcut)

            Divider()

            // Sharer-side revoke and viewer-side release share one chord
            // (⌃⌥. unless remapped). A key equivalent fires the FIRST
            // enabled item, so the revoke yields the chord while *we* are
            // controlling someone else's Mac (still one click away on the
            // SharingCard).
            Button(L("Stop Remote Control")) {
                appState.revokeRemoteControl(reason: "menu")
            }
            .keyboardShortcut(appState.revokeHotkeyChord.swiftUIShortcut)
            .disabled(
                appState.controlGrantee == nil
                    || appState.viewerControlState == .controlling)

            Button(L("Release Remote Control")) {
                appState.stopViewerControl()
            }
            .keyboardShortcut(appState.revokeHotkeyChord.swiftUIShortcut)
            .disabled(appState.viewerControlState != .controlling)
        }

        // ── Edit ──
        // Only the undo region is replaced: annotations have their own undo
        // model, and a focused text field's undo comes back once a canvas
        // isn't active. The pasteboard region is left alone.
        CommandGroup(replacing: .undoRedo) {
            Button(L("Undo Annotation")) {
                ViewerCommands.shared.activeOverlay?.performLocalUndo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(ViewerCommands.shared.activeOverlay?.canUndo ?? false))

            Button(L("Clear All Annotations")) {
                ViewerCommands.shared.activeOverlay?.clearAll()
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(!(ViewerCommands.shared.activeOverlay?.canClearAll ?? false))
        }

        // ── View ──
        // Window-sizing presets + continuous content zoom. The system
        // supplies Enter Full Screen (⌃⌘F) per key window.
        CommandGroup(before: .toolbar) {
            Button(L("Actual Size")) { postViewerZoom(1.0) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(appState.connectionState != .viewing)
            Button(L("Zoom to 50%")) { postViewerZoom(0.5) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(appState.connectionState != .viewing)
            Button(L("Zoom to 200%")) { postViewerZoom(2.0) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(appState.connectionState != .viewing)

            Divider()

            // ⌥⌘ (not ⇧⌘): "+" is already a shifted character, so ⇧⌘+ would
            // collide with the plain ⌘+ preset above.
            Button(L("Zoom In")) {
                appState.zoomViewerContent(by: ViewerZoomMath.menuZoomStep)
            }
            .keyboardShortcut("+", modifiers: [.command, .option])
            .disabled(appState.connectionState != .viewing)
            Button(L("Zoom Out")) {
                appState.zoomViewerContent(by: 1 / ViewerZoomMath.menuZoomStep)
            }
            .keyboardShortcut("-", modifiers: [.command, .option])
            .disabled(appState.connectionState != .viewing)
        }

        // ── Tools ──
        CommandMenu(L("Tools")) {
            ForEach(Self.tools, id: \.key) { entry in
                Toggle(
                    entry.title,
                    isOn: Binding(
                        get: {
                            MainActor.assumeIsolated {
                                ViewerCommands.shared.activeOverlay?.currentTool == entry.tool
                            }
                        },
                        set: { _ in
                            MainActor.assumeIsolated {
                                ViewerCommands.shared.activeOverlay?.currentTool = entry.tool
                            }
                        }
                    )
                )
                .keyboardShortcut(KeyEquivalent(entry.key), modifiers: .command)
                .disabled(ViewerCommands.shared.activeOverlay == nil)
            }
        }

        // ── Window ──
        // Re-open the docked main window after the user closed it.
        // "Tailscreen" is a brand noun, deliberately unlocalized.
        CommandGroup(before: .windowArrangement) {
            Button("Tailscreen") {
                appState.presentMainWindow()
            }
        }

        // ── Help ──
        // ⇧⌘/ — "/" is shift-slash on a US layout, so register "?" with
        // command and the system renders the shift.
        CommandGroup(replacing: .help) {
            Button(L("Keyboard Shortcuts")) {
                ViewerCommands.shared.toggleShortcutsOverlay(nil)
            }
            .keyboardShortcut("?", modifiers: .command)
            .disabled(
                !appState.sharingState.isLive
                    && appState.viewerWindow?.isVisible != true
                    && !appState.isShortcutsPanelVisible)
        }
    }

    private func postViewerZoom(_ factor: Double) {
        NotificationCenter.default.post(
            name: .tailscreenViewerSetZoom,
            object: nil,
            userInfo: ["factor": factor])
    }
}

/// The About panel, with version, description, project link, and copyright
/// — the standard panel without options is nearly blank in dev builds.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: options())
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
        // Only surface the build number when it differs, or "1.2.0 (1.2.0)"
        // is just noise.
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
