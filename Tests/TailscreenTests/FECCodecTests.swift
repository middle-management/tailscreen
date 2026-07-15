import XCTest

@testable import Tailscreen

/// Pure tests for the XOR single-parity codec: parity/recover round trips for
/// every position in a group (the last packet carries the marker bit — its
/// reconstruction is load-bearing, see the timestamp-change corruption path
/// in the depacketizers), mixed packet lengths, HEVC payloads, sequence
/// wrap-around, the group-packing rule, and malformed-input rejection.
final class FECCodecTests: XCTestCase {

    /// Packetize one H.264 access unit of mixed-size NALs (so packet lengths
    /// differ — the `len`-word truncation must recover each exactly).
    private func h264Group(startSeq: UInt16 = 100, ssrc: UInt32 = 0xABCD, ts: UInt32 = 9000) -> [Data] {
        let packetizer = H264Packetizer()
        let nals = [
            Data([0x65] + (0..<400).map { UInt8($0 & 0xFF) }),
            Data([0x41] + (0..<900).map { UInt8(($0 &* 7) & 0xFF) }),
            Data([0x41] + (0..<2500).map { UInt8(($0 &* 13) & 0xFF) }),  // FU-A fragments
            Data([0x41, 0x01, 0x02])
        ]
        return packetizer.packetize(nals: nals, timestamp: ts, ssrc: ssrc, startSequence: startSeq)
    }

    private func hevcGroup(startSeq: UInt16 = 7, ssrc: UInt32 = 0xBEEF, ts: UInt32 = 1800) -> [Data] {
        let packetizer = H265Packetizer()
        let nals = [
            Data([19 << 1, 0x01] + (0..<300).map { UInt8($0 & 0xFF) }),
            Data([1 << 1, 0x01] + (0..<2000).map { UInt8(($0 &* 3) & 0xFF) }),
            Data([1 << 1, 0x01] + (0..<50).map { UInt8(($0 &* 11) & 0xFF) })
        ]
        return packetizer.packetize(nals: nals, timestamp: ts, ssrc: ssrc, startSequence: startSeq)
    }

    private func seqOf(_ packet: Data) -> UInt16 {
        RTPHeader.decode(from: packet)?.header.sequenceNumber ?? 0
    }

    /// Recover position `missing` of `group` from the others and assert the
    /// reconstruction is byte-identical to the original.
    private func assertRecovers(
        _ group: [Data], missing: Int, ssrc: UInt32, file: StaticString = #filePath, line: UInt = #line
    ) {
        let body = FECCodec.parityBody(for: group[...])
        XCTAssertFalse(body.isEmpty, file: file, line: line)
        var members = group
        let lost = members.remove(at: missing)
        let recovered = FECCodec.recover(
            missingSeq: seqOf(lost), ssrc: ssrc, members: members, body: body)
        XCTAssertEqual(recovered, lost, "position \(missing) not reconstructed", file: file, line: line)
    }

    func testRecoveryRoundTripEveryPositionH264() {
        let group = h264Group()
        XCTAssertGreaterThanOrEqual(group.count, 4, "builder should span several packets")
        for missing in group.indices {
            assertRecovers(group, missing: missing, ssrc: 0xABCD)
        }
    }

    func testMarkerPacketSurvivesRecovery() {
        // The AU's last packet carries the marker bit; a parity that omitted
        // byte 1 would silently merge two AUs on recovery.
        let group = h264Group()
        let last = group.count - 1
        XCTAssertEqual(group[last][group[last].startIndex + 1] & 0x80, 0x80, "last packet must carry marker")
        assertRecovers(group, missing: last, ssrc: 0xABCD)
    }

    func testRecoveryRoundTripEveryPositionHEVC() {
        let group = hevcGroup()
        for missing in group.indices {
            assertRecovers(group, missing: missing, ssrc: 0xBEEF)
        }
    }

    func testRecoveryAcrossSequenceWraparound() {
        // Group spanning 0xFFFE…0x0002 — recovery stamps the missing seq the
        // caller tracked, and the parity math is position-independent.
        let group = h264Group(startSeq: 0xFFFE)
        XCTAssertEqual(seqOf(group[0]), 0xFFFE)
        for missing in group.indices {
            assertRecovers(group, missing: missing, ssrc: 0xABCD)
        }
    }

    func testRecoveredPacketFeedsDepacketizerIntact() {
        // End-to-end sanity: drop one FU-A fragment, recover it, and the
        // depacketizer still assembles the exact original access unit.
        let packetizer = H264Packetizer()
        let nal = Data([0x65] + (0..<3000).map { UInt8(($0 &* 5) & 0xFF) })
        let group = packetizer.packetize(nals: [nal], timestamp: 90, ssrc: 5, startSequence: 0)
        let body = FECCodec.parityBody(for: group[...])
        var members = group
        let lost = members.remove(at: 1)
        guard
            let recovered = FECCodec.recover(missingSeq: seqOf(lost), ssrc: 5, members: members, body: body)
        else {
            XCTFail("recovery failed")
            return
        }
        let dp = H264Depacketizer()
        var received = group
        received[1] = recovered
        var au: VideoAccessUnit?
        for packet in received {
            if let out = dp.ingest(packet) { au = out }
        }
        XCTAssertEqual(au.map { AVCCParser.nalUnits(from: $0.avcc) }, [nal])
        XCTAssertEqual(au?.lostBeforeThisAU, false)
    }

    // MARK: - Group packing

    func testGroupRangesChunksAtN() {
        XCTAssertEqual(FECCodec.groupRanges(templateCount: 25, groupSize: 10), [0..<10, 10..<20, 20..<25])
    }

    func testGroupRangesSkipsSingletonRemainder() {
        // Trailing run of 1 < minGroupSize: left uncovered, not a
        // duplication-degenerate parity.
        XCTAssertEqual(FECCodec.groupRanges(templateCount: 21, groupSize: 10), [0..<10, 10..<20])
    }

    func testGroupRangesSkipsSinglePacketBatch() {
        XCTAssertEqual(FECCodec.groupRanges(templateCount: 1, groupSize: 10), [])
    }

    func testGroupRangesShortDeltaFrameFormsOneGroup() {
        XCTAssertEqual(FECCodec.groupRanges(templateCount: 3, groupSize: 10), [0..<3])
    }

    func testGroupRangesRejectsDegenerateGroupSize() {
        XCTAssertEqual(FECCodec.groupRanges(templateCount: 20, groupSize: 1), [])
        XCTAssertEqual(FECCodec.groupRanges(templateCount: 20, groupSize: 0), [])
    }

    func testGroupRangesClampsToMaxGroupSize() {
        // Requested 32 clamps to the wire cap of 16.
        XCTAssertEqual(FECCodec.groupRanges(templateCount: 32, groupSize: 32), [0..<16, 16..<32])
    }

    // MARK: - Malformed input rejection

    func testRecoverRejectsShortBody() {
        let group = h264Group()
        XCTAssertNil(
            FECCodec.recover(missingSeq: 1, ssrc: 1, members: Array(group.dropFirst()), body: Data([0, 1, 2])))
    }

    func testRecoverRejectsGarbageBody() {
        // An all-zero body solves to a recovered length of garbage (the XOR
        // of the members' lengths), which lands outside the body's payload
        // range or below the RTP header size — either way, nil, never a torn
        // packet.
        let group = h264Group()
        var members = group
        members.remove(at: 0)
        let zeroBody = Data(count: 20)
        XCTAssertNil(FECCodec.recover(missingSeq: seqOf(group[0]), ssrc: 1, members: members, body: zeroBody))
    }

    func testRecoverRejectsMemberLongerThanParityRegion() {
        // A member whose payload exceeds the parity's padded region can't
        // have been covered by that parity — mis-matched parity must reject.
        let group = h264Group()
        let smallGroup = [group[3], group[3]]  // tiny packets
        let body = FECCodec.parityBody(for: smallGroup[...])
        XCTAssertNil(FECCodec.recover(missingSeq: 1, ssrc: 1, members: [group[2]], body: body))
    }

    func testRecoverRejectsTruncatedMember() {
        let group = h264Group()
        let body = FECCodec.parityBody(for: group[...])
        var members = Array(group.dropFirst())
        members[0] = members[0].prefix(6)  // shorter than an RTP header
        XCTAssertNil(FECCodec.recover(missingSeq: seqOf(group[0]), ssrc: 1, members: members, body: body))
    }

    func testParityBodyEmptyForDegenerateGroups() {
        let group = h264Group()
        XCTAssertTrue(FECCodec.parityBody(for: group[0..<1]).isEmpty, "singleton group")
        XCTAssertTrue(FECCodec.parityBody(for: [Data([0x80, 0x60]), group[0]][...]).isEmpty, "runt member")
    }
}
