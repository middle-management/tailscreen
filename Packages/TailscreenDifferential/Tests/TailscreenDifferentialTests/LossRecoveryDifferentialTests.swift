import TailscreenProtocol
import XCTest

/// Differential tests for the loss-recovery machinery: the shipping Swift
/// `NACKScheduler`, `FECGroupBuffer` and `RRAccounting` against the public Go
/// SDK's ports, linked in as `libtailscreen.a` and driven through the C ABI.
/// Seeded, clock-injected, compared at every step — see
/// `MediaPathDifferentialTests` for the shape's rationale.
final class LossRecoveryDifferentialTests: XCTestCase {

    // MARK: - NACK scheduler

    private func repr(_ actions: [NACKAction]) -> [DifferentialNACKAction] {
        actions.map { (action) -> DifferentialNACKAction in
            switch action {
            case .sendNACK(let seqs): return .nack(seqs)
            case .sendPLI: return .pli
            }
        }
    }

    private func runNACKScenario(
        seed: UInt64, file: StaticString = #filePath, line: UInt = #line
    ) {
        var rng = SplitMix64(seed: seed)
        var swiftScheduler = NACKScheduler()
        let goScheduler = GoNACKScheduler()

        var nextSeq = UInt16(65450) &+ UInt16(rng.next(upTo: 50))
        var nowNs: UInt64 = 5_000_000
        var openGaps: [UInt16] = []
        var fecMode = false

        for step in 0..<4000 {
            nowNs &+= UInt64(rng.next(upTo: 4_000_000))
            let roll = rng.next(upTo: 100)
            var swiftActions: [DifferentialNACKAction] = []
            var goActions: [DifferentialNACKAction] = []

            if roll < 60 {
                // In-order arrival.
                let seq = nextSeq
                nextSeq &+= 1
                swiftActions = repr(swiftScheduler.observe(seq: seq, nowNs: nowNs))
                goActions = goScheduler.observe(seq: seq, nowNs: nowNs)
            } else if roll < 70 {
                // Loss: skip one to three sequences, then observe past them.
                for _ in 0..<(1 + rng.next(upTo: 3)) {
                    openGaps.append(nextSeq)
                    nextSeq &+= 1
                }
                let seq = nextSeq
                nextSeq &+= 1
                swiftActions = repr(swiftScheduler.observe(seq: seq, nowNs: nowNs))
                goActions = goScheduler.observe(seq: seq, nowNs: nowNs)
            } else if roll < 82 {
                swiftActions = repr(swiftScheduler.tick(nowNs: nowNs))
                goActions = goScheduler.tick(nowNs: nowNs)
            } else if roll < 87, !openGaps.isEmpty {
                // A retransmit landed.
                let seq = openGaps.remove(at: rng.next(upTo: openGaps.count))
                swiftScheduler.cancelGap(seq: seq)
                goScheduler.cancelGap(seq: seq)
            } else if roll < 91, !openGaps.isEmpty {
                // FEC recovered the gap.
                let seq = openGaps.remove(at: rng.next(upTo: openGaps.count))
                swiftScheduler.noteRecovered(seq: seq, nowNs: nowNs)
                goScheduler.noteRecovered(seq: seq, nowNs: nowNs)
            } else if roll < 93 {
                // FEC mode toggles the tolerances in place (TS-FEC-013).
                fecMode.toggle()
                let toleranceNs: UInt64 = fecMode ? 25_000_000 : NACKScheduler.defaultReorderToleranceNs
                let packetTolerance = fecMode ? 12 : NACKScheduler.defaultReorderPacketTolerance
                swiftScheduler.setReorderTolerances(
                    toleranceNs: toleranceNs, packetTolerance: packetTolerance)
                goScheduler.setReorderTolerances(
                    toleranceNs: toleranceNs, packetTolerance: packetTolerance)
            } else if roll < 95 {
                XCTAssertEqual(
                    swiftScheduler.drainNackRecovered(), goScheduler.drainNackRecovered(),
                    "recovered-fill counters diverged at seed \(seed) step \(step)",
                    file: file, line: line)
            } else if roll < 96 {
                // Stream discontinuity: a jump wider than the tracked-gap
                // bound is answered with a PLI, not thousands of gaps.
                nextSeq &+= 400
                openGaps.removeAll()
                let seq = nextSeq
                nextSeq &+= 1
                swiftActions = repr(swiftScheduler.observe(seq: seq, nowNs: nowNs))
                goActions = goScheduler.observe(seq: seq, nowNs: nowNs)
            } else {
                XCTAssertEqual(
                    swiftScheduler.rttEstimateNs, goScheduler.rttEstimateNs,
                    "RTT estimates diverged at seed \(seed) step \(step)", file: file, line: line)
                XCTAssertEqual(
                    swiftScheduler.hasOpenGaps, goScheduler.hasOpenGaps,
                    "open-gap state diverged at seed \(seed) step \(step)", file: file, line: line)
            }

            guard swiftActions == goActions else {
                XCTFail(
                    "NACK divergence at seed \(seed) step \(step): "
                        + "swift \(swiftActions), go \(goActions)",
                    file: file, line: line)
                return
            }
        }

        XCTAssertEqual(
            swiftScheduler.rttEstimateNs, goScheduler.rttEstimateNs,
            "final RTT estimates diverged at seed \(seed)", file: file, line: line)
        XCTAssertEqual(
            swiftScheduler.drainNackRecovered(), goScheduler.drainNackRecovered(),
            "final recovered-fill counters diverged at seed \(seed)", file: file, line: line)
    }

    func testNACKSchedulerMatchesGo() {
        for seed: UInt64 in [7, 31_337, 5_551_212] {
            runNACKScenario(seed: seed)
        }
    }

    // MARK: - FCI packing

    func testFCIPackingMatchesGo() {
        // The pinned wrap-splitting behavior first: PackFCI sorts numerically
        // (NOT wrap-aware) on both sides — the wart is identical on purpose.
        let wrapSpan: [UInt16] = [65534, 65535, 0, 1]
        let swiftWrap = NACKScheduler.packFCI(wrapSpan)
        let goWrap = goPackFCI(wrapSpan)
        XCTAssertEqual(swiftWrap.count, goWrap.count, "wrap-span entry counts diverged")
        for (swiftEntry, goEntry) in zip(swiftWrap, goWrap) {
            XCTAssertEqual(swiftEntry.pid, goEntry.pid)
            XCTAssertEqual(swiftEntry.blp, goEntry.blp)
        }

        var rng = SplitMix64(seed: 99)
        for trial in 0..<300 {
            let base = UInt16(truncatingIfNeeded: rng.next())
            let seqs = (0..<(1 + rng.next(upTo: 40))).map { _ in
                base &+ UInt16(rng.next(upTo: 600))
            }

            let swiftPacked = NACKScheduler.packFCI(seqs)
            let goPacked = goPackFCI(seqs)
            guard swiftPacked.count == goPacked.count,
                zip(swiftPacked, goPacked).allSatisfy({ $0.pid == $1.pid && $0.blp == $1.blp })
            else {
                XCTFail("packFCI divergence at trial \(trial): seqs \(seqs)")
                return
            }

            let maxEntries = 1 + rng.next(upTo: 16)
            let swiftCapped = NACKScheduler.fciCappedSeqs(seqs, maxEntries: maxEntries)
            let goCapped = goFCICappedSeqs(seqs, maxEntries: maxEntries)
            guard swiftCapped == goCapped else {
                XCTFail("fciCappedSeqs divergence at trial \(trial): seqs \(seqs), cap \(maxEntries)")
                return
            }
        }
    }

    // MARK: - FEC group buffer

    private func runFECScenario(
        seed: UInt64, file: StaticString = #filePath, line: UInt = #line
    ) {
        enum GroupEvent {
            case media(UInt16, Data)
            case parity
        }

        var rng = SplitMix64(seed: seed)
        var swiftBuffer = FECGroupBuffer()
        let goBuffer = GoFECGroupBuffer()
        let packetizer = H264Packetizer()

        var seq: UInt16 = 65480  // wraps a few groups in
        var timestamp: UInt32 = 900
        var nowNs: UInt64 = 1_000_000

        for group in 0..<60 {
            // One frame per group, sized so every group spans ≥ 2 packets.
            var nals: [Data] = []
            for nalIndex in 0..<(1 + rng.next(upTo: 2)) {
                nals.append(
                    makeNAL(
                        header: [nalIndex == 0 ? 0x65 : 0x41],
                        size: 1200 + rng.next(upTo: 2000), rng: &rng))
            }
            let packets = packetizer.packetize(
                nals: nals, timestamp: timestamp, ssrc: 0x1234, startSequence: seq)
            let baseSeq = seq
            seq &+= UInt16(packets.count)
            timestamp &+= 3000
            let parityBody = FECCodec.parityBody(for: packets[...])

            // Drop 0–2 members, deliver survivors and the parity (sometimes
            // duplicated) in an impaired order.
            var events: [(slot: Int, tiebreak: Int, event: GroupEvent)] = []
            var tiebreak = 0
            let dropCount = [0, 0, 0, 1, 1, 2][rng.next(upTo: 6)]
            var dropped = Set<Int>()
            while dropped.count < min(dropCount, packets.count) {
                dropped.insert(rng.next(upTo: packets.count))
            }
            for (index, packet) in packets.enumerated() where !dropped.contains(index) {
                events.append(
                    (index + rng.next(upTo: 4), tiebreak, .media(baseSeq &+ UInt16(index), packet)))
                tiebreak += 1
            }
            events.append((rng.next(upTo: packets.count + 4), tiebreak, .parity))
            tiebreak += 1
            if rng.chance(15) {
                events.append((rng.next(upTo: packets.count + 6), tiebreak, .parity))
                tiebreak += 1
            }
            events.sort { ($0.slot, $0.tiebreak) < ($1.slot, $1.tiebreak) }

            for (step, entry) in events.enumerated() {
                nowNs &+= UInt64(rng.next(upTo: 3_000_000))
                if rng.chance(4) {
                    nowNs &+= 30_000_000  // occasionally age buffered parities out
                }
                let swiftRecovery: GoFECGroupBuffer.Recovery?
                let goRecovery: GoFECGroupBuffer.Recovery?
                switch entry.event {
                case .media(let mediaSeq, let packet):
                    swiftRecovery = swiftBuffer.noteMedia(seq: mediaSeq, packet: packet, nowNs: nowNs)
                        .map { GoFECGroupBuffer.Recovery(seq: $0.seq, packet: $0.packet) }
                    goRecovery = goBuffer.noteMedia(seq: mediaSeq, packet: packet, nowNs: nowNs)
                case .parity:
                    let noted = swiftBuffer.noteParity(
                        baseSeq: baseSeq, count: packets.count, body: parityBody, nowNs: nowNs)
                    swiftRecovery = noted.map { GoFECGroupBuffer.Recovery(seq: $0.seq, packet: $0.packet) }
                    goRecovery = goBuffer.noteParity(
                        baseSeq: baseSeq, count: packets.count, body: parityBody, nowNs: nowNs)
                }
                guard swiftRecovery == goRecovery else {
                    XCTFail(
                        "FEC divergence at seed \(seed) group \(group) step \(step): "
                            + "swift \(String(describing: swiftRecovery?.seq)), "
                            + "go \(String(describing: goRecovery?.seq))",
                        file: file, line: line)
                    return
                }
            }

            // Late originals of the dropped members: after a recovery the
            // at-most-once guard must hold identically.
            for index in dropped.sorted() where rng.chance(50) {
                nowNs &+= UInt64(rng.next(upTo: 2_000_000))
                let lateSeq = baseSeq &+ UInt16(index)
                let noted = swiftBuffer.noteMedia(seq: lateSeq, packet: packets[index], nowNs: nowNs)
                let swiftRecovery = noted.map { GoFECGroupBuffer.Recovery(seq: $0.seq, packet: $0.packet) }
                let goRecovery = goBuffer.noteMedia(seq: lateSeq, packet: packets[index], nowNs: nowNs)
                guard swiftRecovery == goRecovery else {
                    XCTFail(
                        "FEC late-original divergence at seed \(seed) group \(group) seq \(lateSeq)",
                        file: file, line: line)
                    return
                }
            }
        }
    }

    func testFECGroupBufferMatchesGo() {
        for seed: UInt64 in [17, 8_888, 123_456_789] {
            runFECScenario(seed: seed)
        }
    }

    // MARK: - Receiver-report accounting

    private func runRRScenario(
        seed: UInt64, file: StaticString = #filePath, line: UInt = #line
    ) {
        var rng = SplitMix64(seed: seed)
        var swiftAccounting = RRAccounting()
        let goAccounting = GoRRAccounting()

        XCTAssertEqual(
            swiftAccounting.hasBaseline, goAccounting.hasBaseline, file: file, line: line)
        XCTAssertNil(swiftAccounting.makeReport(), file: file, line: line)
        XCTAssertNil(goAccounting.makeReport()?.fracLostQ8, file: file, line: line)

        // The model stream runs in extended (monotone) space and truncates to
        // 16 bits on the wire, so wraps fall out naturally.
        var ext: Int64 = 65500
        var delivered: [Int64] = []

        func observeBoth(_ value: Int64) {
            let seq = UInt16(truncatingIfNeeded: value)
            swiftAccounting.observe(seq: seq)
            goAccounting.observe(seq: seq)
        }

        for step in 0..<6000 {
            let roll = rng.next(upTo: 100)
            if roll < 80 {
                // In-order advance, with a few percent silently lost.
                if !rng.chance(4) {
                    observeBoth(ext)
                    delivered.append(ext)
                }
                ext += 1
            } else if roll < 88, !delivered.isEmpty {
                // Duplicate of a recent arrival.
                let back = rng.next(upTo: min(delivered.count, 300))
                observeBoth(delivered[delivered.count - 1 - back])
            } else if roll < 93 {
                // Straggler / late fill, sometimes beyond the dedupe window.
                observeBoth(ext - Int64(rng.next(upTo: 6000)))
            } else if roll < 95 {
                // Forward jump, sometimes wider than the dedupe window.
                ext += Int64(rng.next(upTo: 5000))
            } else {
                let swiftReport = swiftAccounting.makeReport()
                let goReport = goAccounting.makeReport()
                guard swiftReport?.fracLostQ8 == goReport?.fracLostQ8,
                    swiftReport?.extHighestSeq == goReport?.extHighestSeq
                else {
                    XCTFail(
                        "RR divergence at seed \(seed) step \(step): "
                            + "swift \(String(describing: swiftReport)), "
                            + "go \(String(describing: goReport))",
                        file: file, line: line)
                    return
                }
            }
            if delivered.count > 400 {
                delivered.removeFirst(delivered.count - 400)
            }
        }

        let swiftReport = swiftAccounting.makeReport()
        let goReport = goAccounting.makeReport()
        XCTAssertEqual(
            swiftReport?.fracLostQ8, goReport?.fracLostQ8,
            "final loss fractions diverged at seed \(seed)", file: file, line: line)
        XCTAssertEqual(
            swiftReport?.extHighestSeq, goReport?.extHighestSeq,
            "final extended-highest values diverged at seed \(seed)", file: file, line: line)
    }

    func testRRAccountingMatchesGo() {
        for seed: UInt64 in [23, 424_242, 999_999_937] {
            runRRScenario(seed: seed)
        }
    }

    func testExtendSeqMatchesGo() {
        let pinned: [(UInt16, Int64)] = [(2, 65535), (65533, 65538), (100, 100), (65533, 5)]
        for (seq, near) in pinned {
            XCTAssertEqual(
                RRAccounting.extend(seq: seq, near: near), goExtendSeq(seq, near: near),
                "extend(\(seq), near: \(near)) diverged")
        }
        var rng = SplitMix64(seed: 4242)
        for _ in 0..<2000 {
            let seq = UInt16(truncatingIfNeeded: rng.next())
            let near = Int64(rng.next(upTo: 10_000_000)) - 100_000
            guard RRAccounting.extend(seq: seq, near: near) == goExtendSeq(seq, near: near) else {
                XCTFail("extend(\(seq), near: \(near)) diverged")
                return
            }
        }
    }
}
