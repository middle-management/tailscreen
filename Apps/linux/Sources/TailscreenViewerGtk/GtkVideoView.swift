import CGtkVideo
import Foundation
import Gtk
import GtkBackend
import SwiftCrossUI
import TailscreenProtocol
import TailscreenViewer
import TailscreenViewerCore

/// A video surface implemented as a *downstream* swift-cross-ui `View` — no
/// fork. It conforms to the public `View` protocol directly (the tidy
/// `ElementaryView` helper is internal to swift-cross-ui), downcasts the generic
/// backend to the concrete `GtkBackend`, constructs a real `Gtk.GLArea`, and
/// draws the latest `FrameStore` frame with an OpenGL YUV→RGB shader
/// (`CGtkVideo`). Proven end-to-end (correct pixels via `glReadPixels`) — see
/// plans/linux-viewer-gtk-plan.md.
///
/// When `onInputEvent` is supplied it also captures opt-in remote-control input:
/// pointer motion, three mouse buttons, and keyboard, translated to neutral
/// ``InputEvent``s via `ViewerInputMapping` (the pure, unit-tested Core mapper).
///
/// It also drives continuous content zoom/pan (independent of remote control):
/// scroll zooms about the cursor, Shift+scroll pans while zoomed, and a
/// double-click toggles smart-magnify — all geometry via the CI-tested pure
/// `ViewerZoomMath`. Scroll capture goes through the `CGtkVideo` C shim
/// (`cgtkvideo_attach_scroll`) because swift-cross-ui exposes no
/// `EventControllerScroll` binding; scroll only zooms/pans the local view and is
/// never forwarded as remote input.
public struct GtkVideoView: View {
    let store: FrameStore
    let selfTest: Bool
    let onInputEvent: ((InputEvent) -> Void)?
    let annotations: AnnotationStore?
    /// Height of sibling chrome (e.g. the annotation toolbar row) stacked above
    /// this view. Added to the window size requested on the first frame so the
    /// chrome doesn't eat into the video's area.
    let chromeHeight: Int

    public init(
        store: FrameStore,
        selfTest: Bool = false,
        onInputEvent: ((InputEvent) -> Void)? = nil,
        annotations: AnnotationStore? = nil,
        chromeHeight: Int = 0
    ) {
        self.store = store
        self.selfTest = selfTest
        self.onInputEvent = onInputEvent
        self.annotations = annotations
        self.chromeHeight = chromeHeight
    }

    public var body: some View { EmptyView() }

    public func children<Backend: BaseAppBackend>(
        backend: Backend,
        snapshots: [ViewGraphSnapshotter.NodeSnapshot]?,
        environment: EnvironmentValues
    ) -> any ViewGraphNodeChildren {
        EmptyViewChildren()
    }

    public func layoutableChildren<Backend: BaseAppBackend>(
        backend: Backend,
        children: any ViewGraphNodeChildren
    ) -> [LayoutSystem.LayoutableChild] {
        []
    }

    public func asWidget<Backend: BaseAppBackend>(
        _ children: any ViewGraphNodeChildren,
        backend: Backend
    ) -> Backend.Widget {
        guard backend is GtkBackend else {
            // Other backends (WinUI, AppKit) would provide their own native
            // video widget; only the GTK path is wired here.
            return backend.createContainer()
        }
        let area = Gtk.GLArea()
        // Fill the window: without this the GLArea collapses to its (zero)
        // natural size and a sibling (the control bar) drives the window width.
        // The GL shader letterboxes the frame to the allotted rectangle.
        area.expandHorizontally = true
        area.expandVertically = true
        let store = self.store
        let selfTest = self.selfTest
        let annotations = self.annotations
        let chromeHeight = self.chromeHeight
        // One-shot: grow the (hub-sized) window to the video on the first frame.
        let sizedToVideo = ResizeLatch()
        // Repaint when a stroke is drawn or a relayed op arrives.
        annotations?.setRedraw { [weak area] in
            guard let area else { return }
            cgtkvideo_queue_render(UnsafeMutableRawPointer(area.widgetPointer))
        }
        // Shared continuous zoom/pan state (scroll-zoom, drag-free pan, and the
        // double-tap smart-magnify toggle). One instance is captured by both the
        // render closure — which resets the view on a resolution change — and the
        // input closures. All of them run on the GTK main thread, so the plain
        // reference needs no locking.
        let zoom = ViewZoom()
        // GL object names are per-context; if the area's context is torn down
        // and recreated (unrealize→realize, reparent), re-init on the next draw.
        area.createContext = { _ in cgtkvideo_reset() }
        // Let the video sink request repaints as frames arrive. Captured weakly
        // so the store doesn't keep the area alive past the widget tree.
        store.setRedraw { [weak area] in
            guard let area else { return }
            cgtkvideo_queue_render(UnsafeMutableRawPointer(area.widgetPointer))
        }
        area.render = { _, _ in
            // `frame` is a value-type copy with COW plane storage, so these
            // buffer pointers stay valid even if an off-thread `present()`
            // overwrites the store mid-draw. This safety depends on
            // `DecodedVideoFrame` remaining a value type.
            if let frame = store.current() {
                // First real frame: grow the hub-sized window to the video's
                // dimensions (aspect-preserved, capped), so a share opens at a
                // sensible size instead of the narrow picker window. Not in the
                // self-test (it renders synthetic bars and exits).
                if !selfTest, !sizedToVideo.done {
                    sizedToVideo.done = true
                    let (w, h) = Self.windowSize(forVideoWidth: frame.width, height: frame.height)
                    cgtkvideo_resize_toplevel(
                        UnsafeMutableRawPointer(area.widgetPointer), Int32(w), Int32(h + chromeHeight))
                }
                // A new video size (resolution change) invalidates the current
                // zoom/pan — its offset was clamped against the old fit rect — so
                // snap back to plain aspect-fit. Never in self-test (no input
                // attached; its transform stays the default 1/0/0).
                if !selfTest, zoom.resetIfVideoSizeChanged(width: frame.width, height: frame.height) {
                    cgtkvideo_set_view(1, 0, 0)
                }
                frame.yPlane.withUnsafeBufferPointer { yb in
                    frame.uPlane.withUnsafeBufferPointer { ub in
                        frame.vPlane.withUnsafeBufferPointer { vb in
                            cgtkvideo_draw_yuv(
                                Int32(frame.width), Int32(frame.height),
                                yb.baseAddress, ub.baseAddress, vb.baseAddress,
                                frame.colorInfo.range == .full ? 1 : 0)
                        }
                    }
                }
                // Overlay annotation strokes (mapped through the same transform).
                if let annotations {
                    // Ephemeral strokes (`.click` markers) age out on a clock,
                    // and this is the only place that ticks once the ops stop
                    // arriving — a lone click marker with no traffic behind it
                    // would otherwise stay on the canvas for the whole share.
                    // Swept BEFORE the draw so this pass already reflects it;
                    // `expire` deliberately queues no repaint of its own.
                    annotations.expire()
                    let data = annotations.renderData(
                        aspect: Double(frame.width) / Double(max(1, frame.height)),
                        renderHeight: Double(frame.height))
                    if !data.counts.isEmpty {
                        data.xy.withUnsafeBufferPointer { xy in
                            data.counts.withUnsafeBufferPointer { counts in
                                data.rgba.withUnsafeBufferPointer { rgba in
                                    data.widths.withUnsafeBufferPointer { widths in
                                        cgtkvideo_draw_annotations(
                                            xy.baseAddress, counts.baseAddress,
                                            Int32(data.counts.count),
                                            rgba.baseAddress, widths.baseAddress)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                cgtkvideo_clear()
            }
            if selfTest {
                exit(cgtkvideo_selftest_check() == 1 ? 0 : 3)
            }
        }
        if let onInputEvent {
            Self.attachInputCapture(to: area, store: store, emit: onInputEvent)
        }
        // Zoom/pan is a view-transform concern independent of remote-control input
        // capture, and must be a no-op in the headless render self-test.
        if !selfTest {
            Self.attachZoomPan(to: area, store: store, zoom: zoom)
        }
        if let annotations, !selfTest {
            Self.attachAnnotationDrawing(to: area, store: store, annotations: annotations)
        }
        // GtkGLArea is a Gtk.Widget; GtkBackend.Widget == Gtk.Widget, so this
        // runtime cast is safe whenever `backend is GtkBackend`.
        return (area as Any) as! Backend.Widget
    }

    /// Holds the current modifier-key state so pointer events — whose GTK
    /// signals carry no modifier snapshot — can be tagged with the live
    /// modifiers. Updated from the key controller's `modifiers` signal and from
    /// every key event's state. A reference type so all the event closures share
    /// one instance (retained for the widget's lifetime via its controllers).
    private final class ModifierState {
        var modifiers: KeyModifiers = []
    }

    /// One-shot latch so the window is grown to the video size exactly once (the
    /// render callback fires every frame).
    private final class ResizeLatch {
        var done = false
    }

    /// Tracks whether an annotation drag is in progress (button held).
    private final class DrawState {
        var drawing = false
    }

    /// Attach freehand annotation drawing: a button-1 press in pen mode starts a
    /// stroke, pointer motion extends it, release commits it (relayed via the
    /// store's `onLocalOp`). A no-op unless a tool is selected, so it
    /// coexists with zoom/pan + remote-control capture (pen mode is the viewer's
    /// explicit choice). Never attached in the render self-test.
    private static func attachAnnotationDrawing(
        to area: Gtk.GLArea, store: FrameStore, annotations: AnnotationStore
    ) {
        let widget = UnsafeMutableRawPointer(area.widgetPointer)
        let draw = DrawState()

        func normalized(_ px: Double, _ py: Double) -> CGPoint {
            var w: Int32 = 0
            var h: Int32 = 0
            cgtkvideo_widget_size(widget, &w, &h)
            let frame = store.current()
            let point = ViewerInputMapping.normalizePointer(
                px: px, py: py, widgetW: Double(w), widgetH: Double(h),
                videoW: frame?.width ?? 0, videoH: frame?.height ?? 0)
            return CGPoint(x: point.x, y: point.y)
        }

        let click = GestureClick()
        click.button = 1
        click.pressed = { _, _, x, y in
            guard annotations.mode.tool != nil else { return }
            draw.drawing = true
            annotations.beginStroke(at: normalized(x, y))
        }
        click.released = { _, _, x, y in
            guard draw.drawing else { return }
            draw.drawing = false
            annotations.extendStroke(to: normalized(x, y))
            annotations.endStroke()
        }
        area.addEventController(click)

        let motion = EventControllerMotion()
        motion.motion = { _, x, y in
            guard draw.drawing, annotations.mode.tool != nil else { return }
            annotations.extendStroke(to: normalized(x, y))
        }
        area.addEventController(motion)
    }

    /// The window size to request for a video of `width`×`height`: the frame's
    /// aspect, clamped so the window is neither a sliver nor larger than a
    /// sensible cap (width in [640, 1280], height ≤ 800). The user can resize
    /// freely afterwards.
    static func windowSize(forVideoWidth width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (960, 540) }
        let minW = 640.0
        let maxW = 1280.0
        let maxH = 800.0
        let aspect = Double(width) / Double(height)
        var w = min(max(Double(width), minW), maxW)
        var h = w / aspect
        if h > maxH {
            h = maxH
            w = h * aspect
        }
        return (max(1, Int(w.rounded())), max(1, Int(h.rounded())))
    }

    /// Attach the GTK event controllers that turn raw GDK pointer/key events
    /// into neutral ``InputEvent``s (via the unit-tested `ViewerInputMapping`)
    /// and hand them to `emit`. All signals fire on the GTK main thread; `emit`
    /// is responsible for gating (control must be granted) and forwarding.
    private static func attachInputCapture(
        to area: Gtk.GLArea,
        store: FrameStore,
        emit: @escaping (InputEvent) -> Void
    ) {
        let widget = UnsafeMutableRawPointer(area.widgetPointer)
        // A GLArea isn't focusable by default; without focus it never receives
        // key events. Make it focusable and grab focus on press.
        cgtkvideo_widget_make_focusable(widget)
        let mods = ModifierState()

        // Normalize a widget-space pointer position to [0,1] over the video
        // content rect. Reads the live widget + frame sizes at event time.
        func normalize(_ px: Double, _ py: Double) -> (x: Double, y: Double) {
            var w: Int32 = 0
            var h: Int32 = 0
            cgtkvideo_widget_size(widget, &w, &h)
            let frame = store.current()
            return ViewerInputMapping.normalizePointer(
                px: px, py: py,
                widgetW: Double(w), widgetH: Double(h),
                videoW: frame?.width ?? 0, videoH: frame?.height ?? 0)
        }

        // Pointer motion.
        let motion = EventControllerMotion()
        motion.motion = { _, x, y in
            let p = normalize(x, y)
            emit(.mouseMove(x: p.x, y: p.y))
        }
        area.addEventController(motion)

        // Mouse buttons — one GestureClick per button (GTK's GestureSingle
        // listens to a single button number). GDK numbers: 1 left, 2 middle,
        // 3 right; the mapper drops anything else.
        for gdkButton in [1, 2, 3] {
            guard let button = ViewerInputMapping.mouseButton(fromGdk: gdkButton) else { continue }
            let click = GestureClick()
            click.button = UInt(gdkButton)
            click.pressed = { _, _, x, y in
                cgtkvideo_widget_grab_focus(widget)  // direct keystrokes here
                let p = normalize(x, y)
                emit(.mouseDown(x: p.x, y: p.y, button: button, modifiers: mods.modifiers))
            }
            click.released = { _, _, x, y in
                let p = normalize(x, y)
                emit(.mouseUp(x: p.x, y: p.y, button: button, modifiers: mods.modifiers))
            }
            area.addEventController(click)
        }

        // Keyboard.
        let keys = EventControllerKey()
        keys.modifiers = { _, state in
            mods.modifiers = ViewerInputMapping.keyModifiers(fromGdkState: UInt(state.rawValue))
        }
        keys.keyPressed = { _, _, keycode, state in
            let m = ViewerInputMapping.keyModifiers(fromGdkState: UInt(state.rawValue))
            mods.modifiers = m
            guard let usage = ViewerInputMapping.hidUsage(fromGdkHardwareKeycode: Int(keycode)),
                !ViewerInputMapping.isModifierUsage(usage)
            else { return }  // unmapped or a modifier key (state rides every event)
            emit(.keyDown(key: usage, modifiers: m))
        }
        keys.keyReleased = { _, _, keycode, state in
            let m = ViewerInputMapping.keyModifiers(fromGdkState: UInt(state.rawValue))
            mods.modifiers = m
            guard let usage = ViewerInputMapping.hidUsage(fromGdkHardwareKeycode: Int(keycode)),
                !ViewerInputMapping.isModifierUsage(usage)
            else { return }
            emit(.keyUp(key: usage, modifiers: m))
        }
        area.addEventController(keys)
    }

    // MARK: - Continuous zoom / pan

    /// Mutable continuous zoom/pan state shared by the render closure and the
    /// scroll/click/motion closures. Reference type so all closures see one
    /// instance; only touched on the GTK main thread, so no synchronization.
    private final class ViewZoom {
        /// The pure zoom/pan state (scale + offset in widget points), advanced by
        /// `ViewerZoomMath` and projected to the GL view transform by `applyView`.
        var state = ViewerZoomState()
        /// Last pointer position in widget-logical coordinates, used as the zoom
        /// anchor for scroll (which carries no pointer position of its own).
        var lastPointer: CGPoint?
        /// The scroll handler, stashed here so the context-free C scroll callback
        /// (which only carries this box as its user pointer) can dispatch into the
        /// closure that captures the widget + store.
        var onScroll: ((Double, Double, UInt32) -> Void)?
        /// The video size the current `state` was clamped against; a change means
        /// a resolution switch and the view must snap back to fit.
        private var videoSize: (w: Int, h: Int)?

        /// Note the incoming frame's size; returns true (and resets `state`) when
        /// it differs from the last — a resolution change invalidating the offset.
        func resetIfVideoSizeChanged(width: Int, height: Int) -> Bool {
            if let s = videoSize, s.w == width, s.h == height { return false }
            let firstFrame = videoSize == nil
            videoSize = (width, height)
            if firstFrame { return false }  // nothing to reset on the first frame
            state = ViewerZoomState()
            lastPointer = nil
            return true
        }
    }

    /// GTK scroll notches per unit → multiplicative zoom step (matches the mac
    /// View-menu Zoom In step). Shift+scroll pans instead, this many widget points
    /// per unit.
    private static let zoomPerScrollUnit: CGFloat = ViewerZoomMath.menuZoomStep
    private static let panPointsPerScrollUnit: CGFloat = 48
    /// GdkModifierType bit 0 == GDK_SHIFT_MASK.
    private static let gdkShiftMask: UInt32 = 1 << 0

    /// Wire scroll (zoom / Shift-pan), double-click (smart-magnify), and pointer
    /// tracking (the scroll anchor) into the GLArea. The math is entirely
    /// `ViewerZoomMath`; each change projects to `cgtkvideo_set_view` +
    /// `cgtkvideo_queue_render`. Never attached in self-test.
    private static func attachZoomPan(
        to area: Gtk.GLArea,
        store: FrameStore,
        zoom: ViewZoom
    ) {
        let widget = UnsafeMutableRawPointer(area.widgetPointer)

        // Track the pointer so scroll can anchor at the cursor. This is a second,
        // independent motion controller from the remote-control one — GTK fans the
        // event out to both — so zoom works whether or not input capture is wired.
        let motion = EventControllerMotion()
        motion.motion = { _, x, y in zoom.lastPointer = CGPoint(x: x, y: y) }
        area.addEventController(motion)

        // Double-click toggles smart-magnify (fit ↔ zoomed) anchored at the tap.
        let dbl = GestureClick()
        dbl.button = 1
        dbl.pressed = { _, nPress, x, y in
            guard nPress == 2 else { return }
            guard let fit = fitRect(widget: widget, store: store) else { return }
            zoom.state = ViewerZoomMath.smartMagnifyToggled(
                state: zoom.state, anchor: CGPoint(x: x, y: y), fit: fit)
            applyView(zoom, widget: widget, store: store)
        }
        area.addEventController(dbl)

        // Scroll: plain → cursor-anchored zoom; Shift → pan while zoomed.
        cgtkvideo_attach_scroll(
            widget,
            { dx, dy, mods, user in
                guard let user else { return }
                let zoom = Unmanaged<ViewZoom>.fromOpaque(user).takeUnretainedValue()
                zoom.onScroll?(dx, dy, mods)
            }, Unmanaged.passUnretained(zoom).toOpaque())
        // The onScroll closure needs the widget + store; stash them on the box so
        // the context-free C callback can reach them.
        zoom.onScroll = { [weak area] dx, dy, mods in
            guard area != nil else { return }
            guard let fit = fitRect(widget: widget, store: store) else { return }
            if mods & gdkShiftMask != 0 {
                // Pan: horizontal from dx, vertical from dy. Positive scroll moves
                // the content the opposite way (natural "push the surface").
                let delta = CGSize(
                    width: -CGFloat(dx) * panPointsPerScrollUnit,
                    height: -CGFloat(dy) * panPointsPerScrollUnit)
                zoom.state = ViewerZoomMath.panned(state: zoom.state, by: delta, fit: fit)
            } else {
                // Zoom: dy < 0 (scroll up) zooms in. delta is multiplicative.
                let anchor = zoom.lastPointer ?? CGPoint(x: fit.midX, y: fit.midY)
                let delta = CGFloat(pow(Double(zoomPerScrollUnit), -dy))
                zoom.state = ViewerZoomMath.zoomed(
                    state: zoom.state, by: delta, anchor: anchor, fit: fit)
            }
            applyView(zoom, widget: widget, store: store)
        }
    }

    /// The aspect-fit rect the video occupies inside the live widget, in
    /// widget-logical coordinates — the exact rect the GL shader letterboxes to
    /// (`sx`/`sy` there × widget size), so zoom anchoring and pan clamping line up
    /// with what's on screen. The arithmetic is the shared
    /// `ViewerPointerMapping.fitRect`, so it also can't disagree with pointer
    /// mapping about where the bars are. Nil when the widget or frame has no
    /// size yet.
    private static func fitRect(
        widget: UnsafeMutableRawPointer,
        store: FrameStore
    ) -> CGRect? {
        var w: Int32 = 0
        var h: Int32 = 0
        cgtkvideo_widget_size(widget, &w, &h)
        guard w > 0, h > 0,
            let frame = store.current(), frame.width > 0, frame.height > 0
        else { return nil }
        return ViewerPointerMapping.fitRect(
            paneSize: (width: Double(w), height: Double(h)),
            videoSize: (width: frame.width, height: frame.height))
    }

    /// Project the current zoom/pan state onto the GL view transform and request a
    /// repaint. `ViewerZoomMath.videoRect` yields the (re-clamped) displayed rect
    /// in widget-logical coordinates; its centre maps to the shader's NDC pan and
    /// its scale to the shader's zoom (whose quad half-extent is `fit × scale`, so
    /// the projected rect matches `videoRect` exactly).
    private static func applyView(
        _ zoom: ViewZoom,
        widget: UnsafeMutableRawPointer,
        store: FrameStore
    ) {
        guard let fit = fitRect(widget: widget, store: store) else { return }
        var w: Int32 = 0
        var h: Int32 = 0
        cgtkvideo_widget_size(widget, &w, &h)
        let widgetW = CGFloat(w)
        let widgetH = CGFloat(h)
        let rect = ViewerZoomMath.videoRect(fit: fit, state: zoom.state)
        // Widget-logical (y-down, origin top-left) centre → NDC (y-up, origin
        // centre). The shader draws the video quad centred at (panX, panY).
        let panX = 2 * rect.midX / widgetW - 1
        let panY = 1 - 2 * rect.midY / widgetH
        cgtkvideo_set_view(Float(zoom.state.scale), Float(panX), Float(panY))
        cgtkvideo_queue_render(widget)
    }

    public func computeLayout<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: any ViewGraphNodeChildren,
        proposedSize: ProposedViewSize,
        environment: EnvironmentValues,
        backend: Backend
    ) -> ViewLayoutResult {
        ViewLayoutResult(
            size: ViewSize(proposedSize.width ?? 640, proposedSize.height ?? 360),
            preferences: PreferenceValues.default)
    }

    public func commit<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: any ViewGraphNodeChildren,
        layout: ViewLayoutResult,
        environment: EnvironmentValues,
        backend: Backend
    ) {
        backend.setSize(
            of: widget, to: SIMD2(Int(layout.size.width), Int(layout.size.height)))
    }
}
