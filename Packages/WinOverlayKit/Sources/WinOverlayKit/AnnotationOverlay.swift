import CWinOverlay
import Foundation
import TailscreenProtocol

/// Shows the annotations viewers draw, on the sharer's own screen. Holds the
/// store, pixel buffer and window; rasterizes into premultiplied BGRA and
/// hands it to `UpdateLayeredWindow`. `ReceivedAnnotations` (what's visible)
/// and `AnnotationRasterizer` (how to draw it) live in the portable tier,
/// tested on Linux CI; this owns only window lifetime.
///
/// Callable from any thread, including the network thread annotations
/// arrive on: the window lives on a thread of its own with a message pump.
public final class AnnotationOverlay: @unchecked Sendable {
    /// A screen rectangle in virtual-desktop pixels — the same geometry
    /// remote control maps into, since a stroke's normalized coordinates are
    /// relative to what the viewer sees.
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
    /// What the SHARER is drawing right now, including the stroke still
    /// under the pointer. Kept apart from `store` (built around ops that
    /// already happened) since this is replaced wholesale on every pointer
    /// move; merged at render time for one rasterization and one z-order.
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
        // Synchronous teardown, joining the overlay's thread under a bounded
        // wait so a wedged pump can't hold up the end of a share.
        ts_overlay_destroy(handle)
    }

    /// Apply one op from a viewer and redraw if anything changed. Cheap when
    /// nothing changed — a viewer dragging a pen sends an op every few milliseconds.
    public func apply(_ op: AnnotationOp, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let (changed, expiry) = lock.withLock {
            (store.apply(op, nowNs: nowNs), store.nextExpiryNs)
        }
        guard changed else { return }
        redraw()
        // Scheduled off this op's arrival rather than a repeating timer — a
        // click marker vanishing costs nothing the rest of the time.
        if let expiry, expiry > nowNs {
            let delay = Double(expiry - nowNs) / 1_000_000_000
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tick()
            }
        }
    }

    /// Drop click markers that have aged out. A caller ticks this — owning a
    /// timer here would mean owning a thread.
    public func tick(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let changed = lock.withLock { store.expire(nowNs: nowNs) }
        if changed { redraw() }
    }

    /// When the next click marker expires, so a caller can sleep rather than
    /// poll at frame rate for something that happens once a gesture.
    public var nextTickNs: UInt64? { lock.withLock { store.nextExpiryNs } }

    /// Replace what the sharer's own pen is showing. Pushed on every change,
    /// including mid-drag — a sharer who can't see their own stroke until
    /// they let go has no way to tell drawing is working.
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
            // Sharer's own strokes go LAST, so circling something a viewer
            // drew ends up on top of it.
            (store.isEmpty && localStrokes.isEmpty, store.annotations + localStrokes)
        }
        guard let handle else { return }

        // Hidden rather than transparent: a fully-transparent layered window
        // still costs the compositor every frame.
        guard !isEmpty else {
            ts_overlay_hide(handle)
            return
        }

        // Showing is implicit in the update — no separate call.
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
