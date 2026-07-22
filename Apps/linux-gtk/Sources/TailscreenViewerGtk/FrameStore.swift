import Foundation
import TailscreenViewer

/// Thread-safe holder for the most recent decoded frame. The video sink writes
/// the latest frame (from the transport/decoder thread); the `GtkVideoView`
/// render callback reads it (on the GTK main thread). Latest-frame-wins — an
/// unshown frame is simply overwritten, exactly like the SDL sink.
public final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: DecodedVideoFrame?
    private var requestRedraw: (() -> Void)?

    public init() {}

    public func set(_ newFrame: DecodedVideoFrame) {
        lock.lock()
        frame = newFrame
        let redraw = requestRedraw
        lock.unlock()
        // Ask the GLArea to repaint. `set` is called from `present`, which runs
        // on the GTK main thread (the @MainActor transport, serviced by
        // swift-cross-ui's RunLoop tick), so calling into GTK here is safe.
        redraw?()
    }

    public func current() -> DecodedVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    /// Register the GLArea-repaint request (`GtkVideoView` sets this once the
    /// area exists). Invoked on `set` so a new frame triggers a redraw.
    public func setRedraw(_ redraw: @escaping () -> Void) {
        lock.lock()
        requestRedraw = redraw
        lock.unlock()
    }
}
