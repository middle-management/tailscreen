import CGtkOverlay
import Foundation
import TailscreenProtocol

/// Shows the annotations viewers draw, on the Linux sharer's own screen.
///
/// The Linux sibling of `WinOverlayKit.AnnotationOverlay`, deliberately down to
/// the method names: both hold a `ReceivedAnnotations`, rasterize it with
/// `AnnotationRasterizer`, and hand the premultiplied BGRA to the platform's
/// compositor. Everything that could be got wrong in an interesting way —
/// which strokes should be visible, and what they look like — lives in the
/// portable tier where Linux CI already tests it. What is left here is buffer
/// ownership and a scheduled tick.
///
/// **It is inside the capture region, and that is fine.** The Linux sharer
/// captures the X11 root, so these strokes are captured along with everything
/// else and viewers see them twice: once because their own client drew them,
/// once because they came back in the video. Both copies are the same stroke
/// at the same normalized position, so the result is redundant rather than
/// wrong — the same thing macOS's `SharerOverlayWindow` does in display mode,
/// where being captured is in fact the point (it is how a *sharer's* own
/// strokes reach viewers at all).
///
/// Callable from any thread, including the server's control-channel thread
/// where annotations actually arrive: the C layer marshals every GTK call onto
/// the main thread.
final class SharerAnnotationOverlay: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private var store = ReceivedAnnotations()
    private var pixels: [UInt8]
    private let width: Int
    private let height: Int

    /// Whether this session can show an overlay at all.
    ///
    /// False without a compositing manager, because an uncomposited X11 window
    /// has no per-pixel alpha and the "overlay" would be an opaque black
    /// rectangle over the sharer's screen. A caller that gets false here must
    /// withhold `ScreenShareCaps.annotations` rather than advertise a surface
    /// it cannot draw — see `TailscaleScreenShareServer.init`'s
    /// `rendersAnnotations`.
    static var isSupported: Bool { ts_gtk_overlay_supported() == 1 }

    /// - Parameters:
    ///   - width/height: the captured region's pixel size. Annotations arrive
    ///     normalized against what the viewer sees, so the overlay has to be
    ///     the same rectangle the capture is or every stroke lands offset.
    ///
    /// - Returns: nil when the platform has no overlay, or the window could not
    ///   be created. A share without annotations is a smaller loss than a share
    ///   that refuses to start.
    ///
    /// GTK main thread only — it creates a window. (Every *other* entry point,
    /// including `deinit`, is callable from anywhere; the C layer posts to the
    /// main loop. That asymmetry is deliberate: creation is the one call whose
    /// result the caller needs synchronously, in order to decide whether to
    /// advertise `ScreenShareCaps.annotations` at all.)
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
    ///   here must not be ignored:** arming makes this fullscreen
    ///   override-redirect window swallow every click on the sharer's desktop,
    ///   and the only way back out is the Escape key, which needs keyboard
    ///   focus the window manager will never grant an override-redirect window.
    ///   If focus could not be taken, the C layer leaves the overlay
    ///   click-through and answers false rather than trapping the sharer
    ///   behind a window they cannot dismiss.
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
            // Drop the callbacks with the arm, so a stray event on the way
            // down cannot reach a host that believes drawing is off.
            ts_gtk_overlay_set_input_callbacks(handle, nil, nil, nil)
        }
        return reached
    }

    /// Apply one op — from a viewer, or from the sharer's own drawing — and
    /// redraw if anything changed.
    ///
    /// One store for both, and therefore one render pass: a sharer's stroke and
    /// a viewer's are the same kind of thing, and keeping two would mean two
    /// rasterizations and two chances for them to disagree about z-order.
    ///
    /// Cheap when nothing changed, which matters: a viewer dragging a pen
    /// re-sends the same stroke every few milliseconds.
    func apply(_ op: AnnotationOp, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let (changed, expiry) = lock.withLock {
            (store.apply(op, nowNs: nowNs), store.nextExpiryNs)
        }
        guard changed else { return }
        redraw()
        // A click marker has to vanish on its own, so something has to come
        // back for it. Scheduled off the op that created it rather than by
        // owning a repeating timer: this fires once per gesture and costs
        // nothing the rest of the time, and a share spends almost all of its
        // life with nobody drawing. Same shape as the Windows overlay.
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

    private func redraw() {
        guard let handle else { return }
        let annotations = lock.withLock { store.annotations }

        guard !annotations.isEmpty else {
            ts_gtk_overlay_hide(handle)
            return
        }

        let width = self.width
        let height = self.height
        lock.withLock {
            pixels.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                AnnotationRasterizer.render(
                    annotations,
                    into: AnnotationRasterizer.Surface(
                        bgra: base,
                        stride: width * AnnotationRasterizer.bytesPerPixel,
                        width: width,
                        height: height))
                ts_gtk_overlay_update(
                    handle, base,
                    Int32(width * AnnotationRasterizer.bytesPerPixel),
                    Int32(width), Int32(height))
            }
        }
    }
}
