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
    /// — required so keyDown reaches the overlay host for tool shortcuts.
    private final class DrawingPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    let panel: NSPanel
    let model: AnnotationCanvasModel
    private let host: AnnotationOverlayHostView

    /// Fired by the overlay whenever the sharer draws / clears / undoes.
    /// AppState wires this to nothing (sharer's drawings appear in the video
    /// stream naturally) — we keep it here for symmetry with the viewer.
    var onOp: ((AnnotationOp) -> Void)? {
        get { model.onOp }
        set { model.onOp = newValue }
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

        let model = AnnotationCanvasModel()
        model.isInputEnabled = false
        model.currentColor = Annotation.RGBA.paletteColor(forIdentity: Self.localIdentity())

        let host = AnnotationOverlayHostView(model: model)
        host.frame = NSRect(origin: .zero, size: screenFrame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        self.panel = panel
        self.model = model
        self.host = host

        model.onEscape = { [weak self] in
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
}
