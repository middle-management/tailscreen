import CGtkVideo
import Foundation
import Gtk
import GtkBackend
import SwiftCrossUI
import TailscreenViewer

/// A video surface implemented as a *downstream* swift-cross-ui `View` — no
/// fork. It conforms to the public `View` protocol directly (the tidy
/// `ElementaryView` helper is internal to swift-cross-ui), downcasts the generic
/// backend to the concrete `GtkBackend`, constructs a real `Gtk.GLArea`, and
/// draws the latest `FrameStore` frame with an OpenGL YUV→RGB shader
/// (`CGtkVideo`). Proven end-to-end (correct pixels via `glReadPixels`) — see
/// docs/linux-viewer-gtk-plan.md.
public struct GtkVideoView: View {
    let store: FrameStore
    let selfTest: Bool

    public init(store: FrameStore, selfTest: Bool = false) {
        self.store = store
        self.selfTest = selfTest
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
        let store = self.store
        let selfTest = self.selfTest
        // GL object names are per-context; if the area's context is torn down
        // and recreated (unrealize→realize, reparent), re-init on the next draw.
        area.createContext = { _ in cgtkvideo_reset() }
        area.render = { _, _ in
            // `frame` is a value-type copy with COW plane storage, so these
            // buffer pointers stay valid even if an off-thread `present()`
            // overwrites the store mid-draw. This safety depends on
            // `DecodedVideoFrame` remaining a value type.
            if let frame = store.current() {
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
        // GtkGLArea is a Gtk.Widget; GtkBackend.Widget == Gtk.Widget, so this
        // runtime cast is safe whenever `backend is GtkBackend`.
        return (area as Any) as! Backend.Widget
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
