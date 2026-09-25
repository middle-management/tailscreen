// Adaptive-FEC decisions for `TailscaleScreenShareServer`: sweep-window state
// machine, per-viewer parity gate, raw-loss group-size ladder, encoder-rate
// compensation. Pure `static func`s, no instance state. See
// plans/fec-xor-recovery.md; tested via `FECOverheadDecisionTests`.

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
        /// raw-loss reconstruction like `recovered` — a served retransmit
        /// also masks link loss, so without it NACK's own success would hide
        /// the loss that should turn FEC on.
        public var nackRecovered: Int = 0
        /// Video packets planned for THIS viewer this window — denominator
        /// for its own recovered-loss fraction. Per-viewer, not shared: a
        /// shared count would sum recoveries across viewers incorrectly and
        /// deflate a throttled viewer's rate, dropping its gate.
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

    /// Per-viewer parity gate: RTT > 150ms AND raw loss > 2% on that
    /// viewer's own path. Clean-link viewers pay zero overhead even mid-share
    /// with a lossy peer.
    public static func fecViewerGate(rttNs: UInt64, rawLossQ8: Int) -> Bool {
        rttNs > TransportTuning.fecOnGateRTTNs && rawLossQ8 > TransportTuning.fecOnGateLossQ8
    }

    /// Adaptive-FEC decision, one step per sweep window. Per-viewer first:
    /// each `.fec` viewer's raw loss is residual + recovered against its own
    /// expected count (the recovered term prevents oscillation — FEC hiding
    /// all loss must not switch itself off), and gating needs BOTH high RTT
    /// and raw loss on the *same* viewer's path — mixing worst-RTT and
    /// worst-loss across different viewers would arm FEC with nobody gated
    /// to receive the parity.
    ///
    /// - **On-gate:** any viewer passing its own gate → ON, laddered from the
    ///   worst raw loss among gated viewers.
    /// - **While on:** re-ladder from gated viewers; hold N if loss persists
    ///   but nobody's gated (free, since no parity is sent while ungated).
    /// - **Off-gate:** two consecutive clean windows (raw loss < ~1%) → off.
    public static func fecSweepDecision(
        samples: [String: FECViewerSample], state: FECState
    ) -> FECSweepDecision {
        var gated: Set<String> = []
        var worstGatedRawQ8 = 0
        var worstRawQ8 = 0
        for (addr, sample) in samples where sample.fecCapable {
            // Raw loss = residual + recovered; both FEC and NACK recoveries
            // count as "received" in fracLostQ8, so both must be added back.
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
            // Ladder always yields nonzero: a gated viewer's raw loss exceeds
            // the on-gate by definition.
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

    /// Encoder-rate compensation: with group size N, media+parity together
    /// must stay at the congestion-controlled rate, so the encoder runs at
    /// N/(N+1) of it — else FEC adds 10-20% load on already-lossy links. 0
    /// (FEC off, or on with nobody gated) passes through unchanged.
    public static func fecCompensatedBitrate(_ bitrate: Int, groupSize: Int) -> Int {
        guard groupSize > 0 else { return bitrate }
        let scaled = bitrate * groupSize / (groupSize + 1)
        let floor = TransportTuning.adaptiveFloorMinBps * groupSize / (groupSize + 1)
        return max(scaled, floor)
    }
}
