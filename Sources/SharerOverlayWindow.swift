import AppKit

/// Borderless transparent NSPanel that floats above the sharer's desktop at
/// `.statusBar` level, so ScreenCaptureKit (which captures the whole display
/// with no window exclusions — see `ScreenCapture.swift:41`) streams
/// annotations into the video for every viewer.
///
/// The panel is always full-screen. Toggling "Draw on Screen" shows/hides it
/// and also flips `ignoresMouseEvents` so clicks fall through when drawing is
/// off but the panel stays around (preserving existing strokes across toggles).
@MainActor
final class SharerOverlayWindow {
    /// Subclass of NSPanel that accepts key events even though it's borderless
    /// — required so keyDown reaches the DrawingOverlayView for tool shortcuts.
    private final class DrawingPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    let panel: NSPanel
    let overlay: DrawingOverlayView

    /// Fired by the overlay whenever the sharer draws / clears / undoes.
    /// AppState wires this to nothing (sharer's drawings appear in the video
    /// stream naturally) — we keep it here for symmetry with the viewer.
    var onOp: ((AnnotationOp) -> Void)? {
        get { overlay.onOp }
        set { overlay.onOp = newValue }
    }

    init() {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let panel = DrawingPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Accept mouse events even when our app isn't frontmost.
        panel.becomesKeyOnlyIfNeeded = false

        let overlay = DrawingOverlayView(frame: NSRect(origin: .zero, size: screenFrame.size))
        overlay.autoresizingMask = [.width, .height]
        overlay.isInputEnabled = false
        panel.contentView = overlay

        self.panel = panel
        self.overlay = overlay

        overlay.onEscape = { [weak self] in
            self?.setInputEnabled(false)
        }
    }

    /// Ensure the panel is on-screen. Idempotent.
    func show() {
        panel.orderFrontRegardless()
    }

    /// Tear the panel down (used on stop sharing).
    func hide() {
        panel.orderOut(nil)
    }

    /// Route the panel between "passive overlay" (renders remote drawings
    /// that SCStream can capture, but clicks pass through to real apps)
    /// and "active drawing" (the sharer can draw + use shortcuts).
    func setInputEnabled(_ enabled: Bool) {
        panel.ignoresMouseEvents = !enabled
        overlay.isInputEnabled = enabled
        if enabled {
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    func apply(remoteOp op: AnnotationOp) {
        overlay.apply(remoteOp: op)
    }
}
