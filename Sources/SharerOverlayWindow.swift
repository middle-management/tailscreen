import AppKit
import CoreGraphics

/// Borderless transparent NSPanel that floats above the sharer's desktop at
/// `.statusBar` level. Used as a render surface for viewer-drawn strokes
/// pinned to the shared region, and — in display mode only — as the canvas
/// SCStream picks up so the sharer's own strokes flow into the video for
/// every viewer. (In window / application modes the panel sits on top of
/// the captured surface, not inside it, so sharer strokes are local-only
/// until a server-side annotation fan-out is wired up. Viewer-originated
/// strokes still render correctly for the sharer.)
///
/// The panel's footprint depends on what was shared:
///   * ``Mode/display`` — full screen on the captured display, joins every
///     Space (matches the SCStream's "everything on this display" capture).
///   * ``Mode/window`` — tracks the chosen window, follows its position and
///     size, hides when the window isn't on the current Space.
///   * ``Mode/application`` — full screen on the captured display (SCStream
///     in application mode captures the whole display filtered to those
///     apps, so viewer-sent normalized coords map onto the display rect,
///     not the union of app-window rects).
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
        case application(displayID: CGDirectDisplayID?)
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
    /// Polling timer for window mode. Nil for display / application modes
    /// (panel is statically sized to the captured display).
    private var trackingTimer: Timer?
    /// Notification observer token for display hot-plug / resolution change.
    /// Released in `hide()`.
    private var screenChangeObserver: NSObjectProtocol?
    /// Consecutive ticks the tracked window has been missing from
    /// CGWindowList's on-screen set. Used to debounce brief occlusion
    /// (Mission Control, app switching) so the panel doesn't flicker.
    private var consecutiveMisses: Int = 0
    /// Threshold of misses before we hide the panel. At 20 Hz this is
    /// ~150 ms — long enough to ride out Mission Control transitions,
    /// short enough that a real Space switch hides the panel before the
    /// user notices it lingering.
    private static let missThreshold: Int = 3

    /// Fired by the overlay whenever the sharer draws / clears / undoes.
    /// In display mode the sharer's strokes also flow into the captured
    /// video naturally because the panel is in SCStream's capture region,
    /// so AppState typically wires this to a no-op there. In window /
    /// application modes the panel is on top of (not inside) the captured
    /// surface, so reaching other viewers needs a server-side fan-out
    /// hooked up to this callback.
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
        case .display, .application:
            // Cover every Space on the captured display — SCStream picks up
            // the panel wherever the user is (display mode), and in
            // application mode the captured surface is still the whole
            // display filtered to those apps, so the overlay matches.
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        case .window:
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

    /// Ensure the panel is on-screen. Idempotent. Starts the window
    /// tracking loop on first call (window mode only); subsequent calls
    /// are no-ops on the loop. Also subscribes to display-configuration
    /// changes so the panel resizes if the user re-scales / hot-plugs.
    func show() {
        updateTrackedFrame()
        panel.orderFrontRegardless()
        startTrackingIfNeeded()
        subscribeToScreenChangesIfNeeded()
    }

    /// Tear the panel down (used on stop sharing). Stops the tracking loop
    /// and releases the screen-change observer — leaving them around after
    /// the panel is gone would leak a timer / observer holding `self`.
    func hide() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        if let token = screenChangeObserver {
            NotificationCenter.default.removeObserver(token)
            screenChangeObserver = nil
        }
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

    /// Best-guess frame for the overlay at construction time. Display and
    /// application modes are static (sized to the captured display); window
    /// mode refines on each tracking tick.
    private static func initialFrame(for mode: Mode) -> NSRect {
        switch mode {
        case .display(let displayID), .application(let displayID):
            let screen = Self.screen(forDisplayID: displayID) ?? NSScreen.main
            return screen?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        case .window(let windowID):
            if let cg = cgWindowFrame(for: windowID), let cocoa = cgToCocoaFrame(cg) {
                return cocoa
            }
            return NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        }
    }

    /// Window mode runs a 20 Hz polling loop so the panel follows the
    /// shared window through moves / resizes / Space switches. Polling
    /// is simple and bounded — Accessibility observers and NSWorkspace
    /// notifications either need extra entitlements or miss live-drag
    /// updates. Display and application modes are static.
    private func startTrackingIfNeeded() {
        guard trackingTimer == nil else { return }
        switch mode {
        case .display, .application:
            return
        case .window:
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                // Timer was added to `RunLoop.main`, so this fires on the
                // main thread — `assumeIsolated` skips the Task hop that
                // would otherwise allocate per tick and defer the update
                // by one run-loop iteration.
                MainActor.assumeIsolated {
                    self?.updateTrackedFrame()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            trackingTimer = t
        }
    }

    /// Subscribe to display-configuration changes so the static panel
    /// modes (display / application) resize on resolution change or
    /// display hot-plug. Window mode picks the change up on the next
    /// polling tick.
    private func subscribeToScreenChangesIfNeeded() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenParametersChanged()
            }
        }
    }

    /// On display config change, re-derive the static frame for display /
    /// application modes. Window mode re-fits naturally on the next tick.
    private func handleScreenParametersChanged() {
        switch mode {
        case .display, .application:
            let frame = Self.initialFrame(for: mode)
            if panel.frame != frame {
                panel.setFrame(frame, display: false, animate: false)
            }
        case .window:
            updateTrackedFrame()
        }
    }

    /// Refresh the panel frame to match the currently shared window. Hides
    /// the panel after `missThreshold` consecutive ticks where the window
    /// isn't on the current Space — CGWindowList's on-screen-only filter
    /// only returns windows the user can actually see right now, and brief
    /// transitions (Mission Control, app switching) can drop the window
    /// for a frame or two without it actually being gone.
    private func updateTrackedFrame() {
        let target: CGRect?
        switch mode {
        case .display, .application:
            return
        case .window(let id):
            target = Self.cgWindowFrame(for: id)
        }
        guard let cgRect = target, let cocoa = Self.cgToCocoaFrame(cgRect),
            cocoa.width > 0, cocoa.height > 0
        else {
            consecutiveMisses += 1
            if consecutiveMisses >= Self.missThreshold, panel.isVisible {
                panel.orderOut(nil)
            }
            return
        }
        consecutiveMisses = 0
        if panel.frame != cocoa {
            panel.setFrame(cocoa, display: false, animate: false)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Frame (Quartz coordinates, top-left origin on the primary display) of
    /// the window with the given ID, or nil if it isn't currently on-screen.
    /// `optionIncludingWindow` already filters to just this ID, so no extra
    /// match-by-number scan is needed.
    private static func cgWindowFrame(for windowID: CGWindowID) -> CGRect? {
        let options: CGWindowListOption = [.optionIncludingWindow, .optionOnScreenOnly]
        guard
            let infos = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
            let info = infos.first,
            let dict = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
        else { return nil }
        return bounds
    }

    /// Translate a CGWindowList rectangle (top-left origin on the primary
    /// display) into Cocoa global coordinates (bottom-left origin on the
    /// primary display) so the result is directly usable as an NSWindow
    /// frame. The "primary" display per AppKit's coordinate system is the
    /// one whose frame origin is (0, 0) — not necessarily `screens.first`,
    /// which is just whatever the order returned by IOKit happens to be.
    private static func cgToCocoaFrame(_ cgRect: CGRect) -> NSRect? {
        let primary =
            NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.screens.first
        guard let primary else { return nil }
        let primaryHeight = primary.frame.height
        return NSRect(
            x: cgRect.origin.x,
            y: primaryHeight - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
    }
}
