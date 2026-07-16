import Foundation

/// Receiver-side FEC state: a bounded ring of recently received video packets
/// plus briefly-buffered parity datagrams, solved via `FECCodec.recover` the
/// moment a group has exactly one member missing. Sits in front of the
/// depacketizer on the client's receive task (owned like `nackScheduler`).
///
/// Pure and deterministic — no I/O, no wall clock (the caller injects
/// `nowNs`) — so `FECGroupBufferTests` pins every path on CI. Plain
/// `Sendable` value type; the receive task is the only mutator.
public struct FECGroupBuffer: Sendable {
    /// A parity datagram whose group wasn't solvable on arrival (≥ 2 members
    /// missing, or members not yet seen — parity can outrun a reordered
    /// member). Held for one reorder tolerance, then discarded: multi-loss
    /// groups belong to NACK.
    private struct PendingParity {
        let baseSeq: UInt16
        let count: Int
        let body: Data
        let firstSeenNs: UInt64
    }

    /// Cap on retained media bytes. ~4 groups of keyframe-sized packets
    /// (~11 KB per N = 10 group) fit comfortably; keyframe bursts too.
    public let maxHeldBytes: Int
    /// Hard cap on retained media packets (second bound alongside bytes).
    public let maxHeldPackets: Int
    /// How long an unsolvable parity lingers waiting for reordered members.
    public let parityLingerNs: UInt64
    /// Cap on buffered parities (a keyframe burst holds a handful at most).
    public let maxPendingParities: Int
    /// Cap on the recovered-seq guard set (at-most-once recovery per seq).
    public let maxRecoveredGuard: Int

    /// Recently received media packets keyed by sequence number.
    private var held: [UInt16: Data] = [:]
    /// Insertion order of `held` keys, for oldest-first eviction.
    private var heldOrder: [UInt16] = []
    private var heldBytes = 0
    private var pending: [PendingParity] = []
    /// Sequence numbers already recovered once — a late original after
    /// recovery must not be double-fed by us (the original itself still
    /// flows to the depacketizer, whose reorder buffer drops it as a
    /// behind-us duplicate, same as any network dup).
    private var recovered: [UInt16] = []
    private var recoveredSet: Set<UInt16> = []

    public init(
        maxHeldBytes: Int = 256 * 1024,
        maxHeldPackets: Int = 512,
        parityLingerNs: UInt64 = 25_000_000,
        maxPendingParities: Int = 16,
        maxRecoveredGuard: Int = 256
    ) {
        self.maxHeldBytes = maxHeldBytes
        self.maxHeldPackets = maxHeldPackets
        self.parityLingerNs = parityLingerNs
        self.maxPendingParities = maxPendingParities
        self.maxRecoveredGuard = maxRecoveredGuard
    }

    /// One recovered packet, ready for the shared video-ingest path.
    public struct Recovery: Equatable {
        let seq: UInt16
        let packet: Data
    }

    /// Retain one received video packet and re-check any buffered parity
    /// whose group it may have just made solvable (parity-before-member
    /// reordering). Returns a recovery if one solved.
    public mutating func noteMedia(seq: UInt16, packet: Data, nowNs: UInt64) -> Recovery? {
        if held[seq] == nil {
            held[seq] = packet
            heldOrder.append(seq)
            heldBytes += packet.count
            evictHeldIfNeeded()
        }
        return solvePending(nowNs: nowNs)
    }

    /// Ingest one parity datagram. Solves immediately when exactly one group
    /// member is missing; drops it when none are; buffers it briefly (one
    /// reorder tolerance) when ≥ 2 are — NACK owns multi-loss groups.
    public mutating func noteParity(baseSeq: UInt16, count: Int, body: Data, nowNs: UInt64) -> Recovery? {
        purgeAgedParities(nowNs: nowNs)
        let parity = PendingParity(baseSeq: baseSeq, count: count, body: body, firstSeenNs: nowNs)
        if let recovery = trySolve(parity) {
            return recovery
        }
        if missingSeqs(baseSeq: baseSeq, count: count).isEmpty {
            return nil  // fully received — parity has nothing to add
        }
        pending.append(parity)
        if pending.count > maxPendingParities {
            pending.removeFirst(pending.count - maxPendingParities)
        }
        return nil
    }

    /// Reset for a fresh session.
    public mutating func reset() {
        held.removeAll(keepingCapacity: true)
        heldOrder.removeAll(keepingCapacity: true)
        heldBytes = 0
        pending.removeAll(keepingCapacity: true)
        recovered.removeAll(keepingCapacity: true)
        recoveredSet.removeAll(keepingCapacity: true)
    }

    // MARK: - Internals

    private func missingSeqs(baseSeq: UInt16, count: Int) -> [UInt16] {
        var missing: [UInt16] = []
        var seq = baseSeq
        for _ in 0..<count {
            if held[seq] == nil { missing.append(seq) }
            seq &+= 1
        }
        return missing
    }

    /// Attempt to solve one parity's group. Returns a recovery when exactly
    /// one member is missing, that member wasn't already recovered, and the
    /// XOR solve is internally consistent.
    private mutating func trySolve(_ parity: PendingParity) -> Recovery? {
        let missing = missingSeqs(baseSeq: parity.baseSeq, count: parity.count)
        guard missing.count == 1, let missingSeq = missing.first else { return nil }
        guard !recoveredSet.contains(missingSeq) else { return nil }

        var members: [Data] = []
        members.reserveCapacity(parity.count - 1)
        var ssrc: UInt32 = 0
        var seq = parity.baseSeq
        for _ in 0..<parity.count {
            if let member = held[seq] {
                members.append(member)
                if ssrc == 0, let (header, _) = RTPHeader.decode(from: member) {
                    ssrc = header.ssrc
                }
            }
            seq &+= 1
        }
        guard
            let packet = FECCodec.recover(
                missingSeq: missingSeq, ssrc: ssrc, members: members, body: parity.body)
        else { return nil }

        markRecovered(missingSeq)
        // The recovered packet joins the held set like a received one, so a
        // hypothetical overlapping parity sees a complete group (and drops).
        if held[missingSeq] == nil {
            held[missingSeq] = packet
            heldOrder.append(missingSeq)
            heldBytes += packet.count
            evictHeldIfNeeded()
        }
        return Recovery(seq: missingSeq, packet: packet)
    }

    /// Re-run buffered parities after a media arrival: solve the first group
    /// that just became one-missing, drop every fully-received parity, and
    /// keep the rest — a single scan over a rebuilt array, so removing a
    /// satisfied parity never skips or delays the others. At most one
    /// recovery per call (a media packet belongs to exactly one group per
    /// batch, so one arrival can complete at most one group).
    private mutating func solvePending(nowNs: UInt64) -> Recovery? {
        purgeAgedParities(nowNs: nowNs)
        guard !pending.isEmpty else { return nil }
        var recovery: Recovery?
        var remaining: [PendingParity] = []
        remaining.reserveCapacity(pending.count)
        for parity in pending {
            if recovery == nil, let solved = trySolve(parity) {
                recovery = solved  // consumed — not retained
                continue
            }
            if missingSeqs(baseSeq: parity.baseSeq, count: parity.count).isEmpty {
                continue  // fully received — parity has nothing left to add
            }
            remaining.append(parity)
        }
        pending = remaining
        return recovery
    }

    private mutating func purgeAgedParities(nowNs: UInt64) {
        pending.removeAll { nowNs &- $0.firstSeenNs > parityLingerNs }
    }

    private mutating func markRecovered(_ seq: UInt16) {
        recovered.append(seq)
        recoveredSet.insert(seq)
        if recovered.count > maxRecoveredGuard {
            let evicted = recovered.removeFirst()
            recoveredSet.remove(evicted)
        }
    }

    private mutating func evictHeldIfNeeded() {
        while heldBytes > maxHeldBytes || heldOrder.count > maxHeldPackets {
            guard !heldOrder.isEmpty else { return }
            let seq = heldOrder.removeFirst()
            if let packet = held.removeValue(forKey: seq) {
                heldBytes -= packet.count
            }
        }
    }
}
