import CGtkOverlay
import Foundation
import TailscreenProtocol
import TailscreenSharerLinux

/// Shows the annotations viewers draw, on the Linux sharer's own screen.
///
/// Sibling of `WinOverlayKit.AnnotationOverlay` (same method names): both hold
/// a `ReceivedAnnotations`, rasterize it with `AnnotationRasterizer`, and hand
/// premultiplied BGRA to the compositor. What decides which strokes show and
/// how they look lives in the portable tier; this file only owns the buffer
/// and a scheduled tick.
///
/// **It is inside the capture region, deliberately.** The Linux sharer
/// captures the X11 root, so viewers see each stroke twice (their own draw,
/// plus it coming back in the video) — redundant, not wrong, at the same
/// normalized position. Same as macOS's `SharerOverlayWindow` in display mode,
/// where that's how a sharer's own strokes reach viewers at all.
///
/// Callable from any thread, including the server's control-channel thread:
/// the C layer marshals every GTK call onto the main thread.
final class SharerAnnotationOverlay: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private var store = ReceivedAnnotations()
    /// Whether to paint the capture outline under the strokes — the recording
    /// indicator, a border around exactly the captured region for the life of
    /// the share. Rides this overlay rather than a second window since this
    /// one is already the right rectangle, click-through, and composited.
    private var showsOutline = false
    /// Self-test override; nil uses `CaptureOutline.defaultThickness`.
    private var outlineThickness: Int?
    private var pixels: [UInt8]
    private let width: Int
    private let height: Int

    /// False without a compositing manager: an uncomposited X11 window has no
    /// per-pixel alpha, so the "overlay" would be an opaque black rectangle. A
    /// caller getting false must withhold `ScreenShareCaps.annotations` (see
    /// `TailscaleScreenShareServer.init`'s `rendersAnnotations`).
    static var isSupported: Bool { ts_gtk_overlay_supported() == 1 }

    /// - Parameters:
    ///   - width/height: the captured region's pixel size — annotations arrive
    ///     normalized against it, so a mismatch offsets every stroke.
    /// - Returns: nil if the platform has no overlay or window creation
    ///   failed. A share without annotations beats a share that won't start.
    ///
    /// GTK main thread only — it creates a window. Every other entry point,
    /// including `deinit`, is callable from anywhere (the C layer posts to the
    /// main loop); creation alone needs a synchronous result so the caller can
    /// decide whether to advertise `ScreenShareCaps.annotations`.
    init?(width: Int, height: Int) {
        guard width > 0, height > 0, Self.isSupported else { return nil }
        self.width = width
        self.height = height
        self.pixels = [UInt8](
            repeating: 0, count: width * height * AnnotationRasterizer.bytesPerPixel)
        guard let created = ts_gtk_overlay_create(0, 0, Int32(width), Int32(height)) else {
            return nil
        }
        self.handle = created
    }

    deinit {
        ts_gtk_overlay_destroy(handle)
    }

    // MARK: Sharer drawing

    /// The sharer's pointer, while drawing is armed. Phases are 0 = pressed,
    /// 1 = dragged, 2 = released; the point is normalized over the capture
    /// region. Fires on the GTK main thread.
    var onPointer: ((Int, CGPoint) -> Void)?
    /// The sharer pressed Escape and wants out of drawing mode. Fires on the
    /// GTK main thread.
    var onEscape: (() -> Void)?

    /// Arm or disarm sharer drawing.
    ///
    /// - Returns: whether the overlay reached the requested state. **A false
    ///   here must not be ignored:** arming makes this override-redirect
    ///   window swallow every click, and the only way out (Escape) needs
    ///   keyboard focus a WM never grants such a window. If focus couldn't be
    ///   taken, the C layer stays click-through and returns false rather than
    ///   trap the sharer behind it.
    ///
    /// GTK main thread only.
    func setInteractive(_ on: Bool) -> Bool {
        guard let handle else { return false }
        if on {
            let context = Unmanaged.passUnretained(self).toOpaque()
            ts_gtk_overlay_set_input_callbacks(
                handle, context,
                { ctx, phase, x, y in
                    guard let ctx else { return }
                    let overlay = Unmanaged<SharerAnnotationOverlay>
                        .fromOpaque(ctx).takeUnretainedValue()
                    overlay.onPointer?(Int(phase), CGPoint(x: x, y: y))
                },
                { ctx in
                    guard let ctx else { return }
                    let overlay = Unmanaged<SharerAnnotationOverlay>
                        .fromOpaque(ctx).takeUnretainedValue()
                    overlay.onEscape?()
                })
        }
        let reached = ts_gtk_overlay_set_interactive(handle, on ? 1 : 0) == 1
        if !on || !reached {
            // Drop callbacks with the arm so a stray event can't reach a host
            // that believes drawing is off.
            ts_gtk_overlay_set_input_callbacks(handle, nil, nil, nil)
        }
        return reached
    }

    /// Apply one op — from a viewer, or the sharer's own drawing — and redraw
    /// if anything changed. One store for both, so there's one rasterization
    /// and one z-order. Cheap when nothing changed: a dragging pen re-sends
    /// the same stroke every few milliseconds.
    func apply(_ op: AnnotationOp, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let (changed, expiry) = lock.withLock {
            (store.apply(op, nowNs: nowNs), store.nextExpiryNs)
        }
        guard changed else { return }
        redraw()
        // A click marker vanishes on its own; scheduled off the op that
        // created it rather than a repeating timer, so it costs nothing while
        // nobody is drawing. Same shape as the Windows overlay.
        if let expiry, expiry > nowNs {
            let delay = Double(expiry - nowNs) / 1_000_000_000
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tick()
            }
        }
    }

    /// Drop click markers that have aged out.
    func tick(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let changed = lock.withLock { store.expire(nowNs: nowNs) }
        if changed { redraw() }
    }

    /// Clear everything and hide. Called when the share ends, and on the
    /// mid-share source change that invalidates every stroke's coordinates.
    func clear() {
        lock.withLock { _ = store.apply(.clearAll, nowNs: 0) }
        redraw()
    }

    /// Self-test seam: the outline plus an overridable thickness (the shipping
    /// 4px border is two chroma columns at half resolution — too thin to
    /// screenshot-assert reliably). Thickness itself is pinned by
    /// `CaptureOutlineTests`.
    func setShowsOutlineForTesting(_ on: Bool, thickness: Int?) {
        lock.withLock { outlineThickness = thickness }
        setShowsOutline(on)
    }

    /// Turn the capture outline on or off. On for the life of a share.
    func setShowsOutline(_ on: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard showsOutline != on else { return false }
            showsOutline = on
            return true
        }
        guard changed else { return }
        redraw()
    }

    private func redraw() {
        guard let handle else { return }
        let (annotations, outline, thickness) = lock.withLock {
            (store.annotations, showsOutline, outlineThickness)
        }

        // Hidden only when there's nothing at all to show — the outline
        // counts, or it would vanish whenever nobody's drawing.
        guard !annotations.isEmpty || outline else {
            ts_gtk_overlay_hide(handle)
            return
        }

        let width = self.width
        let height = self.height
        lock.withLock {
            pixels.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let surface = AnnotationRasterizer.Surface(
                    bgra: base,
                    stride: width * AnnotationRasterizer.bytesPerPixel,
                    width: width,
                    height: height)
                // Clear once here so outline and strokes composite in order;
                // `render` would clear again and take the outline with it.
                AnnotationRasterizer.render([], into: surface)
                if outline {
                    CaptureOutline.draw(
                        into: surface, thickness: thickness ?? CaptureOutline.defaultThickness)
                }
                AnnotationRasterizer.draw(annotations, into: surface)
                ts_gtk_overlay_update(
                    handle, base,
                    Int32(width * AnnotationRasterizer.bytesPerPixel),
                    Int32(width), Int32(height))
            }
        }
    }
}

/// The engine's seam, satisfied by the real GTK overlay. `apply(_:)` forwards
/// with the default clock, since a protocol requirement can't be witnessed by
/// a method with a defaulted extra parameter.
extension SharerAnnotationOverlay: SharerOverlaySurface {
    func apply(_ op: AnnotationOp) {
        apply(op, nowNs: DispatchTime.now().uptimeNanoseconds)
    }
}
