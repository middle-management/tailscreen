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
/// docs/linux-viewer-gtk-plan.md.
///
/// When `onInputEvent` is supplied it also captures opt-in remote-control input:
/// pointer motion, three mouse buttons, and keyboard, translated to neutral
/// ``InputEvent``s via `ViewerInputMapping` (the pure, unit-tested Core mapper).
/// Scroll is not yet captured — swift-cross-ui exposes no `EventControllerScroll`
/// binding, so it awaits a small C shim (tracked in the GTK viewer plan).
public struct GtkVideoView: View {
    let store: FrameStore
    let selfTest: Bool
    let onInputEvent: ((InputEvent) -> Void)?

    public init(
        store: FrameStore,
        selfTest: Bool = false,
        onInputEvent: ((InputEvent) -> Void)? = nil
    ) {
        self.store = store
        self.selfTest = selfTest
        self.onInputEvent = onInputEvent
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
        // One-shot: grow the (hub-sized) window to the video on the first frame.
        let sizedToVideo = ResizeLatch()
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
                    cgtkvideo_resize_toplevel(UnsafeMutableRawPointer(area.widgetPointer), Int32(w), Int32(h))
                }
                frame.yPlane.withUnsafeBufferPointer { yb in
                    frame.uPlane.withUnsafeBufferPointer { ub in
                        frame.vPlane.withUnsafeBufferPointer { vb in
                            cgtkvideo_draw_yuv(
                                Int32(frame.width), Int32(frame.height),
                                yb.baseAddress, ub.baseAddress, vb.baseAddress)
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
