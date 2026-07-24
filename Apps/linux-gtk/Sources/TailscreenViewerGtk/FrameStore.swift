import Foundation
import TailscreenViewer

/// Thread-safe holder for the most recent decoded frame. The video sink writes
/// the latest frame (from the transport/decoder thread); the `GtkVideoView`
/// render callback reads it (on the GTK main thread). Latest-frame-wins — an
/// unshown frame is simply overwritten, exactly like the SDL sink.
public final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: DecodedVideoFrame?

    public init() {}

    public func set(_ newFrame: DecodedVideoFrame) {
        lock.lock()
        frame = newFrame
        lock.unlock()
    }

    public func current() -> DecodedVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frame
    }
}
