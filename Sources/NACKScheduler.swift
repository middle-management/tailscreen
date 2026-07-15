import Foundation

/// What the receiver should do about the gaps it's tracking, emitted by
/// `NACKScheduler.observe` / `.tick`.
enum NACKAction: Equatable {
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
/// packet; it detects gaps, waits out a short reorder tolerance (so pure
/// reordering produces **zero** NACKs, mirroring `RTPReorderBuffer`), then
/// emits NACKs — re-NACKing on an RTT-derived cadence up to a small attempt
/// cap — and finally converts an unrecoverable gap to a PLI.
///
/// No I/O and no wall clock: the caller injects `nowNs`, so every decision is
/// reproducible in unit tests (the CI-testable core, per the extract-the-
/// decision rule). It's a plain `Sendable` value type; the client owns one
/// behind its own serialization.
struct NACKScheduler: Sendable {
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

    /// A gap is NACK-eligible only once it's older than this OR at least
    /// `reorderPacketTolerance` newer packets have piled up behind it. Below
    /// this, a late (reordered) packet still fills the gap with no NACK.
    let reorderToleranceNs: UInt64
    /// Newer-packet count that makes a gap eligible before the time tolerance.
    let reorderPacketTolerance: Int
    /// Maximum NACK attempts per gap before abandoning it to a PLI.
    let maxAttempts: Int
    /// Floor on the re-NACK interval; the effective interval is
    /// `max(1.5 × RTT, reNackFloorNs)`.
    let reNackFloorNs: UInt64
    /// A gap older than this is abandoned to a PLI regardless of attempts —
    /// it's aged past the server's retransmit ring, so a NACK can't be served.
    let ringWindowNs: UInt64
    /// Global cap on NACK datagrams per second.
    let maxNacksPerSecond: Int
    /// Hard cap on tracked gaps; the oldest overflow is abandoned to a PLI so
    /// a loss storm can't grow the set unbounded.
    let maxGaps: Int

    // MARK: State

    private var highestSeq: UInt16?
    private var gaps: [UInt16: Gap] = [:]
    private var rttNs: UInt64
    /// Timestamps of recent NACK datagrams, for the per-second rate cap.
    private var nackStampsNs: [UInt64] = []

    init(
        reorderToleranceNs: UInt64 = 15_000_000,
        reorderPacketTolerance: Int = 3,
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

    /// Update the RTT estimate (from a receiver-report round trip). Clamped to a
    /// sane band so a bogus sample can't push the re-NACK cadence absurd.
    mutating func updateRTT(_ ns: UInt64) {
        rttNs = min(2_000_000_000, max(1_000_000, ns))
    }

    /// Feed one received video packet's sequence number. Updates gap tracking
    /// (new gaps opened ahead of `highestSeq`, this seq removed if it filled a
    /// gap) and returns any actions now due.
    mutating func observe(seq: UInt16, nowNs: UInt64) -> [NACKAction] {
        guard let highest = highestSeq else {
            highestSeq = seq
            return evaluate(nowNs: nowNs)
        }

        let forward = seq &- highest
        if forward == 0 || forward > UInt16(1 << 15) {
            // Duplicate or an old straggler (possibly a served retransmit) —
            // if it fills a tracked gap, clear it; otherwise ignore.
            gaps.removeValue(forKey: seq)
            return evaluate(nowNs: nowNs)
        }

        // Newer packet: open a gap for every sequence number skipped between
        // the old highest and this one, bump the newer-seen count on existing
        // gaps, and clear this seq if it was itself a tracked gap. A jump wider
        // than `maxGaps` is a stream discontinuity (long stall / resync), not
        // recoverable loss — don't enumerate thousands of gaps; let the
        // keyframe path resync instead.
        if Int(forward) <= maxGaps {
            var missing = highest &+ 1
            while missing != seq {
                if gaps[missing] == nil, gaps.count < maxGaps {
                    gaps[missing] = Gap(firstSeenNs: nowNs)
                }
                missing &+= 1
            }
        }
        for key in Array(gaps.keys) {
            gaps[key]?.newerSeen += 1
        }
        gaps.removeValue(forKey: seq)
        highestSeq = seq
        return evaluate(nowNs: nowNs)
    }

    /// Time-driven re-evaluation with no new packet (call periodically so a gap
    /// that stops seeing newer packets still ages out to its re-NACK / PLI).
    mutating func tick(nowNs: UInt64) -> [NACKAction] {
        evaluate(nowNs: nowNs)
    }

    /// True once at least one gap is being tracked (test/introspection aid).
    var hasOpenGaps: Bool { !gaps.isEmpty }

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
            toNack.sort()
            for seq in toNack {
                gaps[seq]?.attempts += 1
                gaps[seq]?.lastNackNs = nowNs
            }
            nackStampsNs.append(nowNs)
            actions.append(.sendNACK(toNack))
        }
        if abandon {
            actions.append(.sendPLI)
        }
        return actions
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
    static func packFCI(_ seqs: [UInt16]) -> [(pid: UInt16, blp: UInt16)] {
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
