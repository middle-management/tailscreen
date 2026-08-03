import CWinOverlay
import Foundation
import TailscreenProtocol

/// What asking for a drawing surface produced.
public enum SharerDrawingArm: Sendable {
    case armed(SharerDrawingSurface)
    case refused(SharerDrawingRefusal)

    /// The same answer in the portable latch's vocabulary, so a host can hand
    /// this straight to ``SharerDrawingLatch/select(_:surface:)``.
    public var result: SharerDrawingArmResult {
        switch self {
        case .armed: return .armed
        case .refused(let why): return .refused(why)
        }
    }
}

/// The surface the sharer draws on: a topmost, click-taking, keyboard-taking
/// window over the shared region, alive only while a tool is armed.
///
/// A second window rather than a mode on ``AnnotationOverlay`` — the reasoning
/// is in `ts_draw_surface.h` and it comes down to one thing: disarming should
/// be an object ceasing to exist, not four style bits being restored in the
/// right order. There is no such thing as failing to destroy a window.
///
/// Everything decidable lives elsewhere. Which tool is armed and what happens
/// when arming is refused is ``SharerDrawingLatch``; pixels-to-normalized is
/// ``ScreenRegion/normalizedPoint(screenX:screenY:)``; what a stroke looks like
/// is `AnnotationStore` and `AnnotationRasterizer`. All four are tested on
/// Linux CI. What is left here is window lifetime, which no test could check
/// anyway.
public final class SharerDrawingSurface: @unchecked Sendable {
    /// Boxed so the C callbacks — which take a bare `void *` — have something
    /// stable to point at for the surface's whole life.
    private final class Callbacks {
        /// The shared region's SIZE at the origin, because the C layer reports
        /// client coordinates. Its `x`/`y` are deliberately zero: the window
        /// covers the region exactly, so client space *is* region space.
        let extent: ScreenRegion
        let onPointer: @Sendable (Int, Double, Double) -> Void
        let onRelease: @Sendable () -> Void

        init(
            extent: ScreenRegion,
            onPointer: @escaping @Sendable (Int, Double, Double) -> Void,
            onRelease: @escaping @Sendable () -> Void
        ) {
            self.extent = extent
            self.onPointer = onPointer
            self.onRelease = onRelease
        }
    }

    private let handle: OpaquePointer
    private let callbacks: Unmanaged<Callbacks>

    private init(handle: OpaquePointer, callbacks: Unmanaged<Callbacks>) {
        self.handle = handle
        self.callbacks = callbacks
    }

    /// Put the surface up over `region` and take the keyboard, or say why not.
    ///
    /// - Parameters:
    ///   - onPointer: phase (0 pressed, 1 dragged, 2 released) and a normalized
    ///     `[0, 1]` point in the shared region. **Fires on the surface's own
    ///     pump thread**, not the caller's.
    ///   - onRelease: the sharer pressed Escape, or the surface lost the
    ///     keyboard — see `ts_draw_surface.h` for why those are one event.
    ///     Also on the pump thread, and it **must not** deallocate this object
    ///     synchronously: teardown joins that thread. Hop first.
    ///
    /// Call from the thread a person's click arrived on. `SetForegroundWindow`
    /// only obliges a process that is already in the foreground, which this one
    /// is precisely because somebody just clicked it.
    public static func arm(
        region: ScreenRegion,
        onPointer: @escaping @Sendable (Int, Double, Double) -> Void,
        onRelease: @escaping @Sendable () -> Void
    ) -> SharerDrawingArm {
        let box = Unmanaged.passRetained(
            Callbacks(
                extent: ScreenRegion(x: 0, y: 0, width: region.width, height: region.height),
                onPointer: onPointer, onRelease: onRelease))

        var status: Int32 = Int32(TS_DRAW_NO_SURFACE)
        let created = ts_draw_surface_create(
            Int32(region.x), Int32(region.y), Int32(region.width), Int32(region.height),
            box.toOpaque(),
            { context, phase, x, y in
                guard let context else { return }
                let callbacks = Unmanaged<Callbacks>.fromOpaque(context).takeUnretainedValue()
                // Clamped and normalized by the tested inverse mapping, not by
                // arithmetic written here: a drag that leaves the window keeps
                // reporting, and Win32 hands those coordinates over as a signed
                // pair that reads as ~65535 if anyone gets the cast wrong.
                let point = callbacks.extent.normalizedPoint(
                    screenX: Int(x), screenY: Int(y))
                callbacks.onPointer(Int(phase), point.x, point.y)
            },
            { context in
                guard let context else { return }
                Unmanaged<Callbacks>.fromOpaque(context).takeUnretainedValue().onRelease()
            },
            &status)

        guard let created else {
            box.release()
            return .refused(status == Int32(TS_DRAW_NO_KEYBOARD) ? .noKeyboard : .noSurface)
        }
        return .armed(SharerDrawingSurface(handle: created, callbacks: box))
    }

    deinit {
        // Synchronous, and the one place in this port where a bounded wait
        // leans long rather than short: until this returns, the sharer's
        // desktop is still swallowing clicks.
        ts_draw_surface_destroy(handle)
        // Only once the C side has promised no further callbacks.
        callbacks.release()
    }
}
