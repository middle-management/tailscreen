import Foundation
import TailscreenViewer

/// Thread-safe holder for the most recent decoded frame. The video sink writes
/// the latest frame (from the transport/decoder thread); the `GtkVideoView`
/// render callback reads it (on the GTK main thread). Latest-frame-wins — an
/// unshown frame is simply overwritten (latest-frame-wins display).
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
        // Ask the GLArea to repaint. The redraw hand-off (`cgtkvideo_queue_render`)
        // marshals the actual GTK call onto the main thread via g_idle_add, so
        // `set` (and thus `present`) is safe from any thread; the frame itself
        // is a value-type copy behind the lock above.
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
