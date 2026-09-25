import Foundation

/// What the receiver should do about the gaps it's tracking, emitted by
/// `NACKScheduler.observe` / `.tick`.
public enum NACKAction: Equatable {
    /// Request selective retransmission of these sequence numbers (one NACK
    /// datagram; the caller packs them into `(pid, blp)` FCI entries).
    case sendNACK([UInt16])
    /// Give up on retransmission and fall back to a keyframe request. Emitted
    /// when a gap has exhausted its NACK attempts or aged past the server's
    /// ring window — recovery is then never worse than today's PLI path.
    case sendPLI
}

/// Pure, deterministic sequence-gap tracker driving NACK-based selective
/// retransmission on the viewer. Fed one `(seq, nowNs)` per received video
/// packet; detects gaps, waits out a short reorder tolerance (so pure
/// reordering produces **zero** NACKs, mirroring `RTPReorderBuffer`), emits
/// NACKs on an RTT-derived cadence up to a small attempt cap, then converts
/// an unrecoverable gap to a PLI.
///
/// No I/O, no wall clock — caller injects `nowNs`. Value type; the client
/// owns one behind its own serialization.
public struct NACKScheduler: Sendable {
    /// A tracked missing sequence number.
    private struct Gap {
        let firstSeenNs: UInt64
        var attempts: Int = 0
        var lastNackNs: UInt64 = 0
        /// How many *newer* packets have arrived since the gap opened. Reaching
        /// `reorderPacketTolerance` makes the gap NACK-eligible even before the
        /// time tolerance elapses (a run of newer packets means the missing one
        /// isn't merely reordered).
        var newerSeen: Int = 0
    }

    // MARK: Tunables (see the plan's NACKScheduler design)

    /// Phase-1 defaults for the reorder tolerances, named so the client can
    /// restore them after FEC parity stops flowing (`setReorderTolerances`).
    public static let defaultReorderToleranceNs: UInt64 = 15_000_000
    public static let defaultReorderPacketTolerance = 3

    /// A gap is NACK-eligible only once it's older than this OR at least
    /// `reorderPacketTolerance` newer packets have piled up behind it. Below
    /// this, a late (reordered) packet still fills the gap with no NACK.
    /// Mutable only via `setReorderTolerances` (FEC arming/disarming).
    private(set) public var reorderToleranceNs: UInt64
    /// Newer-packet count that makes a gap eligible before the time tolerance.
    private(set) public var reorderPacketTolerance: Int
    /// Maximum NACK attempts per gap before abandoning it to a PLI.
    public let maxAttempts: Int
    /// Floor on the re-NACK interval; the effective interval is
    /// `max(1.5 × RTT, reNackFloorNs)`.
    public let reNackFloorNs: UInt64
    /// A gap older than this is abandoned to a PLI regardless of attempts —
    /// it's aged past the server's retransmit ring, so a NACK can't be served.
    public let ringWindowNs: UInt64
    /// Global cap on NACK datagrams per second.
    public let maxNacksPerSecond: Int
    /// Hard cap on tracked gaps; the oldest overflow is abandoned to a PLI so
    /// a loss storm can't grow the set unbounded.
    public let maxGaps: Int

    // MARK: State

    private var highestSeq: UInt16?
    private var gaps: [UInt16: Gap] = [:]
    private var rttNs: UInt64
    /// Timestamps of recent NACK datagrams, for the per-second rate cap.
    private var nackStampsNs: [UInt64] = []
    /// Packets recovered by a served retransmit (a gap we NACKed that later
    /// filled) since the last `drainNackRecovered()`. The client ships this in
    /// the extended receiver report so the server's FEC arm counts NACK
    /// recoveries as raw link loss — otherwise NACK's own success hides the
    /// loss that would justify FEC on a high-RTT link.
    private var nackRecoveredCount: Int = 0

    public init(
        reorderToleranceNs: UInt64 = NACKScheduler.defaultReorderToleranceNs,
        reorderPacketTolerance: Int = NACKScheduler.defaultReorderPacketTolerance,
        maxAttempts: Int = 3,
        reNackFloorNs: UInt64 = 40_000_000,
        ringWindowNs: UInt64 = 1_000_000_000,
        maxNacksPerSecond: Int = 50,
        maxGaps: Int = 256,
        initialRTTNs: UInt64 = 60_000_000
    ) {
        self.reorderToleranceNs = reorderToleranceNs
        self.reorderPacketTolerance = reorderPacketTolerance
        self.maxAttempts = maxAttempts
        self.reNackFloorNs = reNackFloorNs
        self.ringWindowNs = ringWindowNs
        self.maxNacksPerSecond = maxNacksPerSecond
        self.maxGaps = maxGaps
        self.rttNs = initialRTTNs
    }

    /// Current RTT estimate in nanoseconds (test/introspection aid). Starts at
    /// `initialRTTNs`; adapts via `updateRTTSample` on each NACK→retransmit
    /// round trip.
    public var rttEstimateNs: UInt64 { rttNs }

    /// Read and reset the count of packets recovered by a served retransmit
    /// since the last call. The client drains this once per receiver report.
    public mutating func drainNackRecovered() -> Int {
        let n = nackRecoveredCount
        nackRecoveredCount = 0
        return n
    }

    /// Feed one received video packet's sequence number. Updates gap tracking
    /// (new gaps opened ahead of `highestSeq`, this seq removed if it filled a
    /// gap) and returns any actions now due.
    public mutating func observe(seq: UInt16, nowNs: UInt64) -> [NACKAction] {
        guard let highest = highestSeq else {
            highestSeq = seq
            return evaluate(nowNs: nowNs)
        }

        let forward = seq &- highest
        if forward == 0 || forward > UInt16(1 << 15) {
            // Duplicate or old straggler (possibly a served retransmit) — if
            // it fills a tracked gap, clear it and take an RTT sample; the
            // fill also counts toward the FEC arm's raw loss.
            if let filled = gaps.removeValue(forKey: seq), filled.attempts > 0, filled.lastNackNs != 0 {
                updateRTTSample(nowNs &- filled.lastNackNs)
                nackRecoveredCount += 1
            }
            return evaluate(nowNs: nowNs)
        }

        // A jump wider than `maxGaps` is a stream discontinuity, not
        // selectively repairable. NACK mode suppresses the depacketizer's own
        // loss-PLI, so emit one here or the viewer freezes with neither NACK
        // nor keyframe.
        if Int(forward) > maxGaps {
            gaps.removeAll()
            highestSeq = seq
            return [.sendPLI]
        }

        // Newer packet: open a gap for every sequence number skipped between
        // the old highest and this one, bump the newer-seen count on existing
        // gaps, and clear this seq if it was itself a tracked gap.
        var missing = highest &+ 1
        while missing != seq {
            if gaps[missing] == nil, gaps.count < maxGaps {
                gaps[missing] = Gap(firstSeenNs: nowNs)
            }
            missing &+= 1
        }
        for key in Array(gaps.keys) {
            gaps[key]?.newerSeen += 1
        }
        gaps.removeValue(forKey: seq)
        highestSeq = seq
        return evaluate(nowNs: nowNs)
    }

    /// Blend a NACK→retransmit round-trip sample into the RTT estimate (EMA,
    /// 7/8 old + 1/8 new), clamped to a sane band. Drives `reNackInterval`, so
    /// the re-NACK cadence adapts to the real path instead of the init default.
    private mutating func updateRTTSample(_ sampleNs: UInt64) {
        let clamped = min(2_000_000_000, max(1_000_000, sampleNs))
        rttNs = (rttNs &* 7 &+ clamped) / 8
    }

    /// Time-driven re-evaluation with no new packet (call periodically so a gap
    /// that stops seeing newer packets still ages out to its re-NACK / PLI).
    public mutating func tick(nowNs: UInt64) -> [NACKAction] {
        evaluate(nowNs: nowNs)
    }

    /// Remove a tracked gap *without* the straggler path's RTT-sample side
    /// effect. Used when FEC reconstructs the missing packet — otherwise
    /// FEC latency would get mistaken for a network round trip and corrupt
    /// the RTT EMA. No-op for an untracked seq.
    public mutating func cancelGap(seq: UInt16) {
        gaps.removeValue(forKey: seq)
    }

    /// Account for one FEC-recovered packet: clear its gap (no RTT sample)
    /// and, when the recovered seq is AHEAD of the highest wire packet,
    /// advance `highestSeq` past it (the tail-of-batch/marker case, where no
    /// wire packet ever carries that seq) — otherwise the next batch would
    /// re-open a gap for it and burn a spurious NACK. Otherwise identical to
    /// `observe`'s bookkeeping.
    public mutating func noteRecovered(seq: UInt16, nowNs: UInt64) {
        gaps.removeValue(forKey: seq)
        guard let highest = highestSeq else { return }
        let forward = seq &- highest
        guard forward != 0, forward <= UInt16(1 << 15) else { return }  // behind/duplicate
        // A recovery is always adjacent to received members; a wider jump
        // can't be real — leave it to `observe`'s discontinuity path.
        guard Int(forward) <= maxGaps else { return }
        var missing = highest &+ 1
        while missing != seq {
            if gaps[missing] == nil, gaps.count < maxGaps {
                gaps[missing] = Gap(firstSeenNs: nowNs)
            }
            missing &+= 1
        }
        for key in Array(gaps.keys) {
            gaps[key]?.newerSeen += 1
        }
        highestSeq = seq
    }

    /// Switch the reorder tolerances in place (FEC arming/disarming) WITHOUT
    /// dropping tracked gaps or the adapted RTT estimate, which a scheduler
    /// rebuild would.
    public mutating func setReorderTolerances(toleranceNs: UInt64, packetTolerance: Int) {
        reorderToleranceNs = toleranceNs
        reorderPacketTolerance = packetTolerance
    }

    /// True once at least one gap is being tracked (test/introspection aid).
    public var hasOpenGaps: Bool { !gaps.isEmpty }

    /// Core decision pass shared by `observe` and `tick`: batch every
    /// NACK-eligible gap into one datagram (subject to the per-second cap),
    /// abandon exhausted / aged gaps to a single PLI.
    private mutating func evaluate(nowNs: UInt64) -> [NACKAction] {
        var toNack: [UInt16] = []
        var abandon = false
        let reNackInterval = max(reNackFloorNs, rttNs + rttNs / 2)

        for seq in Array(gaps.keys) {
            guard let gap = gaps[seq] else { continue }
            let agedOut = nowNs &- gap.firstSeenNs >= ringWindowNs
            if agedOut || gap.attempts >= maxAttempts {
                gaps.removeValue(forKey: seq)
                abandon = true
                continue
            }
            let ageEligible = nowNs &- gap.firstSeenNs >= reorderToleranceNs
            let countEligible = gap.newerSeen >= reorderPacketTolerance
            guard ageEligible || countEligible else { continue }
            let firstAttempt = gap.attempts == 0
            let dueAgain = nowNs &- gap.lastNackNs >= reNackInterval
            if firstAttempt || dueAgain {
                toNack.append(seq)
            }
        }

        var actions: [NACKAction] = []
        if !toNack.isEmpty, rateAllows(nowNs: nowNs) {
            // Only seqs that fit one capped datagram (≤16 FCI entries) count
            // as attempted, or the tail beyond 16 burns all 3 attempts unsent.
            let onWire = Self.fciCappedSeqs(toNack)
            for seq in onWire {
                gaps[seq]?.attempts += 1
                gaps[seq]?.lastNackNs = nowNs
            }
            nackStampsNs.append(nowNs)
            actions.append(.sendNACK(onWire))
        }
        if abandon {
            actions.append(.sendPLI)
        }
        return actions
    }

    /// The subset of `seqs` that fits in `maxEntries` generic-NACK FCI groups
    /// (one capped NACK datagram, see `encodeNACK`). Mirrors `packFCI`'s
    /// greedy grouping.
    public static func fciCappedSeqs(_ seqs: [UInt16], maxEntries: Int = 16) -> [UInt16] {
        let sorted = seqs.sorted()
        var covered: [UInt16] = []
        var i = 0
        var entries = 0
        while i < sorted.count && entries < maxEntries {
            let pid = sorted[i]
            covered.append(pid)
            var j = i + 1
            while j < sorted.count {
                let delta = sorted[j] &- pid
                guard delta >= 1, delta <= 16 else { break }
                covered.append(sorted[j])
                j += 1
            }
            i = j
            entries += 1
        }
        return covered
    }

    /// Per-second NACK-datagram rate cap. Prunes stamps older than 1 s and
    /// admits only while under the cap.
    private mutating func rateAllows(nowNs: UInt64) -> Bool {
        nackStampsNs.removeAll { nowNs &- $0 > 1_000_000_000 }
        return nackStampsNs.count < maxNacksPerSecond
    }

    /// Pack a sorted list of missing sequence numbers into RFC-4588 generic
    /// NACK `(pid, blp)` FCI entries: each `pid` is a base seq, `blp` a bitmask
    /// of the 16 sequence numbers following it. Pure so it's unit testable.
    public static func packFCI(_ seqs: [UInt16]) -> [(pid: UInt16, blp: UInt16)] {
        let sorted = seqs.sorted()
        var entries: [(pid: UInt16, blp: UInt16)] = []
        var i = 0
        while i < sorted.count {
            let pid = sorted[i]
            var blp: UInt16 = 0
            var j = i + 1
            while j < sorted.count {
                let delta = sorted[j] &- pid
                guard delta >= 1, delta <= 16 else { break }
                blp |= UInt16(1) << (delta - 1)
                j += 1
            }
            entries.append((pid, blp))
            i = j
        }
        return entries
    }
}
