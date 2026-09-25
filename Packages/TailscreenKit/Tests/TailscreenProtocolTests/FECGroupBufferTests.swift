import XCTest

@testable import TailscreenProtocol

/// Pure tests for the viewer-side FEC group buffer: single-loss recovery,
/// parity-before-member reordering, multi-loss deferral to NACK (parity
/// aging out), the at-most-once recovery guard for late originals, and the
/// bounded media ring. Deterministic — injected `nowNs`, no I/O.
final class FECGroupBufferTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    private func makeGroup(startSeq: UInt16 = 200, ssrc: UInt32 = 0x1234, ts: UInt32 = 900) -> [Data] {
        let packetizer = H264Packetizer()
        let nals = [
            Data([0x65] + (0..<600).map { UInt8($0 & 0xFF) }),
            Data([0x41] + (0..<2400).map { UInt8(($0 &* 3) & 0xFF) }),
            Data([0x41] + (0..<200).map { UInt8(($0 &* 9) & 0xFF) })
        ]
        return packetizer.packetize(nals: nals, timestamp: ts, ssrc: ssrc, startSequence: startSeq)
    }

    private func seqOf(_ packet: Data) -> UInt16 {
        RTPHeader.decode(from: packet)?.header.sequenceNumber ?? 0
    }

    private func parity(for group: [Data]) -> (base: UInt16, count: Int, body: Data) {
        (seqOf(group[0]), group.count, FECCodec.parityBody(for: group[...]))
    }

    func testSingleLossRecoveredOnParityArrival() {
        let group = makeGroup()
        let lostIndex = 1
        var buffer = FECGroupBuffer()
        for (i, packet) in group.enumerated() where i != lostIndex {
            XCTAssertNil(buffer.noteMedia(seq: seqOf(packet), packet: packet, nowNs: UInt64(i) * ms))
        }
        let par = parity(for: group)
        let recovery = buffer.noteParity(baseSeq: par.base, count: par.count, body: par.body, nowNs: 10 * ms)
        XCTAssertEqual(recovery?.seq, seqOf(group[lostIndex]))
        XCTAssertEqual(recovery?.packet, group[lostIndex])
    }

    func testParityBeforeReorderedMemberRecovers() {
        // Parity arrives with two members unseen (unsolvable, buffered); the
        // reordered member's arrival makes the group one-missing and solves it.
        let group = makeGroup()
        var buffer = FECGroupBuffer()
        for (i, packet) in group.enumerated() where i >= 2 {
            XCTAssertNil(buffer.noteMedia(seq: seqOf(packet), packet: packet, nowNs: UInt64(i) * ms))
        }
        let par = parity(for: group)
        XCTAssertNil(
            buffer.noteParity(baseSeq: par.base, count: par.count, body: par.body, nowNs: 6 * ms),
            "two missing members — not solvable yet")
        let recovery = buffer.noteMedia(seq: seqOf(group[1]), packet: group[1], nowNs: 8 * ms)
        XCTAssertEqual(recovery?.seq, seqOf(group[0]))
        XCTAssertEqual(recovery?.packet, group[0])
    }

    func testTwoLossesNeverRecoverAndParityAgesOut() {
        let group = makeGroup()
        var buffer = FECGroupBuffer()
        for (i, packet) in group.enumerated() where i >= 2 {
            XCTAssertNil(buffer.noteMedia(seq: seqOf(packet), packet: packet, nowNs: UInt64(i) * ms))
        }
        let par = parity(for: group)
        XCTAssertNil(buffer.noteParity(baseSeq: par.base, count: par.count, body: par.body, nowNs: 6 * ms))
        // Past the linger window parity is purged; NACK owns multi-loss groups after that.
        let afterLinger = 6 * ms + buffer.parityLingerNs + ms
        XCTAssertNil(buffer.noteMedia(seq: seqOf(group[1]), packet: group[1], nowNs: afterLinger))
    }

    func testParityForFullyReceivedGroupIsDropped() {
        let group = makeGroup()
        var buffer = FECGroupBuffer()
        for (i, packet) in group.enumerated() {
            XCTAssertNil(buffer.noteMedia(seq: seqOf(packet), packet: packet, nowNs: UInt64(i) * ms))
        }
        let par = parity(for: group)
        XCTAssertNil(buffer.noteParity(baseSeq: par.base, count: par.count, body: par.body, nowNs: 9 * ms))
    }

    func testLateOriginalAfterRecoveryIsNotReEmitted() {
        let group = makeGroup()
        var buffer = FECGroupBuffer()
        for (i, packet) in group.enumerated() where i != 0 {
            XCTAssertNil(buffer.noteMedia(seq: seqOf(packet), packet: packet, nowNs: UInt64(i) * ms))
        }
        let par = parity(for: group)
        let recovery = buffer.noteParity(baseSeq: par.base, count: par.count, body: par.body, nowNs: 8 * ms)
        XCTAssertEqual(recovery?.seq, seqOf(group[0]))
        // At-most-once guard: the late original arriving must not re-emit (reorder buffer dedups the wire copy).
        XCTAssertNil(buffer.noteMedia(seq: seqOf(group[0]), packet: group[0], nowNs: 9 * ms))
        // A duplicated parity is equally inert.
        XCTAssertNil(buffer.noteParity(baseSeq: par.base, count: par.count, body: par.body, nowNs: 10 * ms))
    }

    func testMediaRingEvictsOldestUnderMemoryBound() {
        // Old group members get evicted as fresh packets pour in, so its parity finds ≥2 missing and can't mis-solve.
        let oldGroup = makeGroup(startSeq: 0)
        var buffer = FECGroupBuffer(maxHeldBytes: 8 * 1024, maxHeldPackets: 8)
        var now: UInt64 = 0
        for packet in oldGroup {
            now += ms
            _ = buffer.noteMedia(seq: seqOf(packet), packet: packet, nowNs: now)
        }
        // Flood with a later batch to push the old group out.
        let flood = makeGroup(startSeq: 1000, ts: 1800)
        for _ in 0..<4 {
            for packet in flood {
                now += ms
                _ = buffer.noteMedia(seq: seqOf(packet), packet: packet, nowNs: now)
            }
        }
        let par = parity(for: oldGroup)
        XCTAssertNil(
            buffer.noteParity(baseSeq: par.base, count: par.count, body: par.body, nowNs: now + ms),
            "evicted members must make the old group unsolvable, not mis-solved")
    }
}
