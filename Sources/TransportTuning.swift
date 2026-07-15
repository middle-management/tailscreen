import Foundation

/// Internal transport timeouts and tuning constants, centralized so values
/// that must stay coupled are defined (and documented) in one place instead
/// of as literals scattered across the server and client. None of these are
/// user-facing — the user-visible quality knobs live in `QualitySettings`.
///
/// `QualitySettingsTests` pins every value here to the literal it replaced,
/// so an accidental edit fails CI instead of silently retuning the transport.
enum TransportTuning {
    /// Server: drop viewers that have gone silent for this long. Has to
    /// absorb a run of consecutive UDP keepalive losses plus Task
    /// scheduling jitter — clients send KEEPALIVE every
    /// `keepaliveIntervalNs`, so 15 s tolerates ~30 consecutive misses
    /// while still collecting a truly crashed viewer promptly.
    static let viewerIdleTimeoutNs: UInt64 = 15_000_000_000

    /// Client: tear the viewing session down after this long without any
    /// datagram from the sharer. **Invariant: must equal
    /// `viewerIdleTimeoutNs`** — the two ends are designed to time out
    /// together (see the comments in `TailscaleScreenShareClient.receiveLoop`
    /// and around the server's `viewerIdleTimeoutNs` use). Asserted in
    /// `QualitySettingsTests`.
    static let clientIdleDisconnectNs: UInt64 = viewerIdleTimeoutNs

    /// Client: cadence of KEEPALIVE datagrams. 500 ms keeps a dropped UDP
    /// keepalive (or a one-off Task scheduling stall) far away from the
    /// server's idle sweep.
    static let keepaliveIntervalNs: UInt64 = 500_000_000

    /// Server: prune viewers stuck in the approval-pending state after
    /// this long. Longer than the connected-viewer timeout so the sharer
    /// has plausibly enough time to react to the Accept / Deny prompt.
    static let pendingApprovalTimeoutNs: UInt64 = 60_000_000_000

    /// Server: hung-helper watchdog — if a live capture helper emits
    /// nothing (not even its ~1 Hz heartbeat) for this long, capture is
    /// assumed wedged and gets restarted.
    static let helperLivenessTimeoutNs: UInt64 = 15_000_000_000

    /// Server: drop a viewer's video frame once this many are already
    /// queued behind a stalled send, so a slow viewer sheds frames (UDP
    /// video tolerates loss; a PLI recovers) rather than accumulating
    /// unbounded latency/memory.
    static let maxQueuedVideoFramesPerViewer = 4

    /// Server: sliding window for the helper crash budget.
    static let helperCrashWindowNs: UInt64 = 30_000_000_000

    /// Server: give up after this many helper exits inside
    /// `helperCrashWindowNs`.
    static let maxHelperCrashesPerWindow = 3

    /// Adaptive-bitrate sweep: fraction of the baseline the bitrate is
    /// never cut below (numerator / denominator, kept as integers so the
    /// floor math stays in integer arithmetic).
    static let adaptiveFloorNumerator = 3
    static let adaptiveFloorDenominator = 10

    /// Adaptive-bitrate sweep: absolute bitrate floor, so a
    /// temporarily-bad link doesn't push the stream into unwatchable
    /// territory regardless of baseline.
    static let adaptiveFloorMinBps = 500_000

    /// The adaptive sweep's bitrate floor for a given baseline: 30 % of
    /// the baseline, never below `adaptiveFloorMinBps`. Shared by the
    /// sweep and its extracted decision func so the two can't diverge.
    static func adaptiveBitrateFloor(baseline: Int) -> Int {
        max(baseline * adaptiveFloorNumerator / adaptiveFloorDenominator, adaptiveFloorMinBps)
    }
}
