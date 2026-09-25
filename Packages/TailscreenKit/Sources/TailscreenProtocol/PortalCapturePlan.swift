import Foundation

/// The decisions a ScreenCast-portal capture backend makes, extracted so
/// they can be tested where there is no portal.
///
/// Every other capture backend has a CI leg that captures for real; the
/// portal can't — a share begins with a compositor consent dialog a person
/// clicks, so there's no headless path to a frame
/// (`Packages/PortalCaptureKit/README.md`). This is the untestable part made
/// as small as possible: the backend keeps the PipeWire/libavcodec calls,
/// every branch that could be *wrong* lives here. Same reasoning as
/// `SharerDrawingLatch` for the Windows drawing surface.
public enum PortalCapturePlan {
    /// What a portal stream is doing, in terms this tier can name. A neutral
    /// restatement of `PortalStream.State` (`TailscreenProtocol` is
    /// Foundation-only, can't import PipeWire).
    public enum Condition: Equatable, Sendable {
        case connecting
        case streaming
        /// The stream broke: the PipeWire connection dropped, a buffer could
        /// not be negotiated.
        case failed(String)
        /// The producer went away. On a real desktop this is almost always the
        /// person clicking their compositor's own "stop sharing" button.
        case ended(String)
    }

    /// What the host should do about a stream condition.
    public enum StreamAction: Equatable, Sendable {
        /// Nothing to report.
        case ignore
        /// Fire `onUserStopped`: tear the share down quietly, do not respawn.
        case userStopped
        /// Fire `onUnexpectedExit` with this reason.
        case unexpectedExit(String)
    }

    /// Route a stream condition to a `CaptureEncoding` callback.
    ///
    /// **The `ended` → `userStopped` edge matters**: routing a compositor's
    /// own "stop sharing" to `onUnexpectedExit` would make the server
    /// respawn the backend and raise a fresh consent dialog at someone who
    /// just said stop.
    ///
    /// A genuine failure stays retryable: the reason string avoids the
    /// `source-gone:`/`permanent:` markers `classifyHelperExit` reads, which
    /// would suppress a recovery that can work (the host holds the
    /// negotiated `PortalSession` across a restart, so a respawn rebuilds
    /// only the PipeWire stream and doesn't re-prompt).
    public static func action(for condition: Condition) -> StreamAction {
        switch condition {
        case .connecting, .streaming:
            return .ignore
        case .ended:
            return .userStopped
        case .failed(let detail):
            return .unexpectedExit("portal stream failed: \(detail)")
        }
    }

    /// What to do with a frame whose geometry may not match the open encoder.
    public enum FrameAction: Equatable, Sendable {
        /// Geometry agrees — convert and encode.
        case encode
        /// The stream renegotiated. Rebuild the encoder at this size, then
        /// encode subsequent frames.
        case rebuildEncoder(width: Int, height: Int)
        /// Skip this frame; the payload says why (diagnostics only).
        case drop(String)
    }

    /// Round a captured size to what an encoder can actually take. Even in
    /// both axes: 4:2:0 chroma is half-resolution each way, and libavcodec
    /// rounds its context down anyway. The portal redoes this on every
    /// resize (Windows does the same `& ~1` just once, at start).
    public static func encodableSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        let w = width & ~1
        let h = height & ~1
        guard w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// How long to wait before rebuilding the encoder again. Not a tidiness
    /// knob: a window dragged by its corner renegotiates the PipeWire format
    /// continuously, and rebuilding per frame would freeze the screen in
    /// `avcodec_open2` for the whole resize.
    public static let minRebuildIntervalNs: UInt64 = 500_000_000

    /// Decide what to do with an incoming frame.
    ///
    /// - Parameters:
    ///   - frame: the size PipeWire actually delivered.
    ///   - encoder: the open encoder's size, or nil before one exists.
    ///   - lastRebuildNs: when the encoder was last rebuilt, nil if never.
    ///
    /// A mismatch is expected, not exceptional: the portal is the only
    /// backend that can share a single window, and windows get resized. The
    /// server supports rebuilding rather than tearing the share down.
    public static func frameAction(
        frame: (width: Int, height: Int),
        encoder: (width: Int, height: Int)?,
        lastRebuildNs: UInt64?,
        nowNs: UInt64,
        minIntervalNs: UInt64 = minRebuildIntervalNs
    ) -> FrameAction {
        guard let wanted = encodableSize(width: frame.width, height: frame.height) else {
            return .drop("unusable frame geometry \(frame.width)x\(frame.height)")
        }
        guard let encoder else {
            return .rebuildEncoder(width: wanted.width, height: wanted.height)
        }
        if wanted.width == encoder.width && wanted.height == encoder.height {
            return .encode
        }
        // Debounce against the LAST REBUILD, never the last mismatch —
        // otherwise a continuously resizing window would hold the encoder
        // off forever and stay frozen after the user lets go.
        if let lastRebuildNs, nowNs &- lastRebuildNs < minIntervalNs {
            return .drop(
                "waiting out a resize: stream is \(wanted.width)x\(wanted.height), "
                    + "encoder is \(encoder.width)x\(encoder.height)")
        }
        return .rebuildEncoder(width: wanted.width, height: wanted.height)
    }
}
