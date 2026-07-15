import XCTest

@testable import Tailscreen

/// End-to-end packetize → impair → depacketize coverage of the WAN failure
/// modes that loopback and local-headscale never produce (reorder / loss /
/// duplication). Deterministic (seeded `LossyChannel`), pure-logic, and
/// CI-able — this is the in-process complement to `scripts/net-impair.sh`,
/// which can only run locally because it impairs the live tsnet transport.
///
/// The load-bearing invariant in every test is **no torn frames**: every
/// delivered access unit's NAL bytes must exactly match the frame that carried
/// its timestamp. A depacketizer that stitched packets from different frames
/// together would fail that even if counts looked plausible.
final class RTPLossyChannelTests: XCTestCase {

    // MARK: - Stream builders

    /// Build `frameCount` H.264 frames, each a single distinguishable NAL whose
    /// bytes encode the frame index (so integrity can be verified), packetized
    /// with contiguous sequence numbers and a unique timestamp per frame.
    /// `bytesPerFrame` > ~1100 forces FU-A fragmentation, exercising reassembly
    /// under impairment. Returns the send-order packets and the expected NALs
    /// keyed by timestamp.
    private static func buildH264Stream(
        frameCount: Int, bytesPerFrame: Int, ssrc: UInt32
    ) -> (packets: [Data], expectedByTs: [UInt32: [Data]]) {
        let packetizer = H264Packetizer()
        var packets: [Data] = []
        var expected: [UInt32: [Data]] = [:]
        var seq: UInt16 = 0
        for i in 0..<frameCount {
            let ts = UInt32(i + 1) &* 90  // distinct, non-zero, strictly increasing
            let nalHeader: UInt8 = (i % 10 == 0) ? 0x65 : 0x41  // periodic IDR
            var nal = Data([nalHeader])
            nal.append(contentsOf: (0..<bytesPerFrame).map { UInt8((i &* 131 &+ $0) & 0xFF) })
            let framePackets = packetizer.packetize(
                nals: [nal], timestamp: ts, ssrc: ssrc, startSequence: seq)
            seq &+= UInt16(framePackets.count)
            packets.append(contentsOf: framePackets)
            expected[ts] = [nal]
        }
        return (packets, expected)
    }

    /// HEVC sibling of `buildH264Stream`. 2-byte NAL header; type 19
    /// (IDR_W_RADL) for periodic keyframes, type 1 (TRAIL_R) otherwise.
    private static func buildHEVCStream(
        frameCount: Int, bytesPerFrame: Int, ssrc: UInt32
    ) -> (packets: [Data], expectedByTs: [UInt32: [Data]]) {
        let packetizer = H265Packetizer()
        var packets: [Data] = []
        var expected: [UInt32: [Data]] = [:]
        var seq: UInt16 = 0
        for i in 0..<frameCount {
            let ts = UInt32(i + 1) &* 90
            let type: UInt8 = (i % 10 == 0) ? 19 : 1
            var nal = Data([(type & 0x3F) << 1, 0x01])  // F=0, LayerId=0, TID=1
            nal.append(contentsOf: (0..<bytesPerFrame).map { UInt8((i &* 131 &+ $0) & 0xFF) })
            let framePackets = packetizer.packetize(
                nals: [nal], timestamp: ts, ssrc: ssrc, startSequence: seq)
            seq &+= UInt16(framePackets.count)
            packets.append(contentsOf: framePackets)
            expected[ts] = [nal]
        }
        return (packets, expected)
    }

    /// Feed every packet through the depacketizer and collect all delivered
    /// AUs in order. `ingest` returns at most one AU per call; `drain` flushes
    /// any the final packets completed in a burst. Taking the two methods as
    /// closures lets this serve either codec depacketizer without a shared
    /// protocol.
    private static func collectAUs(
        _ packets: [Data],
        ingest: (Data) -> VideoAccessUnit?,
        drain: () -> [VideoAccessUnit]
    ) -> [VideoAccessUnit] {
        var out: [VideoAccessUnit] = []
        for p in packets {
            if let au = ingest(p) { out.append(au) }
        }
        out.append(contentsOf: drain())
        return out
    }

    /// Assert pure-reordering recovery: the reorder buffer anchors its
    /// sequence baseline to the *first packet it receives*, so when the stream
    /// starts out of order any genuinely-earlier packets arrive "behind" the
    /// baseline and are correctly dropped as stragglers — losing at most a
    /// short cold-start prefix (exactly what a viewer joining mid-stream sees,
    /// before a keyframe re-syncs it). After that lock, reordering within the
    /// window must drop nothing. Assert that: delivered frames are a contiguous
    /// run ending at the final frame, missing at most `maxColdStartDrop` frames
    /// at the front, none flagged as loss.
    private func assertReorderRecovered(
        _ delivered: [VideoAccessUnit], frameCount: Int, maxColdStartDrop: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let ts = delivered.map(\.timestamp)
        XCTAssertEqual(
            ts.last, UInt32(frameCount) &* 90, "stream must run to the last frame", file: file,
            line: line)
        for i in ts.indices.dropFirst() {
            XCTAssertEqual(
                ts[i], ts[i - 1] &+ 90,
                "frame dropped mid-stream — reordering within the window must not lose frames once synced",
                file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(
            delivered.count, frameCount - maxColdStartDrop, "too many frames dropped at cold start",
            file: file, line: line)
        XCTAssertFalse(
            delivered.contains { $0.lostBeforeThisAU }, "pure reordering must not be reported as loss",
            file: file, line: line)
    }

    /// Assert every delivered AU is intact (matches its frame) and strictly
    /// ordered by timestamp.
    private func assertIntactAndOrdered(
        _ delivered: [VideoAccessUnit], expected: [UInt32: [Data]], file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var lastTs: UInt32 = 0
        for au in delivered {
            XCTAssertGreaterThan(
                au.timestamp, lastTs, "frames delivered out of order", file: file, line: line)
            lastTs = au.timestamp
            guard let exp = expected[au.timestamp] else {
                XCTFail("delivered AU with unknown timestamp \(au.timestamp)", file: file, line: line)
                continue
            }
            XCTAssertEqual(
                AVCCParser.nalUnits(from: au.avcc), exp,
                "torn/garbled frame at ts=\(au.timestamp)", file: file, line: line)
        }
    }

    // MARK: - Reordering

    func testStreamSurvivesReordering() {
        // 60 multi-packet frames, reordered within an 8-packet window — well
        // inside the depacketizer's default reorder depth (16), so nothing
        // should be reported as loss and every frame should arrive intact.
        let (packets, expected) = Self.buildH264Stream(
            frameCount: 60, bytesPerFrame: 2500, ssrc: 0x1234)
        var channel = LossyChannel(seed: 42, reorderWindow: 8)
        let received = channel.transmit(packets)
        XCTAssertEqual(received.count, packets.count, "reorder-only must not change packet count")

        let dp = H264Depacketizer()
        let delivered = Self.collectAUs(received, ingest: dp.ingest, drain: dp.drainReady)

        // reorderWindow (8) bounds the cold-start prefix the buffer drops
        // before it locks onto the sequence baseline.
        assertReorderRecovered(delivered, frameCount: expected.count, maxColdStartDrop: 8)
        assertIntactAndOrdered(delivered, expected: expected)
    }

    func testHEVCStreamSurvivesReordering() {
        let (packets, expected) = Self.buildHEVCStream(
            frameCount: 40, bytesPerFrame: 2200, ssrc: 0xBEEF)
        var channel = LossyChannel(seed: 1234, reorderWindow: 6)
        let received = channel.transmit(packets)

        let dp = H265Depacketizer()
        let delivered = Self.collectAUs(received, ingest: dp.ingest, drain: dp.drainReady)

        assertReorderRecovered(delivered, frameCount: expected.count, maxColdStartDrop: 6)
        assertIntactAndOrdered(delivered, expected: expected)
    }

    // MARK: - Duplication

    func testStreamSurvivesDuplication() {
        // 30% of packets duplicated, no loss/reorder. Duplicates land on a
        // sequence number we've already passed, so they're dropped silently —
        // no frame loss, no corruption.
        let (packets, expected) = Self.buildH264Stream(
            frameCount: 40, bytesPerFrame: 1500, ssrc: 0xABCD)
        var channel = LossyChannel(seed: 7, dupRate: 0.3)
        let received = channel.transmit(packets)
        XCTAssertGreaterThan(received.count, packets.count, "duplication should add packets")

        let dp = H264Depacketizer()
        let delivered = Self.collectAUs(received, ingest: dp.ingest, drain: dp.drainReady)

        XCTAssertEqual(delivered.count, expected.count, "duplicates must not drop frames")
        XCTAssertFalse(
            delivered.contains { $0.lostBeforeThisAU }, "duplication must not be read as loss")
        assertIntactAndOrdered(delivered, expected: expected)
    }

    // MARK: - Loss

    func testStreamSurvivesLossAndSignalsIt() {
        // 3% packet loss. Some frames are torn and dropped, but the pipeline
        // must keep delivering the rest (never wedge), every *delivered* frame
        // must be intact, and the loss must be signaled so the client can PLI.
        let (packets, expected) = Self.buildH264Stream(
            frameCount: 80, bytesPerFrame: 1500, ssrc: 0x55)
        var channel = LossyChannel(seed: 99, lossRate: 0.03)
        let received = channel.transmit(packets)
        XCTAssertLessThan(received.count, packets.count, "loss should drop packets")

        let dp = H264Depacketizer()
        let delivered = Self.collectAUs(received, ingest: dp.ingest, drain: dp.drainReady)

        XCTAssertGreaterThan(
            delivered.count, expected.count / 2,
            "depacketizer wedged after loss — delivered \(delivered.count)/\(expected.count)")
        assertIntactAndOrdered(delivered, expected: expected)
        XCTAssertTrue(
            delivered.contains { $0.lostBeforeThisAU },
            "loss was never signaled to drive a PLI")
    }

    // MARK: - Combined (realistic WAN)

    func testStreamSurvivesCombinedImpairment() {
        // Loss + duplication + reordering together — the realistic
        // DERP-relayed-WAN cocktail. The pipeline must stay in sync: keep
        // delivering a healthy fraction, in order, with no torn frames.
        let (packets, expected) = Self.buildH264Stream(
            frameCount: 120, bytesPerFrame: 2500, ssrc: 0xCC)
        var channel = LossyChannel(seed: 2024, lossRate: 0.02, dupRate: 0.05, reorderWindow: 6)
        let received = channel.transmit(packets)

        let dp = H264Depacketizer()
        let delivered = Self.collectAUs(received, ingest: dp.ingest, drain: dp.drainReady)

        XCTAssertGreaterThan(
            delivered.count, expected.count / 2,
            "pipeline wedged under combined impairment — \(delivered.count)/\(expected.count)")
        assertIntactAndOrdered(delivered, expected: expected)
    }

    // MARK: - NACK closed loop

    private static func seqOf(_ packet: Data) -> UInt16 {
        RTPHeader.decode(from: packet)?.header.sequenceNumber ?? 0
    }

    private struct NACKLoopOutcome {
        var delivered: [VideoAccessUnit]
        var nacks: Int
        var plis: Int
    }

    /// Impairment + retransmit knobs for `runNACKLoop`, bundled to keep the
    /// helper's parameter list small.
    private struct NACKLoopConfig {
        var lossSeed: UInt64
        var lossRate: Double
        var rttSteps: Int
        var retransmitReliable: Bool
    }

    /// Drive packetize → loss → (`NACKScheduler` + depacketizer) → retransmit
    /// re-injection, in discrete 1 ms steps (one per arriving packet). NACKed
    /// sequence numbers are looked up in the byte-identical wire map and
    /// re-injected `rttSteps` later — unless `retransmitReliable` is false,
    /// which models a link so lossy even retransmits drop, forcing the
    /// scheduler's PLI fallback. The first packet is never dropped so the
    /// receiver's cold-start baseline is clean and every later loss is
    /// recoverable.
    private func runNACKLoop(
        packets: [Data],
        config: NACKLoopConfig,
        ingest: (Data) -> VideoAccessUnit?,
        drain: () -> [VideoAccessUnit]
    ) -> NACKLoopOutcome {
        let lossRate = config.lossRate
        let rttSteps = config.rttSteps
        let retransmitReliable = config.retransmitReliable
        var wire: [UInt16: Data] = [:]
        for packet in packets { wire[Self.seqOf(packet)] = packet }

        var scheduler = NACKScheduler()
        var rng = SeededRNG(seed: config.lossSeed)
        var delivered: [VideoAccessUnit] = []
        var pending: [Int: [Data]] = [:]
        var nacks = 0
        var plis = 0
        let stepNs: UInt64 = 1_000_000

        func handleActions(_ actions: [NACKAction], atStep step: Int) {
            for action in actions {
                switch action {
                case .sendNACK(let seqs):
                    nacks += 1
                    guard retransmitReliable else { continue }
                    for seq in seqs where wire[seq] != nil {
                        if let packet = wire[seq] {
                            pending[step + rttSteps, default: []].append(packet)
                        }
                    }
                case .sendPLI:
                    plis += 1
                }
            }
        }

        func deliver(_ packet: Data, atStep step: Int) {
            if let au = ingest(packet) { delivered.append(au) }
            let now = UInt64(step) &* stepNs
            handleActions(scheduler.observe(seq: Self.seqOf(packet), nowNs: now), atStep: step)
        }

        var step = 0
        for packet in packets {
            step += 1
            let now = UInt64(step) &* stepNs
            if let arrivals = pending.removeValue(forKey: step) {
                for retransmit in arrivals { deliver(retransmit, atStep: step) }
            }
            let lost = step > 1 && lossRate > 0 && Double.random(in: 0..<1, using: &rng) < lossRate
            if !lost { deliver(packet, atStep: step) }
            handleActions(scheduler.tick(nowNs: now), atStep: step)
        }
        // Age out remaining gaps and drain scheduled retransmits.
        let maxStep = (pending.keys.max() ?? step) + rttSteps + 2500
        while step <= maxStep {
            step += 1
            let now = UInt64(step) &* stepNs
            if let arrivals = pending.removeValue(forKey: step) {
                for retransmit in arrivals { deliver(retransmit, atStep: step) }
            }
            handleActions(scheduler.tick(nowNs: now), atStep: step)
            if pending.isEmpty && !scheduler.hasOpenGaps { break }
        }
        delivered.append(contentsOf: drain())
        return NACKLoopOutcome(delivered: delivered, nacks: nacks, plis: plis)
    }

    func testLossRecoveredByNACKWithoutPLI() {
        // 3 % loss with reliable retransmits: every gap is NACKed and refilled
        // before the reorder window overflows, so no PLI ever fires and no
        // frame is torn.
        let (packets, expected) = Self.buildH264Stream(
            frameCount: 90, bytesPerFrame: 1500, ssrc: 0x77)
        let dp = H264Depacketizer(reorderDepth: 64)
        let outcome = runNACKLoop(
            packets: packets,
            config: NACKLoopConfig(lossSeed: 12345, lossRate: 0.03, rttSteps: 4, retransmitReliable: true),
            ingest: dp.ingest, drain: dp.drainReady)

        XCTAssertGreaterThan(outcome.nacks, 0, "loss should have driven NACKs")
        XCTAssertEqual(outcome.plis, 0, "NACK recovery must not fall back to PLI at 3% loss")
        XCTAssertFalse(
            outcome.delivered.contains { $0.lostBeforeThisAU },
            "recovered loss must not surface as a loss signal")
        assertIntactAndOrdered(outcome.delivered, expected: expected)
        XCTAssertGreaterThanOrEqual(
            outcome.delivered.count, expected.count - 1,
            "NACK recovery should deliver essentially every frame")
    }

    func testHEVCLossRecoveredByNACKWithoutPLI() {
        let (packets, expected) = Self.buildHEVCStream(
            frameCount: 70, bytesPerFrame: 1500, ssrc: 0x99)
        let dp = H265Depacketizer(reorderDepth: 64)
        let outcome = runNACKLoop(
            packets: packets,
            config: NACKLoopConfig(lossSeed: 555, lossRate: 0.03, rttSteps: 4, retransmitReliable: true),
            ingest: dp.ingest, drain: dp.drainReady)

        XCTAssertGreaterThan(outcome.nacks, 0)
        XCTAssertEqual(outcome.plis, 0)
        XCTAssertFalse(outcome.delivered.contains { $0.lostBeforeThisAU })
        assertIntactAndOrdered(outcome.delivered, expected: expected)
    }

    func testNACKFallsBackToPLIWhenRetransmitsAlsoDrop() {
        // Retransmits never arrive: the scheduler must abandon each gap to a
        // PLI (never wedge), and every delivered frame must still be intact.
        let (packets, expected) = Self.buildH264Stream(
            frameCount: 90, bytesPerFrame: 1500, ssrc: 0x33)
        let dp = H264Depacketizer(reorderDepth: 64)
        let outcome = runNACKLoop(
            packets: packets,
            config: NACKLoopConfig(lossSeed: 777, lossRate: 0.04, rttSteps: 4, retransmitReliable: false),
            ingest: dp.ingest, drain: dp.drainReady)

        XCTAssertGreaterThan(outcome.plis, 0, "unrecoverable loss must fall back to PLI")
        XCTAssertGreaterThan(
            outcome.delivered.count, expected.count / 2,
            "pipeline wedged — \(outcome.delivered.count)/\(expected.count)")
        assertIntactAndOrdered(outcome.delivered, expected: expected)
    }

    func testSmallReorderProducesNoNACKsInLoop() {
        // Reordering within a 3-packet window (displacement ≤ 2, under the
        // scheduler's 3-newer-packet tolerance and 15 ms time tolerance) must
        // never trip a NACK or a PLI.
        let (packets, expected) = Self.buildH264Stream(
            frameCount: 60, bytesPerFrame: 1500, ssrc: 0x44)
        var channel = LossyChannel(seed: 4242, reorderWindow: 3)
        let received = channel.transmit(packets)
        let dp = H264Depacketizer(reorderDepth: 64)
        let outcome = runNACKLoop(
            packets: received,
            config: NACKLoopConfig(lossSeed: 1, lossRate: 0, rttSteps: 4, retransmitReliable: true),
            ingest: dp.ingest, drain: dp.drainReady)

        XCTAssertEqual(outcome.nacks, 0, "small reordering must not NACK")
        XCTAssertEqual(outcome.plis, 0, "small reordering must not PLI")
        assertIntactAndOrdered(outcome.delivered, expected: expected)
    }

    // MARK: - FEC + NACK closed loop

    private struct RecoveryLoopOutcome {
        var delivered: [VideoAccessUnit]
        var nacks: Int
        var plis: Int
        var fecRecovered: Int
    }

    /// Impairment knobs for `runRecoveryLoop`. `singleLossPerGroupRate`
    /// drops at most one member per FEC group (the FEC-solvable regime);
    /// `mediaLossRate` is unconstrained per-packet loss (multi-loss groups
    /// hand off to NACK); `parityLossRate` drops parity datagrams
    /// (parity loss must be silent and free); `lateOriginalSteps` re-delivers
    /// each dropped original that many steps later (the late-original dedup
    /// case).
    private struct RecoveryLoopConfig {
        var lossSeed: UInt64
        var singleLossPerGroupRate: Double = 0
        var mediaLossRate: Double = 0
        var parityLossRate: Double = 0
        var groupSize: Int = 10
        var rttSteps: Int = 4
        var lateOriginalSteps: Int?
    }

    /// The FEC leg of the recovery loop: the "server" side groups each
    /// frame's packets with `groupRanges` + `parityBody` (parity trails its
    /// group, exactly the broadcast send-chain ordering); the "viewer" side
    /// runs the production composition — FEC-mode `NACKScheduler` tolerances,
    /// `FECGroupBuffer` in front of the depacketizer, recovered packets
    /// ingested through the same path as received ones with `cancelGap` —
    /// with NACKed seqs re-injected byte-identically `rttSteps` later.
    private func runRecoveryLoop(
        packets: [Data],
        config: RecoveryLoopConfig,
        ingest: (Data) -> VideoAccessUnit?,
        drain: () -> [VideoAccessUnit]
    ) -> RecoveryLoopOutcome {
        // Regroup the flat stream into frames (one AU each, contiguous seqs).
        var frames: [[Data]] = []
        var lastTs: UInt32?
        for packet in packets {
            let ts = RTPHeader.decode(from: packet)?.header.timestamp ?? 0
            if ts == lastTs {
                frames[frames.count - 1].append(packet)
            } else {
                frames.append([packet])
                lastTs = ts
            }
        }
        var wire: [UInt16: Data] = [:]
        for packet in packets { wire[Self.seqOf(packet)] = packet }

        // Server side: schedule = per frame, its members then each group's
        // parity datagram; decide the dropped set up front for the
        // single-loss-per-group regime (victims only inside covered ranges,
        // never the stream's first packet, so every drop is FEC-solvable).
        enum Event {
            case media(Data)
            case parity(base: UInt16, count: Int, body: Data)
        }
        var rng = SeededRNG(seed: config.lossSeed)
        var schedule: [Event] = []
        var droppedSeqs: Set<UInt16> = []
        let firstSeq = Self.seqOf(packets[0])
        for frame in frames {
            for packet in frame { schedule.append(.media(packet)) }
            for range in FECCodec.groupRanges(templateCount: frame.count, groupSize: config.groupSize) {
                let dropOne =
                    config.singleLossPerGroupRate > 0
                    && Double.random(in: 0..<1, using: &rng) < config.singleLossPerGroupRate
                if dropOne {
                    let victim = range.lowerBound + Int(rng.next() % UInt64(range.count))
                    let seq = Self.seqOf(frame[victim])
                    if seq != firstSeq { droppedSeqs.insert(seq) }
                }
                let body = FECCodec.parityBody(for: frame[range])
                schedule.append(
                    .parity(base: Self.seqOf(frame[range.lowerBound]), count: range.count, body: body))
            }
        }

        // Viewer side.
        var scheduler = NACKScheduler(
            reorderToleranceNs: TransportTuning.fecSchedulerToleranceNs,
            reorderPacketTolerance: TransportTuning.fecSchedulerPacketTolerance)
        var fec = FECGroupBuffer()
        var delivered: [VideoAccessUnit] = []
        var pending: [Int: [Data]] = [:]
        var nacks = 0
        var plis = 0
        var recovered = 0
        var step = 0
        let stepNs: UInt64 = 1_000_000

        func handleActions(_ actions: [NACKAction], atStep step: Int) {
            for action in actions {
                switch action {
                case .sendNACK(let seqs):
                    nacks += 1
                    for seq in seqs {
                        if let packet = wire[seq] {
                            pending[step + config.rttSteps, default: []].append(packet)
                        }
                    }
                case .sendPLI:
                    plis += 1
                }
            }
        }

        func processRecovered(_ recovery: FECGroupBuffer.Recovery) {
            recovered += 1
            scheduler.cancelGap(seq: recovery.seq)
            if let au = ingest(recovery.packet) { delivered.append(au) }
        }

        func deliverMedia(_ packet: Data, atStep step: Int) {
            let now = UInt64(step) &* stepNs
            handleActions(scheduler.observe(seq: Self.seqOf(packet), nowNs: now), atStep: step)
            if let recovery = fec.noteMedia(seq: Self.seqOf(packet), packet: packet, nowNs: now) {
                processRecovered(recovery)
            }
            if let au = ingest(packet) { delivered.append(au) }
        }

        for event in schedule {
            step += 1
            let now = UInt64(step) &* stepNs
            if let arrivals = pending.removeValue(forKey: step) {
                for retransmit in arrivals { deliverMedia(retransmit, atStep: step) }
            }
            switch event {
            case .media(let packet):
                let seq = Self.seqOf(packet)
                var lost = droppedSeqs.contains(seq)
                if !lost, config.mediaLossRate > 0, seq != firstSeq {
                    lost = Double.random(in: 0..<1, using: &rng) < config.mediaLossRate
                }
                if lost {
                    if let late = config.lateOriginalSteps {
                        pending[step + late, default: []].append(packet)
                    }
                } else {
                    deliverMedia(packet, atStep: step)
                }
            case .parity(let base, let count, let body):
                let lost =
                    config.parityLossRate > 0
                    && Double.random(in: 0..<1, using: &rng) < config.parityLossRate
                if !lost, let recovery = fec.noteParity(baseSeq: base, count: count, body: body, nowNs: now) {
                    processRecovered(recovery)
                }
            }
            handleActions(scheduler.tick(nowNs: now), atStep: step)
        }
        // Drain scheduled retransmits / late originals and age out gaps.
        let maxStep = (pending.keys.max() ?? step) + config.rttSteps + 2500
        while step <= maxStep {
            step += 1
            let now = UInt64(step) &* stepNs
            if let arrivals = pending.removeValue(forKey: step) {
                for retransmit in arrivals { deliverMedia(retransmit, atStep: step) }
            }
            handleActions(scheduler.tick(nowNs: now), atStep: step)
            if pending.isEmpty && !scheduler.hasOpenGaps { break }
        }
        delivered.append(contentsOf: drain())
        return RecoveryLoopOutcome(delivered: delivered, nacks: nacks, plis: plis, fecRecovered: recovered)
    }

    func testSingleLossPerGroupRecoveredByFECWithZeroNACKs() {
        // At most one loss per FEC group: every gap is reconstructed from the
        // parity already in flight — zero NACKs, zero PLIs, zero RTT cost,
        // no frame ever flagged as lost.
        let (packets, expected) = Self.buildH264Stream(
            frameCount: 60, bytesPerFrame: 12_000, ssrc: 0xFEC1)
        let dp = H264Depacketizer(reorderDepth: 64)
        let outcome = runRecoveryLoop(
            packets: packets,
            config: RecoveryLoopConfig(lossSeed: 31337, singleLossPerGroupRate: 0.5),
            ingest: dp.ingest, drain: dp.drainReady)

        XCTAssertGreaterThan(outcome.fecRecovered, 0, "seeded losses should have exercised recovery")
        XCTAssertEqual(outcome.nacks, 0, "FEC-solvable loss must never NACK")
        XCTAssertEqual(outcome.plis, 0, "FEC-solvable loss must never PLI")
        XCTAssertFalse(
            outcome.delivered.contains { $0.lostBeforeThisAU },
            "recovered loss must not surface as a loss signal")
        XCTAssertEqual(outcome.delivered.count, expected.count, "every frame must arrive")
        assertIntactAndOrdered(outcome.delivered, expected: expected)
    }

    func testHEVCSingleLossPerGroupRecoveredByFEC() {
        let (packets, expected) = Self.buildHEVCStream(
            frameCount: 50, bytesPerFrame: 12_000, ssrc: 0xFEC2)
        let dp = H265Depacketizer(reorderDepth: 64)
        let outcome = runRecoveryLoop(
            packets: packets,
            config: RecoveryLoopConfig(lossSeed: 90210, singleLossPerGroupRate: 0.5),
            ingest: dp.ingest, drain: dp.drainReady)

        XCTAssertGreaterThan(outcome.fecRecovered, 0)
        XCTAssertEqual(outcome.nacks, 0)
        XCTAssertEqual(outcome.plis, 0)
        XCTAssertFalse(outcome.delivered.contains { $0.lostBeforeThisAU })
        XCTAssertEqual(outcome.delivered.count, expected.count)
        assertIntactAndOrdered(outcome.delivered, expected: expected)
    }

    func testHeavyLossFallsBackToNACKBeyondFEC() {
        // ~10 % unconstrained loss: FEC closes the single-loss groups
        // (recovered > 0) while multi-loss groups hand off to NACK
        // (nacks > 0) — the layered handoff — and no frame is ever torn.
        let (packets, expected) = Self.buildH264Stream(
            frameCount: 90, bytesPerFrame: 12_000, ssrc: 0xFEC3)
        let dp = H264Depacketizer(reorderDepth: 64)
        let outcome = runRecoveryLoop(
            packets: packets,
            config: RecoveryLoopConfig(lossSeed: 424242, mediaLossRate: 0.10, parityLossRate: 0.10),
            ingest: dp.ingest, drain: dp.drainReady)

        XCTAssertGreaterThan(outcome.fecRecovered, 0, "single-loss groups should solve via FEC")
        XCTAssertGreaterThan(outcome.nacks, 0, "multi-loss groups must hand off to NACK")
        assertIntactAndOrdered(outcome.delivered, expected: expected)
        XCTAssertGreaterThanOrEqual(
            outcome.delivered.count, expected.count - 1,
            "layered FEC+NACK recovery should deliver essentially every frame")
    }

    func testParityLossIsHarmless() {
        // Drop EVERY parity datagram, 3 % media loss: outcome must be
        // exactly today's NACK behavior — parity rides the control plane,
        // so losing it opens no gap, costs no NACK, pollutes no RR.
        let (packets, expected) = Self.buildH264Stream(
            frameCount: 90, bytesPerFrame: 1500, ssrc: 0xFEC4)
        let dp = H264Depacketizer(reorderDepth: 64)
        let outcome = runRecoveryLoop(
            packets: packets,
            config: RecoveryLoopConfig(lossSeed: 12345, mediaLossRate: 0.03, parityLossRate: 1.0),
            ingest: dp.ingest, drain: dp.drainReady)

        XCTAssertEqual(outcome.fecRecovered, 0, "no parity, no recoveries")
        XCTAssertGreaterThan(outcome.nacks, 0, "loss should have driven NACKs")
        XCTAssertEqual(outcome.plis, 0, "NACK still recovers everything at 3% loss")
        XCTAssertFalse(outcome.delivered.contains { $0.lostBeforeThisAU })
        assertIntactAndOrdered(outcome.delivered, expected: expected)
        XCTAssertGreaterThanOrEqual(outcome.delivered.count, expected.count - 1)
    }

    func testLateOriginalAfterFECRecoveryIsHarmless() {
        // Each "lost" packet was merely reordered: it arrives 12 steps later,
        // AFTER its FEC recovery. The duplicate must change nothing — no
        // duplicate AU (strict timestamp ordering catches one), no NACK, no
        // PLI, no scheduler regression.
        let (packets, expected) = Self.buildH264Stream(
            frameCount: 60, bytesPerFrame: 12_000, ssrc: 0xFEC5)
        let dp = H264Depacketizer(reorderDepth: 64)
        let outcome = runRecoveryLoop(
            packets: packets,
            config: RecoveryLoopConfig(
                lossSeed: 777, singleLossPerGroupRate: 0.5, lateOriginalSteps: 12),
            ingest: dp.ingest, drain: dp.drainReady)

        XCTAssertGreaterThan(outcome.fecRecovered, 0)
        XCTAssertEqual(outcome.nacks, 0, "the late original must not provoke a NACK")
        XCTAssertEqual(outcome.plis, 0)
        XCTAssertEqual(outcome.delivered.count, expected.count, "no duplicate or missing AUs")
        assertIntactAndOrdered(outcome.delivered, expected: expected)
    }
}
