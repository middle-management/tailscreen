import Foundation

/// Internal transport timeouts and tuning constants, centralized so values
/// that must stay coupled are defined (and documented) in one place instead
/// of as literals scattered across the server and client. None of these are
/// user-facing — the user-visible quality knobs live in `QualitySettings`.
///
/// `QualitySettingsTests` pins every value here to the literal it replaced,
/// so an accidental edit fails CI instead of silently retuning the transport.
public enum TransportTuning {
    /// Server: drop viewers that have gone silent for this long. Has to
    /// absorb a run of consecutive UDP keepalive losses plus Task
    /// scheduling jitter — clients send KEEPALIVE every
    /// `keepaliveIntervalNs`, so 15 s tolerates ~30 consecutive misses
    /// while still collecting a truly crashed viewer promptly.
    public static let viewerIdleTimeoutNs: UInt64 = 15_000_000_000

    /// Client: tear the viewing session down after this long without any
    /// datagram from the sharer. **Invariant: must equal
    /// `viewerIdleTimeoutNs`** — the two ends are designed to time out
    /// together (see the comments in `TailscaleScreenShareClient.receiveLoop`
    /// and around the server's `viewerIdleTimeoutNs` use). Asserted in
    /// `QualitySettingsTests`.
    public static let clientIdleDisconnectNs: UInt64 = viewerIdleTimeoutNs

    /// Client: cadence of KEEPALIVE datagrams. 500 ms keeps a dropped UDP
    /// keepalive (or a one-off Task scheduling stall) far away from the
    /// server's idle sweep.
    public static let keepaliveIntervalNs: UInt64 = 500_000_000

    /// Server: prune viewers stuck in the approval-pending state after
    /// this long. Longer than the connected-viewer timeout so the sharer
    /// has plausibly enough time to react to the Accept / Deny prompt.
    public static let pendingApprovalTimeoutNs: UInt64 = 60_000_000_000

    /// Server: hung-helper watchdog — if a live capture helper emits
    /// nothing (not even its ~1 Hz heartbeat) for this long, capture is
    /// assumed wedged and gets restarted.
    public static let helperLivenessTimeoutNs: UInt64 = 15_000_000_000

    /// Server: drop a viewer's video frame once this many are already
    /// queued behind a stalled send, so a slow viewer sheds frames (UDP
    /// video tolerates loss; a PLI recovers) rather than accumulating
    /// unbounded latency/memory.
    public static let maxQueuedVideoFramesPerViewer = 4

    /// Server: drop a viewer's audio packet once this many are already
    /// queued behind a stalled send. Audio access units arrive ~every
    /// 21.3 ms (one AAC AU), so 24 ≈ 0.5 s — deep enough to ride out a
    /// DERP hiccup, shallow enough that a stalled viewer's audio latency
    /// stays bounded. Mirrors `maxQueuedVideoFramesPerViewer` for the
    /// per-viewer audio send chains (audio is loss-tolerant; the receiver
    /// conceals the gap).
    public static let maxQueuedAudioPacketsPerViewer = 24

    /// Server: sliding window for the helper crash budget.
    public static let helperCrashWindowNs: UInt64 = 30_000_000_000

    /// Server: give up after this many helper exits inside
    /// `helperCrashWindowNs`.
    public static let maxHelperCrashesPerWindow = 3

    /// Adaptive-bitrate sweep: fraction of the baseline the bitrate is
    /// never cut below (numerator / denominator, kept as integers so the
    /// floor math stays in integer arithmetic).
    public static let adaptiveFloorNumerator = 3
    public static let adaptiveFloorDenominator = 10

    /// Adaptive-bitrate sweep: absolute bitrate floor, so a
    /// temporarily-bad link doesn't push the stream into unwatchable
    /// territory regardless of baseline.
    public static let adaptiveFloorMinBps = 500_000

    /// The adaptive sweep's bitrate floor for a given baseline: 30 % of
    /// the baseline, never below `adaptiveFloorMinBps`. Shared by the
    /// sweep and its extracted decision func so the two can't diverge.
    public static func adaptiveBitrateFloor(baseline: Int) -> Int {
        max(baseline * adaptiveFloorNumerator / adaptiveFloorDenominator, adaptiveFloorMinBps)
    }

    // MARK: - FEC (XOR single-parity) tuning — see `plans/fec-xor-recovery.md`

    /// FEC on-gate: RR-measured RTT must exceed this before parity is worth
    /// its overhead — below it a NACK round trip already beats rendering
    /// the gap, so FEC stays off on fast/direct paths.
    public static let fecOnGateRTTNs: UInt64 = 150_000_000

    /// FEC on-gate: raw link loss (residual RR loss + FEC-recovered,
    /// converted to Q8) must exceed this (~2 %).
    public static let fecOnGateLossQ8 = 5

    /// FEC off-gate: a sweep window counts as clean when raw loss is below
    /// this (~1 % — residual *and* recovered both near zero).
    public static let fecCleanLossQ8 = 3

    /// FEC off-gate: consecutive clean windows before parity switches off
    /// (the anti-oscillation hysteresis).
    public static let fecCleanWindowsToDisable = 2

    /// Loss-ladder band edges, Q8: raw loss above ~4 % steps the group size
    /// down to `fecGroupSizeMedium`; above ~8 % to `fecGroupSizeHeavy`.
    public static let fecMidLossQ8 = 10
    public static let fecHighLossQ8 = 20

    /// The group-size ladder: 2–4 % raw loss → 10 (10 % overhead), 4–8 % →
    /// 7 (~14 %), > 8 % → 5 (20 %). Never below 5 — past ~20 % overhead the
    /// link needs the bitrate/fps arms, not more parity.
    public static let fecGroupSizeLight = 10
    public static let fecGroupSizeMedium = 7
    public static let fecGroupSizeHeavy = 5

    /// Client: NACK-scheduler reorder tolerances while FEC parity is
    /// actually FLOWING (armed on the first 0x0D received, not at bare
    /// negotiation — the server always advertises `.fec`, and a clean link
    /// that never sees parity must keep phase-1 NACK timing). A packet lost
    /// first-in-group sees up to N−1 newer media packets plus the trailing
    /// parity before recovery, so the gap becomes NACK-eligible only after
    /// N+2 newer packets (N = the largest ladder group) or 25 ms (one
    /// 60 fps frame interval + parity slack) — FEC gets first shot at every
    /// gap; NACK fires only for the multi-loss groups FEC can't solve.
    public static let fecSchedulerPacketTolerance = fecGroupSizeLight + 2
    public static let fecSchedulerToleranceNs: UInt64 = 25_000_000

    /// Client: how long without any parity datagram before the FEC receive
    /// machinery disarms — scheduler tolerances back to phase-1, media
    /// buffering off. Comfortably longer than a sweep window's worth of
    /// parity cadence, short enough that a server that gated parity off
    /// doesn't leave the viewer's NACK timing relaxed for long.
    public static let fecParityIdleNs: UInt64 = 3_000_000_000
}
