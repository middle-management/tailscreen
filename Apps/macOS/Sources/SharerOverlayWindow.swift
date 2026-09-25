import AppKit
import CoreGraphics

/// Borderless transparent NSPanel floating at `.statusBar` level: a render
/// surface for viewer-drawn strokes, and — in display mode only — the canvas
/// SCStream picks up so the sharer's own strokes flow into the video. In
/// window/application modes the panel sits on top of the captured surface,
/// not inside it, so sharer strokes stay local-only until a server-side fan-out.
///
/// Footprint depends on what was shared:
///   * ``Mode/display`` — full screen, joins every Space.
///   * ``Mode/window`` — tracks the window's position/size, hides off-Space.
///   * ``Mode/application`` — full display (SCStream captures the whole
///     display filtered to those apps), not the union of app-window rects.
///
/// Toggling "Draw on Screen" flips `ignoresMouseEvents` so clicks pass
/// through when drawing is off, preserving existing strokes.
@MainActor
final class SharerOverlayWindow {
    enum Mode {
        case display(CGDirectDisplayID?)
        case window(CGWindowID)
        case application(displayID: CGDirectDisplayID?)
    }

    /// Accepts key events despite being borderless, so keyDown reaches the
    /// overlay host for tool shortcuts.
    private final class DrawingPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    let panel: NSPanel
    let model: AnnotationCanvasModel
    private let host: AnnotationOverlayHostView
    private let mode: Mode
    /// Nil for display/application modes (statically sized).
    private var trackingTimer: Timer?
    /// Released in `hide()`.
    private var screenChangeObserver: NSObjectProtocol?
    /// Debounces brief occlusion (Mission Control, app switching) so the
    /// panel doesn't flicker.
    private var consecutiveMisses: Int = 0
    /// At 20Hz, ~150ms: rides out Mission Control but hides before a real
    /// Space switch is noticed.
    private static let missThreshold: Int = 3

    /// In display mode the sharer's strokes flow into the video naturally, so
    /// this is typically a no-op there; in window/application modes, reaching
    /// other viewers needs a server-side fan-out hooked to this callback.
    var onOp: ((AnnotationOp) -> Void)? {
        get { model.onOp }
        set { model.onOp = newValue }
    }

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
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        case .window:
            // Single-Space; the tracking loop hides/re-shows as the shared
            // window's Space changes.
            panel.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        }
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false  // accept events even when not frontmost

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

    /// Idempotent.
    func show() {
        updateTrackedFrame()
        panel.orderFrontRegardless()
        startTrackingIfNeeded()
        subscribeToScreenChangesIfNeeded()
    }

    /// Releases the timer/observer — leaving them would leak, holding `self`.
    func hide() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        if let token = screenChangeObserver {
            NotificationCenter.default.removeObserver(token)
            screenChangeObserver = nil
        }
        panel.orderOut(nil)
    }

    /// "Passive overlay" (clicks pass through) vs. "active drawing".
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

    /// Same algorithm as `TailscaleScreenShareClient.localIdentity()`;
    /// hostname + `TAILSCREEN_INSTANCE` makes two local processes pick
    /// different colors.
    static func localIdentity() -> String {
        let host = Host.current().localizedName ?? "tailscreen"
        return "\(host)\(TailscreenInstance.hostnameSuffix)"
    }

    static func screen(forDisplayID displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return number == displayID
        }
    }

    /// Display/application modes are static; window mode refines on each tick.
    static func initialFrame(for mode: Mode) -> NSRect {
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

    /// Polling, not Accessibility observers/NSWorkspace notifications, which
    /// either need extra entitlements or miss live-drag updates.
    private func startTrackingIfNeeded() {
        guard trackingTimer == nil else { return }
        switch mode {
        case .display, .application:
            return
        case .window:
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                // Runs on the main thread (RunLoop.main); assumeIsolated
                // skips a per-tick Task hop.
                MainActor.assumeIsolated {
                    self?.updateTrackedFrame()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            trackingTimer = t
        }
    }

    /// Window mode picks the change up on the next polling tick instead.
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

    /// `kCGWindowListOptionIncludingWindow` alone returns the full on-screen
    /// list (well-defined only paired with `OnScreenAboveWindow`/`BelowWindow`),
    /// so filtering by `kCGWindowNumber` is the reliable path.
    static func cgWindowFrame(for windowID: CGWindowID) -> CGRect? {
        let options: CGWindowListOption = .optionOnScreenOnly
        guard
            let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]],
            let info = infos.first(where: {
                ($0[kCGWindowNumber as String] as? UInt32) == windowID
            }),
            let dict = info[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
        else { return nil }
        return bounds
    }

    /// "Primary" is the display whose frame origin is (0, 0), not necessarily
    /// `screens.first` (IOKit's return order).
    static func cgToCocoaFrame(_ cgRect: CGRect) -> NSRect? {
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
