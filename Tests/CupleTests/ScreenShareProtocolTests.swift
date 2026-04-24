import XCTest
@testable import Cuple

final class ScreenShareProtocolTests: XCTestCase {

    // MARK: - Control-channel message round-trip

    func testRoundTripParameterSets() throws {
        let sps = Data([0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9])
        let pps = Data([0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0])
        let message: ScreenShareMessage = .parameterSets(sps: sps, pps: pps)

        var parser = ScreenShareMessageParser()
        parser.append(message.encode())

        let decoded = try XCTUnwrap(parser.next())
        guard case let .parameterSets(sps: gotSps, pps: gotPps) = decoded else {
            return XCTFail("expected .parameterSets, got \(decoded)")
        }
        XCTAssertEqual(gotSps, sps)
        XCTAssertEqual(gotPps, pps)
    }

    func testRoundTripKeyframeRequest() throws {
        let message: ScreenShareMessage = .keyframeRequest
        var parser = ScreenShareMessageParser()
        parser.append(message.encode())

        let decoded = try XCTUnwrap(parser.next())
        guard case .keyframeRequest = decoded else {
            return XCTFail("expected .keyframeRequest, got \(decoded)")
        }
    }

    func testPartialReceiveReturnsNilUntilComplete() {
        let sps = Data(repeating: 0x67, count: 100)
        let pps = Data(repeating: 0x68, count: 100)
        let full = ScreenShareMessage.parameterSets(sps: sps, pps: pps).encode()

        var parser = ScreenShareMessageParser()
        parser.append(full.prefix(2))
        XCTAssertNil(parser.next())
        parser.append(full.subdata(in: 2..<10))
        XCTAssertNil(parser.next())
        parser.append(full.subdata(in: 10..<full.count))
        let decoded = parser.next()
        XCTAssertNotNil(decoded)
        if case let .parameterSets(sps: gotSps, pps: gotPps) = decoded {
            XCTAssertEqual(gotSps, sps)
            XCTAssertEqual(gotPps, pps)
        } else {
            XCTFail("expected .parameterSets")
        }
    }

    func testMultipleMessagesInOneChunk() throws {
        let m1: ScreenShareMessage = .parameterSets(sps: Data([0x67]), pps: Data([0x68]))
        let m2: ScreenShareMessage = .keyframeRequest
        let m3: ScreenShareMessage = .parameterSets(sps: Data([0x67, 0x42]), pps: Data([0x68, 0x43]))

        var combined = Data()
        combined.append(m1.encode())
        combined.append(m2.encode())
        combined.append(m3.encode())

        var parser = ScreenShareMessageParser()
        parser.append(combined)

        let d1 = try XCTUnwrap(parser.next())
        let d2 = try XCTUnwrap(parser.next())
        let d3 = try XCTUnwrap(parser.next())
        XCTAssertNil(parser.next())

        guard case let .parameterSets(sps: gotSps1, pps: gotPps1) = d1 else { return XCTFail("d1") }
        guard case .keyframeRequest = d2 else { return XCTFail("d2") }
        guard case let .parameterSets(sps: gotSps3, pps: gotPps3) = d3 else { return XCTFail("d3") }
        XCTAssertEqual(gotSps1, Data([0x67]))
        XCTAssertEqual(gotPps1, Data([0x68]))
        XCTAssertEqual(gotSps3, Data([0x67, 0x42]))
        XCTAssertEqual(gotPps3, Data([0x68, 0x43]))
    }

    func testRoundTripKeyframe() throws {
        let au = Data(repeating: 0x67, count: 4096)
        let ts: UInt64 = 0xDEAD_BEEF_CAFE_F00D
        let message: ScreenShareMessage = .keyframe(timestampNs: ts, data: au)

        var parser = ScreenShareMessageParser()
        parser.append(message.encode())

        let decoded = try XCTUnwrap(parser.next())
        guard case let .keyframe(timestampNs: gotTs, data: gotData) = decoded else {
            return XCTFail("expected .keyframe, got \(decoded)")
        }
        XCTAssertEqual(gotTs, ts)
        XCTAssertEqual(gotData, au)
    }

    func testUnknownMessageTypeIsSkipped() throws {
        var bogus = Data()
        bogus.append(0xFF)
        bogus.append(contentsOf: [0x00, 0x00, 0x00, 0x02])
        bogus.append(contentsOf: [0xDE, 0xAD])

        let good = ScreenShareMessage.keyframeRequest.encode()

        var parser = ScreenShareMessageParser()
        parser.append(bogus + good)

        let decoded = try XCTUnwrap(parser.next())
        guard case .keyframeRequest = decoded else {
            return XCTFail("expected .keyframeRequest after skipping unknown type")
        }
    }

    // MARK: - RTP packetize / depacketize

    /// Build an AVCC access unit (length-prefixed NALs) from raw NAL bodies.
    private func buildAVCC(_ nals: [Data]) -> Data {
        var out = Data()
        for nal in nals {
            let n = UInt32(nal.count)
            out.append(UInt8((n >> 24) & 0xFF))
            out.append(UInt8((n >> 16) & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8(n & 0xFF))
            out.append(nal)
        }
        return out
    }

    /// Make a synthetic H.264 NAL with a particular type. First byte is the
    /// NAL header (F=0, NRI=2, type=`type`); body is filler.
    private func makeNAL(type: UInt8, bodySize: Int) -> Data {
        var nal = Data()
        nal.append(0x40 | (type & 0x1F))                 // NRI=2, type=<type>
        nal.append(contentsOf: (0..<bodySize).map { UInt8($0 & 0xFF) })
        return nal
    }

    func testSingleNALRoundTrip() {
        let nal = makeNAL(type: 1, bodySize: 500)       // ≤ MTU → Single NAL packet
        let accessUnit = buildAVCC([nal])

        let packetizer = RTPPacketizer(ssrc: 0x1234_5678, initialSequence: 0)
        let packets = packetizer.packetize(accessUnit: accessUnit, rtpTimestamp: 90000)
        XCTAssertEqual(packets.count, 1)

        let depack = RTPDepacketizer()
        var emitted: Data?
        var keyframe = false
        depack.onAccessUnit = { data, kf in emitted = data; keyframe = kf }

        for p in packets { depack.feed(p) }
        XCTAssertEqual(emitted, accessUnit)
        XCTAssertFalse(keyframe)                         // type 1 is P-slice
    }

    func testKeyframeDetected() {
        let idr = makeNAL(type: 5, bodySize: 200)        // IDR slice
        let accessUnit = buildAVCC([idr])

        let packetizer = RTPPacketizer(ssrc: 1, initialSequence: 100)
        let packets = packetizer.packetize(accessUnit: accessUnit, rtpTimestamp: 1)

        let depack = RTPDepacketizer()
        var emitted: Data?
        var keyframe = false
        depack.onAccessUnit = { data, kf in emitted = data; keyframe = kf }

        for p in packets { depack.feed(p) }
        XCTAssertEqual(emitted, accessUnit)
        XCTAssertTrue(keyframe)
    }

    func testFUAFragmentationRoundTrip() {
        // Oversized IDR: much larger than MTU → must fragment via FU-A.
        let bigNAL = makeNAL(type: 5, bodySize: 5000)
        let accessUnit = buildAVCC([bigNAL])

        let packetizer = RTPPacketizer(ssrc: 42, initialSequence: 0)
        let packets = packetizer.packetize(accessUnit: accessUnit, rtpTimestamp: 90_000)
        XCTAssertGreaterThan(packets.count, 1, "5000-byte NAL should produce multiple FU-A fragments")

        // Sanity-check FU-A framing: first fragment has S=1, last has E=1 and marker bit.
        let first = packets.first!
        let last = packets.last!
        let rtpHeader = 12
        let firstPayload = first[first.index(first.startIndex, offsetBy: rtpHeader)...]
        let lastPayload = last[last.index(last.startIndex, offsetBy: rtpHeader)...]
        let firstFUHeader = firstPayload[firstPayload.index(after: firstPayload.startIndex)]
        let lastFUHeader = lastPayload[lastPayload.index(after: lastPayload.startIndex)]
        XCTAssertEqual(firstFUHeader & 0b1000_0000, 0b1000_0000, "S bit set on first fragment")
        XCTAssertEqual(lastFUHeader & 0b0100_0000, 0b0100_0000, "E bit set on last fragment")
        // Marker bit is in the 2nd byte of the RTP header; only on last packet.
        XCTAssertEqual(last[last.index(last.startIndex, offsetBy: 1)] & 0x80, 0x80)
        XCTAssertEqual(first[first.index(first.startIndex, offsetBy: 1)] & 0x80, 0x00)

        // Reassemble.
        let depack = RTPDepacketizer()
        var emitted: Data?
        var keyframe = false
        depack.onAccessUnit = { data, kf in emitted = data; keyframe = kf }
        for p in packets { depack.feed(p) }
        XCTAssertEqual(emitted, accessUnit)
        XCTAssertTrue(keyframe)
    }

    func testMultipleNALsOneFrame() {
        // Access unit containing an SEI + IDR (common for first keyframe).
        let sei = makeNAL(type: 6, bodySize: 30)
        let idr = makeNAL(type: 5, bodySize: 400)
        let accessUnit = buildAVCC([sei, idr])

        let packetizer = RTPPacketizer(ssrc: 7, initialSequence: 1000)
        let packets = packetizer.packetize(accessUnit: accessUnit, rtpTimestamp: 12345)
        // Both NALs fit under MTU → 2 Single NAL packets, 1 access unit.
        XCTAssertEqual(packets.count, 2)

        let depack = RTPDepacketizer()
        var emitted: Data?
        var keyframe = false
        depack.onAccessUnit = { data, kf in emitted = data; keyframe = kf }
        for p in packets { depack.feed(p) }
        XCTAssertEqual(emitted, accessUnit)
        XCTAssertTrue(keyframe)
    }

    func testDroppedMiddleFragmentFailsAndReportsLoss() {
        let bigNAL = makeNAL(type: 1, bodySize: 5000)
        let accessUnit = buildAVCC([bigNAL])

        let packetizer = RTPPacketizer(ssrc: 1, initialSequence: 0)
        let packets = packetizer.packetize(accessUnit: accessUnit, rtpTimestamp: 1)
        XCTAssertGreaterThan(packets.count, 2)

        let depack = RTPDepacketizer()
        var emittedCount = 0
        var lossCount = 0
        depack.onAccessUnit = { _, _ in emittedCount += 1 }
        depack.onLoss = { _ in lossCount += 1 }

        // Feed all except the middle fragment.
        for (i, p) in packets.enumerated() where i != packets.count / 2 {
            depack.feed(p)
        }

        XCTAssertEqual(emittedCount, 0, "Corrupted frame must not be emitted")
        XCTAssertGreaterThan(lossCount, 0, "Loss must be reported for keyframe-request feedback")
    }

    func testShortDatagramIsRejected() {
        let depack = RTPDepacketizer()
        var emittedCount = 0
        var lossCount = 0
        depack.onAccessUnit = { _, _ in emittedCount += 1 }
        depack.onLoss = { _ in lossCount += 1 }

        // Only 5 bytes — well below the 12-byte RTP header minimum.
        depack.feed(Data([0x80, 0x60, 0x00, 0x01, 0x00]))
        XCTAssertEqual(emittedCount, 0)
        XCTAssertEqual(lossCount, 1)
    }

    func testSequenceNumbersAreMonotonic() {
        let nal = makeNAL(type: 1, bodySize: 200)
        let accessUnit = buildAVCC([nal])
        let packetizer = RTPPacketizer(ssrc: 1, initialSequence: 65534)

        // Four frames → four Single NAL packets at seq 65534, 65535, 0, 1 (wraps).
        var seqs: [UInt16] = []
        for ts in 0..<4 {
            for p in packetizer.packetize(accessUnit: accessUnit, rtpTimestamp: UInt32(ts)) {
                let seq = UInt16(p[p.index(p.startIndex, offsetBy: 2)]) << 8
                          | UInt16(p[p.index(p.startIndex, offsetBy: 3)])
                seqs.append(seq)
            }
        }
        XCTAssertEqual(seqs, [65534, 65535, 0, 1])
    }
}
