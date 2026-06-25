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
    /// AUs in order. `ingest` returns at most one AU per call; `drainReady`
    /// flushes any the final packets completed in a burst.
    private static func collectAUs(_ packets: [Data], through dp: Depacketizing) -> [VideoAccessUnit] {
        var out: [VideoAccessUnit] = []
        for p in packets {
            if let au = dp.ingest(p) { out.append(au) }
        }
        out.append(contentsOf: dp.drainReady())
        return out
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

        let delivered = Self.collectAUs(received, through: H264Depacketizer())

        XCTAssertEqual(
            delivered.count, expected.count, "reordering within the window must not drop frames")
        XCTAssertFalse(
            delivered.contains { $0.lostBeforeThisAU }, "pure reordering must not be read as loss")
        assertIntactAndOrdered(delivered, expected: expected)
    }

    func testHEVCStreamSurvivesReordering() {
        let (packets, expected) = Self.buildHEVCStream(
            frameCount: 40, bytesPerFrame: 2200, ssrc: 0xBEEF)
        var channel = LossyChannel(seed: 1234, reorderWindow: 6)
        let received = channel.transmit(packets)

        let delivered = Self.collectAUs(received, through: H265Depacketizer())

        XCTAssertEqual(delivered.count, expected.count)
        XCTAssertFalse(delivered.contains { $0.lostBeforeThisAU })
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

        let delivered = Self.collectAUs(received, through: H264Depacketizer())

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

        let delivered = Self.collectAUs(received, through: H264Depacketizer())

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

        let delivered = Self.collectAUs(received, through: H264Depacketizer())

        XCTAssertGreaterThan(
            delivered.count, expected.count / 2,
            "pipeline wedged under combined impairment — \(delivered.count)/\(expected.count)")
        assertIntactAndOrdered(delivered, expected: expected)
    }
}

/// Lets `collectAUs` work against either codec depacketizer. Both already
/// expose these methods; the protocol just unifies them for the test.
private protocol Depacketizing {
    func ingest(_ packet: Data) -> VideoAccessUnit?
    func drainReady() -> [VideoAccessUnit]
}
extension H264Depacketizer: Depacketizing {}
extension H265Depacketizer: Depacketizing {}
