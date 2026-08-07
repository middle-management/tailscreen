// Congestion-control decisions for `TailscaleScreenShareServer`, moved
// verbatim out of TailscaleScreenShareServer.swift: PLI accounting,
// per-viewer loss attribution + fairness throttling, the adaptive-bitrate
// arm, the fps ladder, and the receiver-feedback congestion decision.
// Everything here is a pure `static func` on the server (plus its
// input/output value types): no instance state, no locks, no callbacks.
// `CongestionDecisionTests` and `PerViewerFairnessDecisionTests` exercise
// it through the public API.

import Foundation
import TailscreenProtocol

extension TailscaleScreenShareServer {
    /// Pure PLI-ring append: add `timestampNs` and drop the oldest entries
    /// once the ring exceeds `cap`. Extracted from `recordPLI` so the
    /// bounded-growth invariant is unit testable.
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

    /// Pure loss attribution. Rules: no viewer over `lossThreshold` →
    /// `.healthy`; exactly one over threshold with every other viewer at 0
    /// PLIs and ≥2 viewers total → `.isolated`; anything else → `.widespread`
    /// (with a single viewer there is no "everyone else", so it stays
    /// `.widespread` — identical to today's behavior). Extracted so the
    /// precedence is unit testable, same pattern as `audioRelayDecision`.
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

    /// Pure fairness decision layered over `lossAttribution`. An `.isolated`
    /// viewer is throttled (keyframe-only) so its bad link stops dragging the
    /// session; an already-throttled viewer is renewed while it keeps losing
    /// (over threshold) and expires after a clean window (asymmetric
    /// hysteresis, matching the sweep's style). Throttled viewers never drive
    /// the global bitrate — they're deliberately frame-skipped, so their PLIs
    /// are expected and must not re-introduce the worst-link-wins coupling.
    /// The global input is therefore the worst PLI count over the
    /// *non-throttled* viewers, which for a `.widespread` verdict with nobody
    /// throttled equals the true max (today's path, so `AdaptiveBitrateTests`
    /// stay valid).
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

    /// Pure per-viewer broadcast gate: does this viewer receive this frame
    /// (and advance its sequence cursor)? A throttled viewer skips inter
    /// frames — but ALWAYS receives keyframes — so it gets a decodable
    /// keyframe-only slideshow. Crucially the caller advances `nextSequence`
    /// only when this returns true, so the throttled viewer sees a contiguous
    /// stream, not a perceived-loss gap that would provoke a PLI storm.
    public static func shouldSendFrame(isKeyframe: Bool, throttledUntilNs: UInt64, nowNs: UInt64) -> Bool {
        if isKeyframe { return true }
        return nowNs >= throttledUntilNs
    }

    /// Pure adaptive-bitrate decision: given the worst per-viewer PLI count in
    /// the last window, the current and baseline bitrates, and how long since
    /// the last change, return the next bitrate — or `nil` to hold steady.
    ///
    /// Cut 25 % (never below the floor of 30 % of baseline or 500 kbps) when
    /// loss exceeds `lossThreshold` and the down-hysteresis has elapsed; recover
    /// +10 % (min 100 kbps step, capped at baseline) after a clean window once
    /// the longer up-hysteresis has elapsed. Asymmetric hysteresis makes cuts
    /// fast and recovery slow. A `current` above `baseline` clamps straight
    /// down to it with no hysteresis (see below). Extracted from the sweep so
    /// the math is unit testable without a live encoder.
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
        // Self-heal: a mid-share ceiling drop can race an in-flight sweep
        // apply and leave `current` parked above the (new, lower) baseline,
        // where neither arm below would ever fire on a loss-free link (the
        // raise arm requires current < baseline). Clamp straight down, no
        // hysteresis — the encoder should never run above the effective
        // ceiling.
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

    /// Measured congestion inputs for `nextCongestionDecision`. Bundled so the
    /// decision stays under the argument-count limit and the sweep builds it in
    /// one place. Legacy viewers contribute only `pliCount` (their RR fraction
    /// is 0 and they never NACK), so a PLI-only session degrades to exactly the
    /// `nextAdaptiveBitrate` behavior `AdaptiveBitrateTests` pins.
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

        public init(
            lossFractionQ8: Int, pliCount: Int, nackServed: Int, current: Int, baseline: Int,
            fpsTier: Int, fpsCap: Int = 60, elapsedSinceChangeNs: UInt64
        ) {
            self.lossFractionQ8 = lossFractionQ8
            self.pliCount = pliCount
            self.nackServed = nackServed
            self.current = current
            self.baseline = baseline
            self.fpsTier = fpsTier
            self.fpsCap = fpsCap
            self.elapsedSinceChangeNs = elapsedSinceChangeNs
        }
    }

    /// Bitrate + fps-tier decision from receiver feedback. `nil` on either
    /// field means "leave it". Extracted as a pure func (same pattern as
    /// `nextAdaptiveBitrate`) so the loss bands, NACK weighting, and fps-ladder
    /// transitions are unit testable without a live encoder.
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
    /// Next tier up, clamped to the session `cap` — a capped (e.g. 30 fps
    /// `.low`) session must never be raised above its cap. `nil` when already
    /// at the top rung or the cap.
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

    /// Convert an RR "fraction lost" (Q8, 0…255) into a PLI-equivalent loss
    /// count so RR loss flows through the SAME per-viewer fairness/isolation
    /// gate as PLIs. ~10 % loss (highLossQ8 = 26) maps to just over the 2-PLI
    /// threshold, so a viewer reporting high RR loss with no PLIs is still
    /// eligible for keyframe-only isolation instead of dragging the global rate.
    public static func rrLossPLIEquivalent(fracLostQ8: Int) -> Int {
        max(0, fracLostQ8) / 8
    }

    /// Global congestion inputs derived from per-viewer signals, folding RR
    /// loss into the same isolation gate as PLI. Returns the viewers to throttle
    /// (keyframe-only) and the worst PLI / RR-loss over ONLY the non-throttled
    /// viewers — so one viewer's (possibly fabricated) RR loss gets it isolated
    /// first and can't set the shared rate for everyone.
    public struct GlobalCongestionInputs: Equatable {
        public var throttle: [String]
        public var pliInput: Int
        public var lossQ8Input: Int
    }
    public static func congestionInputs(
        pliCounts: [String: Int],
        lossQ8ByAddr: [String: Int],
        currentlyThrottled: Set<String>,
        lossThreshold: Int = 2
    ) -> GlobalCongestionInputs {
        // Combined per-viewer loss folds RR into PLI-equivalent units so the
        // fairness gate can isolate an RR-lossy-but-PLI-quiet viewer.
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
        return GlobalCongestionInputs(
            throttle: fairness.throttle, pliInput: pliInput, lossQ8Input: lossQ8Input)
    }

    /// Receiver-feedback congestion control. Bitrate is the primary lever (cut
    /// 25 % on heavy loss, recover 10 % on a clean window, asymmetric
    /// hysteresis — same math as `nextAdaptiveBitrate`); the fps ladder is the
    /// second lever once bitrate bottoms out. Loss severity comes from the RR
    /// fraction (> ~10 % Q8 cut, < ~2 % clean) *or* the legacy PLI count, so a
    /// PLI-only session behaves exactly as before. NACK-served packets soften
    /// the cut (recoverable loss the retransmit path already handled).
    ///
    /// fps rules: downshift only when the bitrate is already at the floor and
    /// loss persists; on recovery, restore fps *before* letting bitrate climb
    /// past ~60 % of baseline (frame rate hurts perception less than blocking
    /// artifacts).
    ///
    /// Known property (recorded design trade-off, not a bug): this arm sees
    /// **residual** loss only — FEC-recovered packets count as received — so
    /// on a congestion-limited link FEC can mask the loss, let the
    /// clean-window up-ramp raise the rate, and re-induce the loss: a slow
    /// sawtooth bounded by the up-hysteresis and the +10 % step. The RR's
    /// `fecRecovered` term de-oscillates only the FEC arm by design; feeding
    /// raw loss here would double-penalize loss the parity already repaired
    /// and suppress recovery exactly on the links FEC targets.
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
        // NACK recoveries halve the effective PLI weight — the loss was fixed
        // cheaply, so it shouldn't drive a full-rate cut on its own.
        let effectivePLIs = inputs.pliCount - min(inputs.pliCount, inputs.nackServed / 2)
        let heavyLoss = inputs.lossFractionQ8 > highLossQ8 || effectivePLIs > lossThreshold
        // Recovery is NOT gated on `nackServed == 0`: on a real WAN a NACK is
        // served most windows, and the retransmit already repaired that loss,
        // so requiring literally zero NACKs would suppress recovery exactly on
        // the lossy links NACK targets. Low RR loss + no PLIs is "clean enough".
        let clean = inputs.lossFractionQ8 <= lowLossQ8 && inputs.pliCount == 0

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
