import AppKit
import CoreGraphics

/// A thin border drawn around exactly the region being captured, for the
/// duration of a share — shows the sharer *what viewers can see*, tracking a
/// moved window or a Space switch rather than a static status glyph.
///
/// Two load-bearing rules:
/// 1. **Tracks the region, not the screen** — shares tracking statics/miss-
///    threshold with `SharerOverlayWindow` so the two can't disagree.
/// 2. **Never captured itself**: `sharingType = .none`, or a display share
///    would draw the border into the video for every viewer.
///
/// A separate window from `SharerOverlayWindow`, which is created lazily and
/// sits *inside* the capture region (so strokes reach viewers) — both wrong
/// for an outline, which must exist for the whole share and stay out of the video.
@MainActor
final class CaptureOutlineWindow {
    /// Reuses `SharerOverlayWindow.Mode` rather than a parallel enum — both
    /// answer "where is the shared region?"
    typealias Mode = SharerOverlayWindow.Mode

    private let panel: NSPanel
    private let mode: Mode
    private var trackingTimer: Timer?
    private var screenChangeObserver: NSObjectProtocol?
    private var consecutiveMisses = 0

    /// At 20Hz, ~150ms: rides out a Mission Control transition but hides the
    /// outline before a real Space switch looks like a bug.
    private static let missThreshold = 3

    private static let lineWidth: CGFloat = 4

    init(mode: Mode) {
        self.mode = mode
        let frame = SharerOverlayWindow.initialFrame(for: mode)

        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above SharerOverlayWindow's .statusBar, and survives full-screen apps.
        panel.level = .screenSaver
        // Covers the entire shared region, so it must not swallow clicks.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        // Keeps the outline out of the video — without this, a display share
        // captures its own border. If ScreenCaptureKit stops honoring
        // `sharingType`, fall back to excluding this window's CGWindowID via
        // SCContentFilter instead.
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = OutlineView()
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
    }

    func show() {
        updateTrackedFrame()
        panel.orderFrontRegardless()
        startTrackingIfNeeded()
        subscribeToScreenChangesIfNeeded()
    }

    func hide() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        if let token = screenChangeObserver {
            NotificationCenter.default.removeObserver(token)
            screenChangeObserver = nil
        }
        panel.orderOut(nil)
    }

    // MARK: - Tracking

    private func startTrackingIfNeeded() {
        guard trackingTimer == nil else { return }
        // Display/application shares are static; only a display-config change
        // moves them, handled by the observer below.
        guard case .window = mode else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            // Runs on the main thread (added to RunLoop.main); assumeIsolated
            // skips a per-tick Task allocation.
            MainActor.assumeIsolated { self?.updateTrackedFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func subscribeToScreenChangesIfNeeded() {
        guard screenChangeObserver == nil else { return }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenParametersChanged() }
        }
    }

    private func handleScreenParametersChanged() {
        switch mode {
        case .display, .application:
            let frame = SharerOverlayWindow.initialFrame(for: mode)
            if panel.frame != frame {
                panel.setFrame(frame, display: true, animate: false)
            }
        case .window:
            updateTrackedFrame()
        }
    }

    private func updateTrackedFrame() {
        guard case .window(let id) = mode else { return }
        guard let cgRect = SharerOverlayWindow.cgWindowFrame(for: id),
            let cocoa = SharerOverlayWindow.cgToCocoaFrame(cgRect),
            cocoa.width > 0, cocoa.height > 0
        else {
            consecutiveMisses += 1
            // Hide rather than freeze: a stale outline claims a boundary that
            // isn't there once the window is off-Space or gone.
            if consecutiveMisses >= Self.missThreshold, panel.isVisible {
                panel.orderOut(nil)
            }
            return
        }
        consecutiveMisses = 0
        if panel.frame != cocoa {
            panel.setFrame(cocoa, display: true, animate: false)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Drawing

    /// Insets the stroke by half the line width so it lands inside the panel
    /// rather than clipping at the bounds edge.
    ///
    /// **No `isFlipped` override.** The inset rect from `bounds` is identical
    /// either way up, so the override changed nothing on screen while costing
    /// a real crash: `isFlipped` is an `@objc` member on a `@MainActor` type,
    /// and AppKit's hit-test machinery calls it on every mouse move over this
    /// screenSaver-level panel covering the whole shared region — a wild
    /// pointer there caused a SIGBUS (v0.10.0-rc.12). Before adding another
    /// `@objc` override here, check whether AppKit calls it from a geometry
    /// path; `nonisolated` is the escape hatch when genuinely needed (see
    /// `RemoteControlInputView`).
    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let inset = CaptureOutlineWindow.lineWidth / 2
            let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
            path.lineWidth = CaptureOutlineWindow.lineWidth
            // Platform's own "recording" signal; adapts to Increase Contrast
            // and doesn't collide with the annotation palette.
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }
}
