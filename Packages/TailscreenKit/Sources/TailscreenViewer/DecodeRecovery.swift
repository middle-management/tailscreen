import Foundation

/// One rung of the viewer's consecutive-decode-failure escalation ladder.
///
/// Produced by `DecodeRecovery.action(consecutiveFailures:alreadyFired:)` —
/// `>=` thresholds plus a per-episode fired-rung latch, so each rung fires
/// once per episode even if the counter skips a value; both reset on the next
/// successfully decoded frame.
///
/// Shared by the macOS `VideoDecoder` (VideoToolbox) and the portable
/// `ViewerSession` (FFmpeg-backed Linux/Windows, via
/// `VideoDecoding.onDecodeFailure` → `onDecoderResetNeeded`/`onDecodeFatal`).
public enum DecodeRecoveryAction: Hashable, Sendable {
    /// A fresh IDR often un-wedges a decoder whose reference state was
    /// corrupted by loss, and it's cheap.
    case requestKeyframe
    /// Tear down and rebuild the decoder's internal state (mac: the
    /// VideoToolbox session; portable: drop the lazy libavcodec context).
    case recreateSession
    /// Show a "Connection degraded" indication.
    case signalDegraded
    /// Surface the stall through the host's alert/error path.
    case surfaceError
}

/// The decode-failure escalation ladder: pure thresholds + decision function,
/// tested by `DecodeRecoveryDecisionTests`.
public enum DecodeRecovery {
    public static let requestKeyframeFailureThreshold = 5
    public static let recreateSessionFailureThreshold = 30
    /// ~1.5–3 s of dead video at 30–60 fps.
    public static let signalDegradedFailureThreshold = 90
    /// ~5–10 s.
    public static let surfaceErrorFailureThreshold = 300

    /// The highest rung whose threshold `consecutiveFailures` meets, or nil
    /// if it already fired this episode. `>=` + `alreadyFired` (rather than
    /// `==`) keeps the ladder moving if a threshold value gets skipped; rungs
    /// fire in order, at most once per episode. Caller resets `alreadyFired`
    /// with the counter on the first successful frame.
    public static func action(
        consecutiveFailures: Int,
        alreadyFired: Set<DecodeRecoveryAction>
    ) -> DecodeRecoveryAction? {
        let rungsHighestFirst: [(threshold: Int, action: DecodeRecoveryAction)] = [
            (surfaceErrorFailureThreshold, .surfaceError),
            (signalDegradedFailureThreshold, .signalDegraded),
            (recreateSessionFailureThreshold, .recreateSession),
            (requestKeyframeFailureThreshold, .requestKeyframe)
        ]
        for rung in rungsHighestFirst where consecutiveFailures >= rung.threshold {
            if alreadyFired.contains(rung.action) { return nil }
            return rung.action
        }
        return nil
    }
}

extension DecodeRecoveryAction {
    /// Stable spelling for the `decode.recovery.action` diagnostic event —
    /// not `String(describing:)`, so renaming the case doesn't change old bundles.
    public var diagnosticName: String {
        switch self {
        case .requestKeyframe: return "request_keyframe"
        case .recreateSession: return "recreate_session"
        case .signalDegraded: return "signal_degraded"
        case .surfaceError: return "surface_error"
        }
    }
}
