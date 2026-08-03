import Foundation

/// The decisions a ScreenCast-portal capture backend makes, extracted so they
/// can be tested where there is no portal.
///
/// **Why these are here and not inline in the backend.** Every other capture
/// backend in this repo has a CI leg that captures something for real: X11
/// grabs the Xvfb root, and the mac helper runs against a live
/// `SCStream`. The portal structurally cannot — a share begins with a consent
/// dialog a compositor draws and a person clicks, so there is no headless path
/// to a frame and there never will be (`Packages/PortalCaptureKit/README.md`).
/// What is left is to make the untestable part as small as possible: the
/// backend keeps the PipeWire and libavcodec calls, and every branch that could
/// be *wrong* rather than merely unexercised lives here.
///
/// The same reasoning produced `SharerDrawingLatch` for the Windows drawing
/// surface. It is deliberately not the same claim as a gate.
public enum PortalCapturePlan {
    /// What a portal stream is doing, in terms this tier can name.
    ///
    /// A neutral restatement of `PortalStream.State`, because `TailscreenProtocol`
    /// is Foundation-only and cannot import PipeWire. The backend's translation
    /// is a four-line `switch`; the *routing* below is the part with a wrong
    /// answer.
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
    /// **The `ended` → `userStopped` edge is the one that matters.** A person
    /// pressing "stop sharing" in their own compositor is not a fault, and
    /// routing it to `onUnexpectedExit` would make the server respawn the
    /// backend — which, for this backend, means raising a fresh consent dialog
    /// at somebody who *just said stop*. The seam already distinguishes the
    /// two cases and names a portal revoke as the example; this is that case.
    ///
    /// A genuine failure stays retryable on purpose. The host holds the
    /// negotiated `PortalSession` across a restart (the same reason the
    /// Windows backend is constructed with an already-picked capture item), so
    /// a respawn rebuilds only the PipeWire stream and does not re-prompt.
    /// The reason string therefore deliberately avoids the `source-gone:` and
    /// `permanent:` markers `TailscaleScreenShareServer.classifyHelperExit`
    /// reads — those would suppress a recovery that can actually work.
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

    /// Round a captured size to what an encoder can actually take.
    ///
    /// Even in both axes: 4:2:0 chroma is half-resolution in each, libavcodec
    /// rounds its context down, and `encode` still validates plane sizes
    /// against what was asked for — so rounding here keeps the conversion, the
    /// encoder and the guard describing one geometry. The Windows backend does
    /// the same `& ~1` at start; this tier owns it because the portal has to
    /// redo it every time a window is resized.
    public static func encodableSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        let w = width & ~1
        let h = height & ~1
        guard w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// How long to wait before rebuilding the encoder again.
    ///
    /// Not a tidiness knob. A window being dragged by its corner renegotiates
    /// the PipeWire format continuously, and rebuilding an x264 encoder per
    /// frame would spend the entire share in `avcodec_open2` — the screen
    /// would freeze for exactly as long as the user kept resizing, which is
    /// the moment they are most likely to be watching it.
    public static let minRebuildIntervalNs: UInt64 = 500_000_000

    /// Decide what to do with an incoming frame.
    ///
    /// - Parameters:
    ///   - frame: the size PipeWire actually delivered.
    ///   - encoder: the open encoder's size, or nil before one exists.
    ///   - lastRebuildNs: when the encoder was last rebuilt, nil if never.
    ///
    /// A mismatch is *expected*, not exceptional: the portal is the only
    /// backend here that can share a single window, and windows get resized.
    /// The server supports it — `onParameterSets` is documented as "once per
    /// encoder configuration" and its anchor handler re-anchors when the
    /// inputs genuinely change — so the answer is to rebuild rather than to
    /// tear the share down.
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
        // Debounce, but only against the LAST REBUILD — never against the last
        // mismatch. Timing from the mismatch would restart the clock on every
        // dropped frame, so a continuously resizing window would hold the
        // encoder off forever and the share would stay frozen after the user
        // let go.
        if let lastRebuildNs, nowNs &- lastRebuildNs < minIntervalNs {
            return .drop(
                "waiting out a resize: stream is \(wanted.width)x\(wanted.height), "
                    + "encoder is \(encoder.width)x\(encoder.height)")
        }
        return .rebuildEncoder(width: wanted.width, height: wanted.height)
    }
}
