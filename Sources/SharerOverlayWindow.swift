import AppKit
import CoreGraphics

/// Borderless transparent NSPanel that floats above the sharer's desktop at
/// `.statusBar` level, so ScreenCaptureKit can stream annotations into the
/// video for every viewer (display mode) and so the sharer sees viewer-drawn
/// strokes pinned to the shared content (window / application modes).
///
/// The panel's footprint depends on what was shared:
///   * ``Mode/display`` — full screen on the captured display, joins every
///     Space (matches the SCStream's "everything on this display" capture).
///   * ``Mode/window`` — tracks the chosen window, follows its position and
///     size, hides when the window isn't on the current Space.
///   * ``Mode/application`` — tracks the union of on-screen windows that
///     belong to the picked bundle IDs, hides when none are visible.
///
/// Toggling "Draw on Screen" shows/hides it and flips `ignoresMouseEvents` so
/// clicks fall through when drawing is off but the panel stays around
/// (preserving existing strokes across toggles).
@MainActor
final class SharerOverlayWindow {
    /// What the sharer picked in `SCContentSharingPicker`, distilled down to
    /// what the overlay needs to know to size and position itself.
    enum Mode {
        case display(CGDirectDisplayID?)
        case window(CGWindowID)
        case application(bundleIDs: [String], displayID: CGDirectDisplayID?)
    }

    /// Subclass of NSPanel that accepts key events even though it's borderless
    /// — required so keyDown reaches the overlay host for tool shortcuts.
    private final class DrawingPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    let panel: NSPanel
    let model: AnnotationCanvasModel
    private let host: AnnotationOverlayHostView
    private let mode: Mode
    /// Polling timer for window/app modes. Nil in display mode (no tracking
    /// needed — the panel is statically full-screen).
    private var trackingTimer: Timer?

    /// Fired by the overlay whenever the sharer draws / clears / undoes.
    /// AppState wires this to nothing (sharer's drawings appear in the video
    /// stream naturally in display mode) — we keep it here for symmetry with
    /// the viewer.
    var onOp: ((AnnotationOp) -> Void)? {
        get { model.onOp }
        set { model.onOp = newValue }
    }

    /// `mode` selects what the overlay covers — full display, a specific
    /// window, or the union of one or more apps' windows. The initial frame
    /// is the best guess at construction time; for window/app modes it then
    /// updates via a polling timer (started in `show()`).
    init(mode: Mode = .display(nil)) {
        self.mode = mode
        let initialFrame = Self.initialFrame(for: mode)

        let panel = DrawingPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        switch mode {
        case .display:
            // Cover every Space on the captured display — SCStream picks up
            // the panel wherever the user is, so annotations land in the
            // video regardless of which Space is foregrounded.
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        case .window, .application:
            // Single-Space — the tracking loop hides the panel when the
            // shared window isn't on the user's current Space and re-shows
            // it when they switch back.
            panel.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        }
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Accept mouse events even when our app isn't frontmost.
        panel.becomesKeyOnlyIfNeeded = false

        let model = AnnotationCanvasModel()
        model.isInputEnabled = false
        model.currentColor = Annotation.RGBA.paletteColor(forIdentity: Self.localIdentity())

        let host = AnnotationOverlayHostView(model: model)
        host.frame = NSRect(origin: .zero, size: initialFrame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        self.panel = panel
        self.model = model
        self.host = host

        model.onEscape = { [weak self] in
            self?.setInputEnabled(false)
        }
    }

    /// Ensure the panel is on-screen. Idempotent. Starts the window/app
    /// tracking loop on first call; subsequent calls are no-ops on the loop.
    func show() {
        updateTrackedFrame()
        panel.orderFrontRegardless()
        startTrackingIfNeeded()
    }

    /// Tear the panel down (used on stop sharing). Stops the tracking loop
    /// too — leaving it running after the panel is gone would leak a timer
    /// holding `self`.
    func hide() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        panel.orderOut(nil)
    }

    /// Route the panel between "passive overlay" (renders remote drawings
    /// that SCStream can capture, but clicks pass through to real apps)
    /// and "active drawing" (the sharer can draw + use shortcuts).
    func setInputEnabled(_ enabled: Bool) {
        panel.ignoresMouseEvents = !enabled
        model.isInputEnabled = enabled
        if enabled {
            panel.orderFrontRegardless()
            panel.makeKey()
            panel.makeFirstResponder(host)
            ViewerCommands.shared.activeOverlay = model
        } else if ViewerCommands.shared.activeOverlay === model {
            ViewerCommands.shared.activeOverlay = nil
        }
    }

    func apply(remoteOp op: AnnotationOp) {
        model.apply(remoteOp: op)
    }

    /// Stable identity string used to derive this participant's drawing
    /// color. Same algorithm as TailscaleScreenShareClient.localIdentity()
    /// — combining hostname + TAILSCREEN_INSTANCE makes two local processes
    /// on the same Mac pick *different* colors (they have different instance
    /// suffixes), while two real machines pick whatever their hostnames
    /// hash to.
    static func localIdentity() -> String {
        let host = Host.current().localizedName ?? "tailscreen"
        return "\(host)\(TailscreenInstance.hostnameSuffix)"
    }

    /// Map a `CGDirectDisplayID` to the matching `NSScreen` via
    /// `NSScreenNumber` in the device description. Returns nil when the ID
    /// is nil or no attached screen reports it.
    private static func screen(forDisplayID displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return number == displayID
        }
    }

    /// Best-guess frame for the overlay at construction time, before the
    /// tracking loop has had a chance to refine it. Display mode is static;
    /// window/app modes refine on the first `show()` tick.
    private static func initialFrame(for mode: Mode) -> NSRect {
        switch mode {
        case .display(let displayID):
            let screen = Self.screen(forDisplayID: displayID) ?? NSScreen.main
            return screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        case .window(let windowID):
            if let cg = cgWindowFrame(for: windowID), let cocoa = cgToCocoaFrame(cg) {
                return cocoa
            }
            return NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        case .application(let bundleIDs, let displayID):
            if let cg = appWindowsUnionCGFrame(bundleIDs: bundleIDs),
                let cocoa = cgToCocoaFrame(cg) {
                return cocoa
            }
            let screen = Self.screen(forDisplayID: displayID) ?? NSScreen.main
            return screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        }
    }

    /// In display mode the panel is static; in window/app modes a 20 Hz
    /// polling loop keeps the panel pinned to the shared content as the user
    /// moves / resizes it. Polling is simple and bounded — alternatives
    /// (Accessibility observers, NSWorkspace notifications) need extra
    /// entitlements or miss live drag updates.
    private func startTrackingIfNeeded() {
        guard trackingTimer == nil else { return }
        switch mode {
        case .display:
            return
        case .window, .application:
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateTrackedFrame()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            trackingTimer = t
        }
    }

    /// Refresh the panel frame to match the currently shared window/app.
    /// Hides the panel if the tracked content isn't on the current Space —
    /// CGWindowList's on-screen-only filter only returns windows the user
    /// can actually see right now.
    private func updateTrackedFrame() {
        let target: CGRect?
        switch mode {
        case .display:
            return
        case .window(let id):
            target = Self.cgWindowFrame(for: id)
        case .application(let bundleIDs, _):
            target = Self.appWindowsUnionCGFrame(bundleIDs: bundleIDs)
        }
        guard let cgRect = target, let cocoa = Self.cgToCocoaFrame(cgRect),
            cocoa.width > 0, cocoa.height > 0
        else {
            if panel.isVisible {
                panel.orderOut(nil)
            }
            return
        }
        if panel.frame != cocoa {
            panel.setFrame(cocoa, display: false, animate: false)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Frame (Quartz coordinates, top-left origin on the primary display) of
    /// the window with the given ID, or nil if it isn't currently on-screen.
    private static func cgWindowFrame(for windowID: CGWindowID) -> CGRect? {
        let options: CGWindowListOption = [.optionIncludingWindow, .optionOnScreenOnly]
        guard
            let infos = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
            let info = infos.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }),
            let dict = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
        else { return nil }
        return bounds
    }

    /// Union of bounds for every on-screen window belonging to one of
    /// `bundleIDs`. Layer-0 windows only — skips menubar / dock / status-item
    /// surfaces so the overlay doesn't end up oversized when the user has a
    /// taskbar app in the share set.
    private static func appWindowsUnionCGFrame(bundleIDs: [String]) -> CGRect? {
        guard !bundleIDs.isEmpty else { return nil }
        let bundleSet = Set(bundleIDs)
        let pidToBundle: [pid_t: String] = NSWorkspace.shared.runningApplications.reduce(into: [:]) { acc, app in
            if let b = app.bundleIdentifier {
                acc[app.processIdentifier] = b
            }
        }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var union: CGRect?
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let pidRaw = info[kCGWindowOwnerPID as String] as? Int32,
                let bundle = pidToBundle[pid_t(pidRaw)],
                bundleSet.contains(bundle),
                let dict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                bounds.width > 0, bounds.height > 0
            else { continue }
            union = union?.union(bounds) ?? bounds
        }
        return union
    }

    /// Translate a CGWindowList rectangle (top-left origin on the primary
    /// display) into Cocoa global coordinates (bottom-left origin on the
    /// primary display) so the result is directly usable as an NSWindow
    /// frame.
    private static func cgToCocoaFrame(_ cgRect: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryHeight = primary.frame.height
        return NSRect(
            x: cgRect.origin.x,
            y: primaryHeight - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
    }
}
