import Foundation

/// One rung of the viewer's consecutive-decode-failure escalation ladder.
///
/// Produced by `DecodeRecovery.action(consecutiveFailures:alreadyFired:)` —
/// `>=` thresholds plus a per-episode fired-rung latch, so each rung fires once
/// per failing episode even if the counter ever skips a value; counter and
/// latches reset on the next successfully decoded frame.
///
/// The ladder is the ONE escalation policy every viewer host shares. It was
/// extracted from the macOS app's `VideoDecoder`, which still drives it for
/// VideoToolbox (counting on its own serial queue, rebuilding its
/// decompression session on `.recreateSession`); the portable `ViewerSession`
/// drives the same rungs for hosts whose decoder reports per-frame failures
/// through the `VideoDecoding.onDecodeFailure` seam (the FFmpeg-backed Linux
/// and Windows viewers) — see `ViewerSession.onDecoderResetNeeded` /
/// `.onDecodeFatal`.
public enum DecodeRecoveryAction: Hashable, Sendable {
    /// Ask the sharer for a fresh keyframe — a new IDR often un-wedges a
    /// decoder whose reference state was corrupted by loss, and it's cheap.
    case requestKeyframe
    /// Tear down and rebuild the decoder's internal state (mac: the
    /// VideoToolbox decompression session, handled inside `VideoDecoder`;
    /// portable hosts: `ViewerSession.onDecoderResetNeeded`, e.g. dropping the
    /// lazy libavcodec context so the next access unit builds a fresh one).
    case recreateSession
    /// Show a "Connection degraded" indication — the stream has been dead
    /// for a second or two of wall-clock video.
    case signalDegraded
    /// Surface the stall through the host's alert/error path.
    case surfaceError
}

/// The decode-failure escalation ladder: pure thresholds + decision function,
/// CI-tested by the package's `DecodeRecoveryDecisionTests` (moved here from
/// the macOS app target when the ladder went portable).
public enum DecodeRecovery {
    /// Failures before the first rung: ask the sharer for a keyframe.
    public static let requestKeyframeFailureThreshold = 5
    /// Failures before the decoder's internal state is torn down and rebuilt.
    public static let recreateSessionFailureThreshold = 30
    /// Failures before the degraded indication (~1.5–3 s of dead video at
    /// 30–60 fps).
    public static let signalDegradedFailureThreshold = 90
    /// Failures before the stall is surfaced as an error (~5–10 s).
    public static let surfaceErrorFailureThreshold = 300

    /// Pure escalation decision: the highest rung whose threshold
    /// `consecutiveFailures` meets or exceeds — returned only if it hasn't
    /// fired yet this episode, nil once it has. `>=` plus the `alreadyFired`
    /// latch (instead of exact `==` matching) keeps the ladder moving even
    /// when the counting is imperfect and a threshold value gets skipped.
    /// Rungs below the highest met one are superseded, never fired late, so an
    /// episode's rungs always fire in order and at most once. The caller
    /// resets its latch set along with the counter on the first successful
    /// frame.
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
