import TailscreenProtocol
import XCTest

/// Differential tests for the media receive path: the shipping Swift
/// `RTPReorderBuffer` and `MultiCodecDepacketizer` against the public Go
/// SDK's ports, linked in as `libtailscreen.a` and driven through the C ABI.
///
/// Every scenario is seeded and clock-injected: both implementations consume
/// the SAME impaired delivery plan at the SAME injected times, and must
/// produce identical releases, identical access units and identical loss
/// tallies at every step. The conformance vectors pin the stateless codecs;
/// these suites pin the stateful behavior a fixed vector file cannot express
/// — gap holds, abandonment order, torn-AU accounting, wrap arithmetic.
final class MediaPathDifferentialTests: XCTestCase {

    // MARK: - Reorder buffer

    private func runReorderScenario(
        seed: UInt64, maxDepth: Int, gapHoldNs: UInt64,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var rng = SplitMix64(seed: seed)
        var swiftBuffer = RTPReorderBuffer(maxDepth: maxDepth, gapHoldNs: gapHoldNs)
        let goBuffer = GoReorderBuffer(maxDepth: maxDepth, gapHoldNs: gapHoldNs)

        // Start near the wrap so the stream crosses 65535 mid-scenario.
        let base = UInt16(65300) &+ UInt16(rng.next(upTo: 100))
        let items = (0..<1500).map { offset -> (seq: UInt16, packet: Data) in
            let seq = base &+ UInt16(offset)
            return (seq, Data([UInt8(seq >> 8), UInt8(seq & 0xFF), UInt8(truncatingIfNeeded: rng.next())]))
        }
        let deliveries = impairDelivery(
            items, rng: &rng, dropPercent: 3, duplicatePercent: 2, maxDisplacement: 6)

        var nowNs: UInt64 = 1_000_000
        for (step, delivery) in deliveries.enumerated() {
            nowNs &+= UInt64(rng.next(upTo: 3_000_000))
            let swiftReleases = swiftBuffer.push(seq: delivery.seq, packet: delivery.packet, nowNs: nowNs)
                .map { GoReorderBuffer.Release(packet: $0.packet, lostBefore: $0.lostBefore) }
            let goReleases = goBuffer.push(seq: delivery.seq, packet: delivery.packet, nowNs: nowNs)
            guard swiftReleases == goReleases else {
                XCTFail(
                    "reorder divergence at seed \(seed) step \(step) seq \(delivery.seq): "
                        + "swift released \(swiftReleases.count), go released \(goReleases.count)",
                    file: file, line: line)
                return
            }
        }
        XCTAssertEqual(
            swiftBuffer.skippedGapCount, goBuffer.skippedGapCount,
            "abandoned-gap tallies diverged at seed \(seed)", file: file, line: line)
    }

    func testReorderBufferMatchesGoInCountMode() {
        for seed: UInt64 in [1, 2024, 777_777] {
            runReorderScenario(seed: seed, maxDepth: 16, gapHoldNs: 0)
        }
        // maxDepth is literal on both sides: 0 holds nothing, so every
        // out-of-order arrival abandons its gap on the spot. Pinned here
        // because a "helpful" clamp on either side is exactly the one-sided
        // divergence this suite exists to catch.
        runReorderScenario(seed: 5, maxDepth: 0, gapHoldNs: 0)
    }

    func testReorderBufferMatchesGoInTimeHeldMode() {
        // A short hold (vs. the production 300 ms) so gaps expire — and the
        // abandonment ORDER gets compared — many times within one scenario.
        for seed: UInt64 in [3, 40_404, 987_654_321] {
            runReorderScenario(seed: seed, maxDepth: 64, gapHoldNs: 30_000_000)
        }
    }

    // MARK: - Depacketizer

    private func runDepacketizerScenario(
        seed: UInt64, hevc: Bool, reorderDepth: Int, gapHoldNs: UInt64,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var rng = SplitMix64(seed: seed)

        // Build the wire stream ONCE with the shipping packetizer (the
        // packetizers themselves are pinned by the conformance vectors), so
        // both depacketizers parse identical bytes.
        let packetize: ([Data], UInt32, UInt32, UInt16) -> [Data]
        if hevc {
            let packetizer = H265Packetizer()
            packetize = { packetizer.packetize(nals: $0, timestamp: $1, ssrc: $2, startSequence: $3) }
        } else {
            let packetizer = H264Packetizer()
            packetize = { packetizer.packetize(nals: $0, timestamp: $1, ssrc: $2, startSequence: $3) }
        }

        var packets: [Data] = []
        var seq: UInt16 = 65350  // wraps mid-stream
        var timestamp: UInt32 = 9000
        for frame in 0..<60 {
            let isIDR = frame % 10 == 0
            var nals: [Data] = []
            for nalIndex in 0..<(1 + rng.next(upTo: 3)) {
                let idr = isIDR && nalIndex == 0
                let header: [UInt8] = hevc ? [idr ? 19 << 1 : 1 << 1, 1] : [idr ? 0x65 : 0x41]
                nals.append(makeNAL(header: header, size: 2 + rng.next(upTo: 2500), rng: &rng))
            }
            let framePackets = packetize(nals, timestamp, 0x7777, seq)
            seq &+= UInt16(framePackets.count)
            timestamp &+= 3000
            packets.append(contentsOf: framePackets)
        }

        let deliveries = impairDelivery(
            packets, rng: &rng, dropPercent: 2, duplicatePercent: 2, maxDisplacement: 5)

        let swiftDepacketizer = MultiCodecDepacketizer(reorderDepth: reorderDepth, gapHoldNs: gapHoldNs)
        let goDepacketizer = GoDepacketizer(hevc: hevc, reorderDepth: reorderDepth, gapHoldNs: gapHoldNs)

        var nowNs: UInt64 = 1_000_000
        for (step, packet) in deliveries.enumerated() {
            nowNs &+= UInt64(rng.next(upTo: 2_000_000))
            var swiftAUs: [GoDepacketizer.AccessUnit] = []
            if let au = swiftDepacketizer.ingest(packet, nowNs: nowNs) {
                swiftAUs.append(differentialAU(au))
            }
            swiftAUs.append(contentsOf: swiftDepacketizer.drainReady().map(differentialAU))
            let goAUs = goDepacketizer.ingest(packet, nowNs: nowNs)
            guard swiftAUs == goAUs else {
                XCTFail(
                    "depacketizer divergence at seed \(seed) step \(step) "
                        + "(\(hevc ? "hevc" : "h264")): swift yielded \(swiftAUs.count) AUs, "
                        + "go yielded \(goAUs.count)",
                    file: file, line: line)
                return
            }
        }
        XCTAssertEqual(
            swiftDepacketizer.tornAUCount, goDepacketizer.tornAUCount,
            "torn-AU tallies diverged at seed \(seed)", file: file, line: line)
        XCTAssertEqual(
            swiftDepacketizer.skippedGapCount, goDepacketizer.skippedGapCount,
            "abandoned-gap tallies diverged at seed \(seed)", file: file, line: line)
    }

    private func differentialAU(_ au: VideoAccessUnit) -> GoDepacketizer.AccessUnit {
        GoDepacketizer.AccessUnit(
            avcc: au.avcc,
            containsIDR: au.containsIDR,
            timestamp: au.timestamp,
            lostBefore: au.lostBeforeThisAU,
            isHEVC: au.codec == .hevc)
    }

    func testH264DepacketizerMatchesGo() {
        for seed: UInt64 in [11, 22_222] {
            runDepacketizerScenario(seed: seed, hevc: false, reorderDepth: 256, gapHoldNs: 20_000_000)
        }
        runDepacketizerScenario(seed: 33, hevc: false, reorderDepth: 16, gapHoldNs: 0)
    }

    func testHEVCDepacketizerMatchesGo() {
        for seed: UInt64 in [44, 55_555] {
            runDepacketizerScenario(seed: seed, hevc: true, reorderDepth: 256, gapHoldNs: 20_000_000)
        }
        runDepacketizerScenario(seed: 66, hevc: true, reorderDepth: 16, gapHoldNs: 0)
    }
}
