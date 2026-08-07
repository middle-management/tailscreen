// The adaptive-FEC decision cluster for `TailscaleScreenShareServer`,
// moved verbatim out of TailscaleScreenShareServer.swift (see
// plans/fec-xor-recovery.md): the sweep-window state machine, the per-viewer
// parity gate, the raw-loss group-size ladder, and the encoder-rate
// compensation. Everything here is a pure `static func` on the server (plus
// its value types): no instance state, no locks, no callbacks.
// `FECOverheadDecisionTests` exercises it through the public API.

import Foundation
import TailscreenProtocol

extension TailscaleScreenShareServer {
    // MARK: - Adaptive FEC (pure decisions — see plans/fec-xor-recovery.md)

    /// Adaptive-FEC state carried across sweep windows: the active group size
    /// (0 = FEC off) and the consecutive-clean-window count driving the
    /// off-gate hysteresis.
    public struct FECState: Equatable, Sendable {
        public var groupSize: Int = 0
        public var cleanWindows: Int = 0

        public init(groupSize: Int = 0, cleanWindows: Int = 0) {
            self.groupSize = groupSize
            self.cleanWindows = cleanWindows
        }
    }

    /// Per-viewer measurements the sweep snapshots for the FEC arm.
    public struct FECViewerSample: Equatable, Sendable {
        /// Latest RR-derived RTT (0 = unknown).
        public var rttNs: UInt64 = 0
        /// Freshness-decayed residual (post-FEC) RR loss, Q8.
        public var residualLossQ8: Int = 0
        /// FEC-recovered packets this viewer reported this window.
        public var recovered: Int = 0
        /// NACK-recovered packets this viewer reported this window. Feeds
        /// raw-loss reconstruction identically to `recovered`: a served
        /// retransmit masks link loss (counts as received), so without it a
        /// link NACK is quietly repairing reads clean and FEC never gates on —
        /// even at the high RTT where NACK's per-loss round trip is the very
        /// latency FEC's zero-RTT recovery removes.
        public var nackRecovered: Int = 0
        /// Video packets planned for THIS viewer this window — the
        /// denominator for its own recovered-loss fraction. Per-viewer on
        /// purpose: a shared template-stream count would sum recoveries
        /// across viewers against one stream (two viewers each recovering
        /// 3 % must not read as 6 %) and would deflate a keyframe-only
        /// throttled viewer's rate (its expected count is a small fraction
        /// of the templates), dropping its gate and inviting a
        /// loss → PLI-storm → re-gate oscillation.
        public var expectedPackets: Int = 0
        /// Viewer advertised `.fec` in its HELLO.
        public var fecCapable: Bool = false

        public init(
            rttNs: UInt64 = 0, residualLossQ8: Int = 0, recovered: Int = 0,
            nackRecovered: Int = 0, expectedPackets: Int = 0, fecCapable: Bool = false
        ) {
            self.rttNs = rttNs
            self.residualLossQ8 = residualLossQ8
            self.recovered = recovered
            self.nackRecovered = nackRecovered
            self.expectedPackets = expectedPackets
            self.fecCapable = fecCapable
        }
    }

    /// One sweep step of the FEC arm: the next adaptive state plus the set
    /// of viewers gated for parity delivery this window.
    public struct FECSweepDecision: Equatable, Sendable {
        public var state = FECState()
        public var gated: Set<String> = []
    }

    /// Convert a per-window recovered-packet count to a Q8 loss fraction
    /// against that viewer's own expected packet count (same fixed point as
    /// the RR `fracLostQ8`). Raw link loss ≈ residual + this.
    public static func fecRecoveredQ8(recovered: Int, expectedPackets: Int) -> Int {
        guard expectedPackets > 0, recovered > 0 else { return 0 }
        return min(255, recovered * 256 / expectedPackets)
    }

    /// The raw-loss → group-size ladder: 2–4 % → 10, 4–8 % → 7, > 8 % → 5.
    private static func fecLadder(rawLossQ8: Int) -> Int {
        if rawLossQ8 > TransportTuning.fecHighLossQ8 { return TransportTuning.fecGroupSizeHeavy }
        if rawLossQ8 > TransportTuning.fecMidLossQ8 { return TransportTuning.fecGroupSizeMedium }
        if rawLossQ8 > TransportTuning.fecOnGateLossQ8 { return TransportTuning.fecGroupSizeLight }
        return 0
    }

    /// Pure per-viewer parity gate: this viewer receives parity only when
    /// its **own** measured path passes the on-gate — RTT > 150 ms and raw
    /// (residual + recovered, against its own expected count) loss > 2 %.
    /// Clean-link viewers pay zero overhead even mid-share with a lossy
    /// peer; legacy / non-`.fec` viewers never pass (the caller keys the
    /// gate off the caps map).
    public static func fecViewerGate(rttNs: UInt64, rawLossQ8: Int) -> Bool {
        rttNs > TransportTuning.fecOnGateRTTNs && rawLossQ8 > TransportTuning.fecOnGateLossQ8
    }

    /// Pure adaptive-FEC decision, one step per sweep window. Everything is
    /// **per-viewer first**: each `.fec` viewer's raw loss is residual +
    /// recovered against its own expected count (the recovered term is the
    /// anti-oscillation input — FEC hiding all loss zeroes the residual,
    /// and without it the decision would switch FEC off and re-trigger the
    /// loss it was hiding), and its gate needs BOTH high RTT and raw loss on
    /// the same path. Mixing worst-RTT and worst-loss across *different*
    /// viewers is exactly wrong: viewer A (slow, clean) + viewer B (fast,
    /// lossy) must not switch FEC on with nobody gated, paying the encoder
    /// compensation for parity no one receives.
    ///
    /// - **On-gate** (FEC currently off): at least one viewer passes its own
    ///   gate → ON, group size laddered from the worst raw loss over the
    ///   gated viewers.
    /// - **While on:** re-ladder from the gated viewers' worst raw loss.
    ///   With loss present but nobody gated (gray zone / RTT recovered),
    ///   hold N for a quick re-arm — the applier sends no parity and pays
    ///   no compensation while `gated` is empty, so a held N is free.
    /// - **Off-gate:** two consecutive windows with every `.fec` viewer's
    ///   raw loss under ~1 % step FEC off (asymmetric hysteresis, matching
    ///   the sweep's style).
    public static func fecSweepDecision(
        samples: [String: FECViewerSample], state: FECState
    ) -> FECSweepDecision {
        var gated: Set<String> = []
        var worstGatedRawQ8 = 0
        var worstRawQ8 = 0
        for (addr, sample) in samples where sample.fecCapable {
            // Raw link loss = residual (post-recovery RR loss) + everything the
            // link lost but a recovery masked. BOTH FEC and NACK recoveries
            // count as received in `fracLostQ8`, so both must be added back to
            // reconstruct raw loss — else NACK's own success on a high-RTT link
            // hides the loss that justifies turning FEC on.
            let rawLossQ8 = min(
                255,
                sample.residualLossQ8
                    + fecRecoveredQ8(
                        recovered: sample.recovered + sample.nackRecovered,
                        expectedPackets: sample.expectedPackets))
            worstRawQ8 = max(worstRawQ8, rawLossQ8)
            if fecViewerGate(rttNs: sample.rttNs, rawLossQ8: rawLossQ8) {
                gated.insert(addr)
                worstGatedRawQ8 = max(worstGatedRawQ8, rawLossQ8)
            }
        }

        let next: FECState
        if state.groupSize == 0 {
            // A gated viewer's raw loss is > the on-gate by definition, so
            // the ladder always yields a nonzero group here.
            next = gated.isEmpty ? FECState() : FECState(groupSize: fecLadder(rawLossQ8: worstGatedRawQ8))
        } else if worstRawQ8 < TransportTuning.fecCleanLossQ8 {
            let clean = state.cleanWindows + 1
            next =
                clean >= TransportTuning.fecCleanWindowsToDisable
                ? FECState()
                : FECState(groupSize: state.groupSize, cleanWindows: clean)
        } else if !gated.isEmpty {
            let laddered = fecLadder(rawLossQ8: worstGatedRawQ8)
            next = FECState(groupSize: laddered > 0 ? laddered : state.groupSize, cleanWindows: 0)
        } else {
            next = FECState(groupSize: state.groupSize, cleanWindows: 0)
        }
        return FECSweepDecision(state: next, gated: next.groupSize > 0 ? gated : [])
    }

    /// Encoder-rate compensation: with an effective group size of N, media +
    /// parity together must stay at the congestion-controlled rate, so the
    /// encoder runs at N/(N+1) of it. Skipping this would make FEC *add*
    /// 10–20 % load precisely on lossy links. 0 (FEC off, or on with nobody
    /// gated — no parity flowing) passes through unchanged. The result is
    /// clamped so compensation can never push the encoder below the adaptive
    /// floor's own compensated equivalent.
    public static func fecCompensatedBitrate(_ bitrate: Int, groupSize: Int) -> Int {
        guard groupSize > 0 else { return bitrate }
        let scaled = bitrate * groupSize / (groupSize + 1)
        let floor = TransportTuning.adaptiveFloorMinBps * groupSize / (groupSize + 1)
        return max(scaled, floor)
    }
}
