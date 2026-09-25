// Congestion-control decisions for `TailscaleScreenShareServer`: PLI
// accounting, per-viewer loss attribution + fairness throttling, the
// adaptive-bitrate arm, the fps ladder, and the receiver-feedback decision.
// Pure `static func`s, no instance state. See `CongestionDecisionTests`,
// `PerViewerFairnessDecisionTests`.

import Foundation
import TailscreenProtocol

extension TailscaleScreenShareServer {
    /// PLI-ring append: add `timestampNs`, drop oldest entries past `cap`.
    public static func appendingPLI(_ ring: [UInt64], timestampNs: UInt64, cap: Int = 32) -> [UInt64] {
        var out = ring
        out.append(timestampNs)
        if out.count > cap {
            out.removeFirst(out.count - cap)
        }
        return out
    }

    /// Per-viewer loss attribution: is loss this window isolated to one
    /// viewer (whose link we can throttle without touching the shared
    /// encoder) or widespread (everyone's suffering — cut the global rate)?
    public enum LossVerdict: Equatable {
        /// No viewer over the loss threshold.
        case healthy
        /// Exactly one viewer over threshold, every OTHER viewer perfectly
        /// clean (0 PLIs), and at least two viewers total. That viewer's
        /// link — not the encoder — is the problem, so throttle it alone.
        case isolated(addr: String, plis: Int)
        /// More than one viewer losing (or a merely-nonzero peer), or a
        /// single viewer with no peers to protect: today's global cut.
        case widespread(worstPLIs: Int)
    }

    /// Loss attribution. No viewer over `lossThreshold` → `.healthy`; exactly
    /// one over threshold with every other viewer at 0 PLIs and ≥2 viewers
    /// total → `.isolated`; anything else → `.widespread` (a single viewer
    /// has no "everyone else", so it stays `.widespread`).
    public static func lossAttribution(pliCounts: [String: Int], lossThreshold: Int = 2) -> LossVerdict {
        let worst = pliCounts.values.max() ?? 0
        guard worst > lossThreshold else { return .healthy }
        let over = pliCounts.filter { $0.value > lossThreshold }
        if over.count == 1, pliCounts.count >= 2, let bad = over.first {
            let othersAllClean = pliCounts.allSatisfy { $0.key == bad.key || $0.value == 0 }
            if othersAllClean {
                return .isolated(addr: bad.key, plis: bad.value)
            }
        }
        return .widespread(worstPLIs: worst)
    }

    /// Output of `fairnessDecision`: which viewers to keep in keyframe-only
    /// mode this window, and the PLI count (worst over the NON-throttled
    /// viewers) to feed the global `nextAdaptiveBitrate`.
    public struct FairnessDecision: Equatable {
        public var throttle: [String]  // sorted for determinism
        public var globalBitrateInput: Int

        public init(throttle: [String], globalBitrateInput: Int) {
            self.throttle = throttle
            self.globalBitrateInput = globalBitrateInput
        }
    }

    /// Fairness decision layered over `lossAttribution`. An `.isolated`
    /// viewer is throttled (keyframe-only); an already-throttled viewer is
    /// renewed while still over threshold, expires after a clean window.
    /// Throttled viewers never drive the global bitrate — they're
    /// deliberately frame-skipped, so their PLIs must not re-introduce
    /// worst-link-wins coupling. Global input is the worst PLI count over
    /// non-throttled viewers.
    public static func fairnessDecision(
        pliCounts: [String: Int],
        currentlyThrottled: Set<String>,
        lossThreshold: Int = 2
    ) -> FairnessDecision {
        let verdict = lossAttribution(pliCounts: pliCounts, lossThreshold: lossThreshold)
        var throttle = currentlyThrottled.filter { (pliCounts[$0] ?? 0) > lossThreshold }
        if case .isolated(let addr, _) = verdict {
            throttle.insert(addr)
        }
        let globalInput = pliCounts.filter { !throttle.contains($0.key) }.values.max() ?? 0
        return FairnessDecision(throttle: throttle.sorted(), globalBitrateInput: globalInput)
    }

    /// Per-viewer broadcast gate: does this viewer receive this frame (and
    /// advance its sequence cursor)? A throttled viewer skips inter frames
    /// but always receives keyframes. Caller must advance `nextSequence`
    /// only when this returns true, so the throttled viewer sees a contiguous
    /// stream rather than a gap that provokes a PLI storm.
    public static func shouldSendFrame(isKeyframe: Bool, throttledUntilNs: UInt64, nowNs: UInt64) -> Bool {
        if isKeyframe { return true }
        return nowNs >= throttledUntilNs
    }

    /// Adaptive-bitrate decision: next bitrate given worst per-viewer PLI
    /// count, current/baseline bitrates, and time since last change (`nil` =
    /// hold). Cut 25% (floor: 30% of baseline or 500kbps) when loss exceeds
    /// `lossThreshold` past down-hysteresis; recover +10% (min 100kbps step)
    /// after a clean window past up-hysteresis. Asymmetric: cuts fast,
    /// recovery slow. `current` above `baseline` clamps straight down.
    public static func nextAdaptiveBitrate(
        worstPLIs: Int,
        current: Int,
        baseline: Int,
        elapsedSinceChangeNs: UInt64,
        lossThreshold: Int = 2,
        downHysteresisNs: UInt64 = 5_000_000_000,
        upHysteresisNs: UInt64 = 10_000_000_000
    ) -> Int? {
        guard baseline > 0 else { return nil }
        // Self-heal: a mid-share ceiling drop can leave `current` parked
        // above the new baseline, where neither arm below would fire on a
        // clean link. Clamp straight down, no hysteresis.
        if current > baseline { return baseline }
        // 30 % of baseline, never below 500 kbps (see TransportTuning).
        let floor = TransportTuning.adaptiveBitrateFloor(baseline: baseline)
        if worstPLIs > lossThreshold && elapsedSinceChangeNs >= downHysteresisNs && current > floor {
            return max(floor, current * 3 / 4)  // -25 %
        } else if worstPLIs == 0 && elapsedSinceChangeNs >= upHysteresisNs && current < baseline {
            return min(baseline, current + max(current / 10, 100_000))  // +10 %, min step 100 kbps
        }
        return nil
    }

    /// Measured congestion inputs for `nextCongestionDecision`. Legacy
    /// viewers contribute only `pliCount` (RR fraction 0, never NACK), so a
    /// PLI-only session degrades to `nextAdaptiveBitrate` behavior.
    public struct CongestionInputs: Equatable {
        /// Worst per-viewer RR "fraction lost" this window, Q8 (0…255).
        public var lossFractionQ8: Int
        /// Worst non-throttled per-viewer PLI count this window (legacy signal).
        public var pliCount: Int
        /// Retransmits served this window. NACK-recovered loss is cheap (one
        /// packet, not a keyframe), so it weighs half a PLI in the cut decision.
        public var nackServed: Int
        public var current: Int
        public var baseline: Int
        /// Current capture frame-rate tier (60 / 30 / 15).
        public var fpsTier: Int
        /// Session fps cap (from `QualitySettings.fpsCap`). The fps-recovery
        /// ladder must never raise above this — a `.low`-preset 30 fps session
        /// must not be pushed to 60.
        public var fpsCap: Int = 60
        public var elapsedSinceChangeNs: UInt64
        /// At least one non-isolated `.receiverReport` viewer has stopped
        /// reporting (see `feedbackIsStale`). Suppresses the up-ramp only —
        /// silence is not evidence of loss (never drives a cut) but also not
        /// evidence of a clean link. Defaults false for legacy PLI-only
        /// sessions.
        public var feedbackStale: Bool = false

        public init(
            lossFractionQ8: Int, pliCount: Int, nackServed: Int, current: Int, baseline: Int,
            fpsTier: Int, fpsCap: Int = 60, elapsedSinceChangeNs: UInt64,
            feedbackStale: Bool = false
        ) {
            self.lossFractionQ8 = lossFractionQ8
            self.pliCount = pliCount
            self.nackServed = nackServed
            self.current = current
            self.baseline = baseline
            self.fpsTier = fpsTier
            self.fpsCap = fpsCap
            self.elapsedSinceChangeNs = elapsedSinceChangeNs
            self.feedbackStale = feedbackStale
        }
    }

    /// Whether one viewer's receiver feedback has gone missing, as distinct
    /// from reporting "clean" (0). The sweep decays a stale RR's loss to 0,
    /// so without this check a dead feedback path reads as a perfect link and
    /// the recovery arm keeps climbing against a viewer nobody hears from.
    ///
    /// Two clocks: a viewer that HAS reported goes stale one window after its
    /// last report; one that has NEVER reported is measured from admission
    /// with `graceWindows` of slack (it may just not have sent one yet).
    ///
    /// `expectsReports` gates it: a viewer that never negotiated
    /// `.receiverReport` is silent by design and must not be flagged stale.
    public static func feedbackIsStale(
        expectsReports: Bool,
        hasReported: Bool,
        sinceNs: UInt64,
        windowNs: UInt64,
        graceWindows: UInt64 = 2
    ) -> Bool {
        guard expectsReports else { return false }
        let limit = hasReported ? windowNs : windowNs &* graceWindows
        return sinceNs >= limit
    }

    /// Bitrate + fps-tier decision from receiver feedback. `nil` on either
    /// field means "leave it".
    public struct CongestionDecision: Equatable, Sendable {
        public var bitrate: Int?
        public var fpsTier: Int?
        public static let hold = CongestionDecision(bitrate: nil, fpsTier: nil)
    }

    /// The fps downshift ladder: 60 → 30 → 15 (and back). `nil` at the ends.
    public static func lowerFpsTier(_ tier: Int) -> Int? {
        if tier > 30 { return 30 }
        if tier > 15 { return 15 }
        return nil
    }
    /// Next tier up, clamped to the session `cap`. `nil` when already at the
    /// top rung or the cap.
    public static func raiseFpsTier(_ tier: Int, cap: Int) -> Int? {
        let next: Int
        if tier < 30 {
            next = 30
        } else if tier < 60 {
            next = 60
        } else {
            return nil
        }
        let clamped = min(next, cap)
        return clamped > tier ? clamped : nil
    }

    /// Convert an RR "fraction lost" (Q8, 0…255) into a PLI-equivalent count
    /// so RR loss flows through the same fairness/isolation gate as PLIs.
    /// ~10% loss maps just over the 2-PLI threshold.
    public static func rrLossPLIEquivalent(fracLostQ8: Int) -> Int {
        max(0, fracLostQ8) / 8
    }

    /// Global congestion inputs, folding RR loss into the same isolation gate
    /// as PLI. Returns viewers to throttle and the worst PLI/RR-loss over
    /// only the non-throttled viewers, so one lossy viewer gets isolated
    /// rather than setting the shared rate for everyone.
    public struct GlobalCongestionInputs: Equatable {
        public var throttle: [String]
        public var pliInput: Int
        public var lossQ8Input: Int
        /// Any viewer whose feedback has gone missing, excluding those this
        /// sweep isolated — isolating a viewer removes its link from the
        /// shared decision, so its silence must not hold back the rate.
        public var feedbackStale: Bool = false
    }
    public static func congestionInputs(
        pliCounts: [String: Int],
        lossQ8ByAddr: [String: Int],
        currentlyThrottled: Set<String>,
        lossThreshold: Int = 2,
        feedbackStaleAddrs: Set<String> = []
    ) -> GlobalCongestionInputs {
        // Folds RR into PLI-equivalent units so fairness can isolate an
        // RR-lossy-but-PLI-quiet viewer.
        var combined: [String: Int] = [:]
        for key in Set(pliCounts.keys).union(lossQ8ByAddr.keys) {
            let pli = pliCounts[key] ?? 0
            let rr = rrLossPLIEquivalent(fracLostQ8: lossQ8ByAddr[key] ?? 0)
            combined[key] = max(pli, rr)
        }
        let fairness = fairnessDecision(
            pliCounts: combined, currentlyThrottled: currentlyThrottled, lossThreshold: lossThreshold)
        let throttleSet = Set(fairness.throttle)
        let pliInput = pliCounts.filter { !throttleSet.contains($0.key) }.values.max() ?? 0
        let lossQ8Input = lossQ8ByAddr.filter { !throttleSet.contains($0.key) }.values.max() ?? 0
        let stale = feedbackStaleAddrs.contains { !throttleSet.contains($0) }
        return GlobalCongestionInputs(
            throttle: fairness.throttle, pliInput: pliInput, lossQ8Input: lossQ8Input,
            feedbackStale: stale)
    }

    /// Receiver-feedback congestion control. Bitrate is the primary lever
    /// (cut 25% on heavy loss, recover 10% on a clean window, same
    /// hysteresis as `nextAdaptiveBitrate`); fps ladder is the second lever
    /// once bitrate bottoms out. Loss severity: RR fraction (>~10% cut,
    /// <~2% clean) or legacy PLI count. NACK-served packets soften the cut.
    ///
    /// fps: downshift only once bitrate is at the floor and loss persists;
    /// on recovery restore fps before letting bitrate climb past ~60% of
    /// baseline.
    ///
    /// Deliberate trade-off: this arm sees **residual** loss only (FEC
    /// recoveries count as received), so on a congestion-limited link FEC can
    /// mask loss, let the up-ramp raise the rate, and re-induce it — a slow
    /// sawtooth bounded by hysteresis. Feeding raw loss here would
    /// double-penalize loss FEC already repaired.
    public static func nextCongestionDecision(
        _ inputs: CongestionInputs,
        lossThreshold: Int = 2,
        downHysteresisNs: UInt64 = 5_000_000_000,
        upHysteresisNs: UInt64 = 10_000_000_000
    ) -> CongestionDecision {
        guard inputs.baseline > 0 else { return .hold }
        if inputs.current > inputs.baseline {
            return CongestionDecision(bitrate: inputs.baseline, fpsTier: nil)
        }

        let highLossQ8 = 26  // ~10 %
        let lowLossQ8 = 5  // ~2 %
        let floor = TransportTuning.adaptiveBitrateFloor(baseline: inputs.baseline)
        // NACK recoveries halve the effective PLI weight — cheaply-fixed loss
        // shouldn't drive a full-rate cut alone.
        let effectivePLIs = inputs.pliCount - min(inputs.pliCount, inputs.nackServed / 2)
        let heavyLoss = inputs.lossFractionQ8 > highLossQ8 || effectivePLIs > lossThreshold
        // Not gated on nackServed == 0: a NACK-repaired link is still "clean
        // enough". feedbackStale only subtracts from `clean` — missing
        // feedback is never evidence of loss, so the cut path ignores it.
        let clean =
            inputs.lossFractionQ8 <= lowLossQ8 && inputs.pliCount == 0 && !inputs.feedbackStale

        let downReady = inputs.elapsedSinceChangeNs >= downHysteresisNs
        let upReady = inputs.elapsedSinceChangeNs >= upHysteresisNs

        // Bitrate cut.
        if heavyLoss && downReady && inputs.current > floor {
            return CongestionDecision(bitrate: max(floor, inputs.current * 3 / 4), fpsTier: nil)
        }
        // fps downshift: bitrate can't cut further (at/below floor) but loss
        // persists — drop the frame-rate tier instead.
        if heavyLoss && downReady && inputs.current <= floor {
            if let lower = lowerFpsTier(inputs.fpsTier) {
                return CongestionDecision(bitrate: nil, fpsTier: lower)
            }
            return .hold
        }
        // Recovery. Restore fps first once bitrate has climbed back to ~60 %
        // of baseline; otherwise raise bitrate.
        if clean && upReady {
            let sixtyPct = inputs.baseline * 6 / 10
            if inputs.current >= sixtyPct, let higher = raiseFpsTier(inputs.fpsTier, cap: inputs.fpsCap) {
                return CongestionDecision(bitrate: nil, fpsTier: higher)
            }
            if inputs.current < inputs.baseline {
                let raised = min(inputs.baseline, inputs.current + max(inputs.current / 10, 100_000))
                return CongestionDecision(bitrate: raised, fpsTier: nil)
            }
        }
        return .hold
    }
}
