import Foundation

/// Thread-safe holder for the most recent decoded frame. The video sink writes
/// (from the transport/decoder thread); the `GtkVideoView` render callback
/// reads (on the GTK main thread). Latest-frame-wins: an unshown frame is
/// simply overwritten.
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
        // The host's redraw closure marshals onto its own UI thread (GTK
        // defers via `g_idle_add`), so `set` is safe to call from any thread.
        redraw?()
    }

    public func current() -> DecodedVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }

    /// Registers the renderer's repaint request, invoked on each `set`.
    public func setRedraw(_ redraw: @escaping () -> Void) {
        lock.lock()
        requestRedraw = redraw
        lock.unlock()
    }
}
