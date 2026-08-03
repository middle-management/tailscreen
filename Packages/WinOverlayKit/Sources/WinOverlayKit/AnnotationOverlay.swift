import CWinOverlay
import Foundation
import TailscreenProtocol

/// Shows the annotations viewers draw, on the sharer's own screen.
///
/// Holds the store, the pixel buffer and the window, and does the one thing
/// that has to be right: rasterize into premultiplied BGRA and hand it to
/// `UpdateLayeredWindow`. The interesting halves are elsewhere on purpose —
/// `ReceivedAnnotations` decides what should be visible and `AnnotationRasterizer`
/// draws it, both in the portable tier where Linux CI runs their tests. What
/// is left here is window lifetime, which no test could check anyway.
///
/// Callable from any thread, including the network thread annotations arrive
/// on: the window itself lives on a thread of its own with a message pump (see
/// `ts_overlay.h`), and every call here is a post to it.
public final class AnnotationOverlay: @unchecked Sendable {
    /// A screen rectangle in virtual-desktop pixels — the same geometry remote
    /// control maps into, and for the same reason: an annotation's normalized
    /// coordinates are relative to what the viewer can SEE, so they land
    /// correctly only against the captured region's real rect.
    public struct Region: Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var store = ReceivedAnnotations()
    /// What the SHARER is drawing right now, including the stroke still under
    /// the pointer.
    ///
    /// Kept apart from `store` — which holds what viewers sent — rather than
    /// pushed through it: the in-progress stroke is replaced wholesale on every
    /// pointer move, and `ReceivedAnnotations` is built around ops that have
    /// already happened. Merged at render time, so there is still exactly one
    /// rasterization and one z-order.
    private var localStrokes: [Annotation] = []
    private var pixels: [UInt8]
    private let region: Region

    /// - Returns: nil when the platform has no overlay — off Windows, or if
    ///   the window could not be created. A share without annotations is a
    ///   smaller loss than a share that refuses to start.
    public init?(region: Region) {
        guard region.width > 0, region.height > 0 else { return nil }
        self.region = region
        self.pixels = [UInt8](
            repeating: 0,
            count: region.width * region.height * AnnotationRasterizer.bytesPerPixel)

        guard
            let created = ts_overlay_create(
                Int32(region.x), Int32(region.y), Int32(region.width), Int32(region.height))
        else { return nil }
        self.handle = created
    }

    deinit {
        // Synchronous teardown — the same rule the rest of this port follows.
        // It joins the overlay's thread, under a bounded wait so a wedged pump
        // cannot hold up the end of a share.
        ts_overlay_destroy(handle)
    }

    /// Apply one op from a viewer and redraw if anything changed.
    ///
    /// Called on the server's control-channel thread. Cheap when nothing
    /// changed, which matters because a viewer dragging a pen sends an op
    /// every few milliseconds.
    public func apply(_ op: AnnotationOp, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let (changed, expiry) = lock.withLock {
            (store.apply(op, nowNs: nowNs), store.nextExpiryNs)
        }
        guard changed else { return }
        redraw()
        // A click marker has to vanish on its own, so SOMETHING has to come
        // back for it. Scheduled off the arrival of the op that created it,
        // rather than by owning a repeating timer: this fires once per
        // gesture and costs nothing the rest of the time, and a share spends
        // almost all of its life with nobody drawing.
        if let expiry, expiry > nowNs {
            let delay = Double(expiry - nowNs) / 1_000_000_000
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tick()
            }
        }
    }

    /// Drop click markers that have aged out. A caller ticks this; there is no
    /// timer in here, because owning one would mean owning a thread.
    public func tick(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let changed = lock.withLock { store.expire(nowNs: nowNs) }
        if changed { redraw() }
    }

    /// When the next click marker expires, so a caller can sleep rather than
    /// poll at frame rate for something that happens once a gesture.
    public var nextTickNs: UInt64? { lock.withLock { store.nextExpiryNs } }

    /// Replace what the sharer's own pen is showing.
    ///
    /// Pushed on every change to the sharer's `AnnotationStore` — including
    /// mid-drag — because a sharer who cannot see their own stroke until they
    /// let go has no way to tell whether drawing is working at all. That is the
    /// same cost profile a viewer dragging a pen already imposes: an op every
    /// few milliseconds, each one a redraw.
    public func setLocalStrokes(_ strokes: [Annotation]) {
        lock.withLock { localStrokes = strokes }
        redraw()
    }

    /// Clear everything and hide. Called when the share ends.
    public func clear() {
        lock.withLock {
            _ = store.apply(.clearAll, nowNs: 0)
            localStrokes = []
        }
        redraw()
    }

    private func redraw() {
        let (isEmpty, annotations) = lock.withLock {
            // The sharer's own strokes go LAST, so a sharer circling something
            // a viewer drew ends up on top of it rather than under it.
            (store.isEmpty && localStrokes.isEmpty, store.annotations + localStrokes)
        }
        guard let handle else { return }

        // Hidden rather than transparent when there is nothing to draw: a
        // fully-transparent layered window still costs the compositor on every
        // frame of whatever is underneath it, and a share spends most of its
        // life with nobody drawing.
        guard !isEmpty else {
            ts_overlay_hide(handle)
            return
        }

        // Showing is implicit in the update — there is no separate call,
        // because an overlay with nothing in it should never be visible and so
        // cannot be asked to be.
        lock.withLock {
            pixels.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                AnnotationRasterizer.render(
                    annotations,
                    into: AnnotationRasterizer.Surface(
                        bgra: base,
                        stride: region.width * AnnotationRasterizer.bytesPerPixel,
                        width: region.width, height: region.height))
                _ = ts_overlay_update(handle, base, Int32(region.width), Int32(region.height))
            }
        }
    }
}
