import AppKit
import CoreGraphics

/// A thin border drawn around exactly the region being captured, for the
/// duration of a share.
///
/// It answers a question a status glyph cannot: not "a share is running
/// somewhere" but "**this** is what they can see." That distinction is the
/// whole value — a sharer who has moved a window, switched Spaces or
/// forgotten which display they picked learns the truth by looking at the
/// screen rather than by asking the app.
///
/// Two rules make it honest rather than decorative, and both are load-bearing:
///
/// 1. **It tracks the region, not the screen.** A window share outlines that
///    window and follows it; a display share outlines that display. An outline
///    that lags what is actually captured is a *lie* about what viewers can
///    see, which is worse than no outline at all. The tracking is shared with
///    `SharerOverlayWindow` (same statics, same miss-threshold) precisely so
///    the two cannot disagree about where the shared region is.
/// 2. **It is never captured itself.** `sharingType = .none` asks macOS to omit
///    this window from screen capture. Without it, a display share would draw a
///    border into the video and every viewer would see a frame around their own
///    view of your screen. See the caveat on `panel` below.
///
/// Deliberately a separate window from `SharerOverlayWindow` rather than a
/// border added to it. That panel is created *lazily* — only when the first
/// annotation arrives or "Draw on Screen" is toggled — so it does not exist for
/// an ordinary share, and in display mode it is deliberately **inside** the
/// capture region so the sharer's own strokes reach viewers. Both properties
/// are exactly wrong for an outline, which must exist for the whole share and
/// must stay out of the video.
@MainActor
final class CaptureOutlineWindow {
    /// Reuses `SharerOverlayWindow.Mode` rather than defining a parallel enum:
    /// both types answer "where is the shared region?" and the projection from
    /// a `PickerSelection` (`AppState.overlayMode(for:)`) is already written
    /// and tested once.
    typealias Mode = SharerOverlayWindow.Mode

    private let panel: NSPanel
    private let mode: Mode
    private var trackingTimer: Timer?
    private var screenChangeObserver: NSObjectProtocol?
    private var consecutiveMisses = 0

    /// Matches `SharerOverlayWindow.missThreshold`'s reasoning: at 20 Hz this
    /// is ~150 ms, long enough to ride out a Mission Control transition and
    /// short enough that a real Space switch hides the outline before anyone
    /// notices it floating over nothing.
    private static let missThreshold = 3

    /// Border thickness in points. Thin enough not to obscure content at the
    /// edges, thick enough to read as deliberate rather than as a rendering
    /// artifact.
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
        // Above `SharerOverlayWindow`'s `.statusBar` so the outline is never
        // hidden under the annotation canvas, and so it survives a full-screen
        // app — a share does not stop when the sharer goes full-screen, so
        // neither should the sign that one is running.
        panel.level = .screenSaver
        // A capture indicator that can swallow a click would be a bug in its
        // own right: it covers the entire shared region.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        // **The rule that keeps the outline out of the video.** Without this a
        // display share captures the border and every viewer sees a frame
        // around their own view. Needs a first-run visual check on a real
        // desktop: if ScreenCaptureKit ever stops honouring `sharingType`, the
        // fallback is to pass this window's `CGWindowID` down to the capture
        // helper and add it to `SCContentFilter`'s excluded set.
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
        // Display and application shares are static — the panel already covers
        // the display and only a display-configuration change moves it, which
        // the observer below handles.
        guard case .window = mode else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            // Added to `RunLoop.main`, so this fires on the main thread;
            // `assumeIsolated` skips a per-tick Task allocation.
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
            // The shared window is off the current Space (or gone). Hiding
            // rather than freezing matters: an outline left behind on an empty
            // patch of desktop claims a boundary that is not there.
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

    /// Strokes the border inset by half the line width, so the whole stroke
    /// lands *inside* the panel. Stroking on the bounds edge would clip the
    /// outer half and render as a 2pt line that looks like a mistake.
    private final class OutlineView: NSView {
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let inset = CaptureOutlineWindow.lineWidth / 2
            let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
            path.lineWidth = CaptureOutlineWindow.lineWidth
            // `systemRed` rather than a fixed colour: it is the platform's own
            // "recording" signal, it adapts to Increase Contrast, and it does
            // not collide with the annotation palette, which is what a viewer's
            // strokes are drawn in.
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }
}
