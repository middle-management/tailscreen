import XCTest

@testable import Tailscreen

/// Nightly long-run soak tier (`.github/workflows/soak.yml`). Self-skips
/// unless `TAILSCREEN_SOAK=1`, so `make test` and PR CI never pay for it.
///
/// Two sweeps, both fully deterministic:
///
///   1. The `ParserFuzzTests` harness at ~50× the PR iteration budget.
///   2. The `RTPLossyChannelTests` pipeline (packetize → `LossyChannel` →
///      depacketize) over a seeded impairment matrix — every case derives its
///      seed from its matrix coordinates (never the clock), so a red nightly
///      names the exact reproducing configuration in the failure message.
final class SoakTests: XCTestCase {
    private func skipUnlessSoak() throws {
        guard ProcessInfo.processInfo.environment["TAILSCREEN_SOAK"] == "1" else {
            throw XCTSkip("SoakTests run only with TAILSCREEN_SOAK=1 (nightly soak workflow)")
        }
    }

    func testParserFuzzLongRun() throws {
        try skipUnlessSoak()
        ParserFuzzHarness(multiplier: 50).runAll()
    }

    func testLossyChannelSeededMatrix() throws {
        try skipUnlessSoak()
        let seedCount = 64
        let lossRates = [0.01, 0.03, 0.10, 0.30]
        let reorderWindows = [0, 4, 16]
        let dupRates = [0.0, 0.05]
        for seedIndex in 0..<seedCount {
            for (lossIndex, loss) in lossRates.enumerated() {
                for (reorderIndex, reorder) in reorderWindows.enumerated() {
                    for (dupIndex, dup) in dupRates.enumerated() {
                        // Seed from the matrix coordinates — reproducible by
                        // construction, and printed on failure.
                        let seed =
                            0x50A6_0000_0000_0000
                            &+ UInt64(seedIndex) &* 1_000_000
                            &+ UInt64(lossIndex) &* 10_000
                            &+ UInt64(reorderIndex) &* 100
                            &+ UInt64(dupIndex)
                        let config =
                            "seed=\(seed) loss=\(loss) reorder=\(reorder) dup=\(dup) "
                            + "hevc=\(seedIndex % 2 == 1)"
                        runImpairedPipeline(
                            seed: seed, loss: loss, reorderWindow: reorder, dup: dup,
                            useHEVC: seedIndex % 2 == 1, config: config)
                    }
                }
            }
        }
    }

    /// One matrix cell: build a distinguishable stream, impair it, feed the
    /// real depacketizer, and assert the recovery invariants — every
    /// delivered AU is byte-intact (no torn frames), delivery is strictly
    /// ordered, and the pipeline never wedges (structurally: the loop ends).
    private func runImpairedPipeline(
        seed: UInt64, loss: Double, reorderWindow: Int, dup: Double,
        useHEVC: Bool, config: String
    ) {
        let frameCount = 60
        let bytesPerFrame = 1400  // > 1100 forces FU fragmentation
        var expectedByTs: [UInt32: Data] = [:]
        var packets: [Data] = []
        var seq: UInt16 = 0
        let h264 = H264Packetizer()
        let h265 = H265Packetizer()
        for i in 0..<frameCount {
            let ts = UInt32(i + 1) &* 3000
            var nal: Data
            if useHEVC {
                nal = Data([UInt8(i % 10 == 0 ? 19 : 1) << 1, 0x01])
            } else {
                nal = Data([i % 10 == 0 ? 0x65 : 0x41])
            }
            nal.append(contentsOf: (0..<bytesPerFrame).map { UInt8((i &* 131 &+ $0) & 0xFF) })
            let framePackets =
                useHEVC
                ? h265.packetize(nals: [nal], timestamp: ts, ssrc: 0xABCD, startSequence: seq)
                : h264.packetize(nals: [nal], timestamp: ts, ssrc: 0xABCD, startSequence: seq)
            seq &+= UInt16(framePackets.count)
            packets.append(contentsOf: framePackets)
            expectedByTs[ts] = nal
        }

        var channel = LossyChannel(
            seed: seed, lossRate: loss, dupRate: dup, reorderWindow: reorderWindow)
        let received = channel.transmit(packets)

        var delivered: [VideoAccessUnit] = []
        if useHEVC {
            let depacketizer = H265Depacketizer()
            for packet in received {
                if let au = depacketizer.ingest(packet) { delivered.append(au) }
            }
            delivered.append(contentsOf: depacketizer.drainReady())
        } else {
            let depacketizer = H264Depacketizer()
            for packet in received {
                if let au = depacketizer.ingest(packet) { delivered.append(au) }
            }
            delivered.append(contentsOf: depacketizer.drainReady())
        }

        var lastTs: UInt32 = 0
        for au in delivered {
            XCTAssertGreaterThan(
                au.timestamp, lastTs, "AUs must deliver in strictly increasing ts order (\(config))")
            lastTs = au.timestamp
            guard let expected = expectedByTs[au.timestamp] else {
                XCTFail("delivered AU with unknown timestamp \(au.timestamp) (\(config))")
                continue
            }
            let nals = AVCCParser.nalUnits(from: au.avcc)
            XCTAssertEqual(nals.count, 1, "one NAL per frame in this stream (\(config))")
            XCTAssertEqual(nals.first, expected, "torn frame — NAL bytes differ (\(config))")
        }
    }
}
