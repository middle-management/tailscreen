import XCTest

@testable import TailscreenProtocol

final class RTPPacketTests: XCTestCase {
    func testHeaderRoundTrip() throws {
        var buffer = Data()
        let original = RTPHeader(
            marker: true,
            payloadType: 96,
            sequenceNumber: 0xABCD,
            timestamp: 0x1234_5678,
            ssrc: 0xDEAD_BEEF
        )
        original.encode(into: &buffer)

        XCTAssertEqual(buffer.count, RTPHeader.size)

        let (decoded, payloadOffset) = try XCTUnwrap(RTPHeader.decode(from: buffer))
        XCTAssertEqual(payloadOffset, RTPHeader.size)
        XCTAssertTrue(decoded.marker)
        XCTAssertEqual(decoded.payloadType, 96)
        XCTAssertEqual(decoded.sequenceNumber, 0xABCD)
        XCTAssertEqual(decoded.timestamp, 0x1234_5678)
        XCTAssertEqual(decoded.ssrc, 0xDEAD_BEEF)
    }

    func testHeaderRejectsWrongVersion() {
        var buffer = Data([0x40, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])  // V=1
        XCTAssertNil(RTPHeader.decode(from: buffer))
        buffer[0] = 0x80
        XCTAssertNotNil(RTPHeader.decode(from: buffer))
    }

    func testControlPacketsAreDistinguishable() {
        let hello = ScreenShareControlMessage.encode(.hello)
        let pli = ScreenShareControlMessage.encode(.pli)
        XCTAssertTrue(ScreenShareControlMessage.looksLikeControl(hello))
        XCTAssertTrue(ScreenShareControlMessage.looksLikeControl(pli))
        XCTAssertEqual(ScreenShareControlMessage.decode(hello), .hello)
        XCTAssertEqual(ScreenShareControlMessage.decode(pli), .pli)

        // CODEC_NO (the viewer's "I can't decode this, fall back to H.264"
        // signal) must round-trip and read as control, not RTP.
        let codecNo = ScreenShareControlMessage.encode(.codecUnsupported)
        XCTAssertTrue(ScreenShareControlMessage.looksLikeControl(codecNo))
        XCTAssertEqual(ScreenShareControlMessage.decode(codecNo), .codecUnsupported)

        // PROFILE_NO (the viewer's "I can't decode this bit depth, fall back
        // to 8-bit" signal) must round-trip and read as control, not RTP.
        let profileNo = ScreenShareControlMessage.encode(.profileUnsupported)
        XCTAssertTrue(ScreenShareControlMessage.looksLikeControl(profileNo))
        XCTAssertEqual(ScreenShareControlMessage.decode(profileNo), .profileUnsupported)
        // Old parsers (no 0x09 case) get nil from decode and ignore it — the
        // backward-compatibility contract for the new byte.
        XCTAssertEqual(profileNo, Data([0x09]))

        // A real RTP packet's first byte is 0x80; must not look like control.
        var rtp = Data()
        RTPHeader(marker: false, payloadType: 96, sequenceNumber: 0, timestamp: 0, ssrc: 1).encode(into: &rtp)
        XCTAssertFalse(ScreenShareControlMessage.looksLikeControl(rtp))
    }

    func testAVCCParserSplitsLengthPrefixedNALs() {
        let nal1 = Data([0x67, 0xAA, 0xBB])  // SPS
        let nal2 = Data([0x68, 0xCC])  // PPS
        let nal3 = Data([0x65] + Array(repeating: UInt8(0x99), count: 100))  // IDR slice

        var avcc = Data()
        for nal in [nal1, nal2, nal3] {
            avcc.appendBE(UInt32(nal.count))
            avcc.append(nal)
        }

        let parsed = AVCCParser.nalUnits(from: avcc)
        XCTAssertEqual(parsed, [nal1, nal2, nal3])
    }

    func testSingleNALPacketization() throws {
        // Small NAL fits in one Single NAL packet.
        let nal = Data([0x67, 0x42, 0x00, 0x1F, 0xAC])  // SPS
        let packets = H264Packetizer().packetize(
            nals: [nal], timestamp: 9000, ssrc: 0x11_22_33_44, startSequence: 100
        )

        XCTAssertEqual(packets.count, 1)
        let packet = packets[0]
        let (header, offset) = try XCTUnwrap(RTPHeader.decode(from: packet))
        XCTAssertTrue(header.marker)  // last (and only) packet of AU
        XCTAssertEqual(header.sequenceNumber, 100)
        XCTAssertEqual(header.timestamp, 9000)
        XCTAssertEqual(packet.suffix(from: packet.startIndex + offset), nal)
    }

    func testFragmentedNALPacketization() throws {
        // Build a NAL larger than maxPayloadBytes to force FU-A.
        let bodySize = H264Packetizer.maxPayloadBytes * 3 - 7
        var nal = Data([0x65])  // IDR slice header (NRI=11, type=5)
        nal.append(contentsOf: (0..<bodySize).map { UInt8($0 & 0xFF) })

        let packets = H264Packetizer().packetize(
            nals: [nal], timestamp: 18000, ssrc: 1, startSequence: 0
        )

        // Body is split into ceil(bodySize / (maxPayload-2)) fragments.
        let fragSize = H264Packetizer.maxPayloadBytes - 2
        let expectedFragments = (bodySize + fragSize - 1) / fragSize
        XCTAssertEqual(packets.count, expectedFragments)

        for (i, packet) in packets.enumerated() {
            let (header, offset) = try XCTUnwrap(RTPHeader.decode(from: packet))
            XCTAssertEqual(header.timestamp, 18000)
            XCTAssertEqual(header.sequenceNumber, UInt16(i))
            XCTAssertEqual(header.marker, i == packets.count - 1)

            let payload = packet.suffix(from: packet.startIndex + offset)
            XCTAssertGreaterThanOrEqual(payload.count, 3)
            let fuIndicator = payload[payload.startIndex]
            let fuHeader = payload[payload.startIndex + 1]
            XCTAssertEqual(fuIndicator & 0x1F, 28)  // type 28 = FU-A
            XCTAssertEqual(fuIndicator & 0xE0, 0x60)  // NRI preserved (0x65 → NRI=11)
            XCTAssertEqual(fuHeader & 0x1F, 5)  // original NAL type
            XCTAssertEqual((fuHeader & 0x80) != 0, i == 0)  // S bit on first
            XCTAssertEqual((fuHeader & 0x40) != 0, i == packets.count - 1)  // E bit on last
        }
    }

    func testSingleNALRoundTripThroughDepacketizer() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let pps = Data([0x68, 0xCB, 0x83])
        let slice = Data([0x65, 0xAA, 0xBB, 0xCC, 0xDD])  // small IDR slice

        let packets = H264Packetizer().packetize(
            nals: [sps, pps, slice], timestamp: 12345, ssrc: 0xCAFE, startSequence: 7
        )
        XCTAssertEqual(packets.count, 3)

        let depacketizer = H264Depacketizer()
        var au: VideoAccessUnit?
        for p in packets {
            if let result = depacketizer.ingest(p) { au = result }
        }
        let unwrapped = try XCTUnwrap(au)

        XCTAssertTrue(unwrapped.containsIDR)
        XCTAssertEqual(unwrapped.timestamp, 12345)
        XCTAssertFalse(unwrapped.lostBeforeThisAU)
        XCTAssertEqual(AVCCParser.nalUnits(from: unwrapped.avcc), [sps, pps, slice])
    }

    func testFragmentedNALRoundTripThroughDepacketizer() throws {
        // Mix small + large NALs in one access unit to exercise both modes.
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let bodySize = H264Packetizer.maxPayloadBytes * 2 + 137
        var slice = Data([0x65])
        slice.append(contentsOf: (0..<bodySize).map { UInt8(($0 * 13) & 0xFF) })

        let packets = H264Packetizer().packetize(
            nals: [sps, slice], timestamp: 90_000, ssrc: 1, startSequence: 0xFFFE
        )

        let depacketizer = H264Depacketizer()
        var au: VideoAccessUnit?
        for p in packets {
            if let result = depacketizer.ingest(p) { au = result }
        }
        let unwrapped = try XCTUnwrap(au)

        XCTAssertTrue(unwrapped.containsIDR)
        XCTAssertFalse(unwrapped.lostBeforeThisAU)
        XCTAssertEqual(AVCCParser.nalUnits(from: unwrapped.avcc), [sps, slice])
    }

    func testSequenceWraparoundIsAccepted() throws {
        // First packet seq = 0xFFFF, second seq = 0x0000. The depacketizer
        // must treat the wraparound as in-sequence (not as packet loss).
        let nal1 = Data([0x41, 0xAA])
        let nal2 = Data([0x41, 0xBB])

        let packetizer = H264Packetizer()
        var p1Packets = packetizer.packetize(
            nals: [nal1], timestamp: 1, ssrc: 1, startSequence: 0xFFFF
        )
        // Packetizer puts marker on the last packet of the AU it's given,
        // which is what we want here — that flushes AU1.
        let p2Packets = packetizer.packetize(
            nals: [nal2], timestamp: 2, ssrc: 1, startSequence: 0x0000
        )
        p1Packets.append(contentsOf: p2Packets)

        let depacketizer = H264Depacketizer()
        var aus: [VideoAccessUnit] = []
        for p in p1Packets {
            if let result = depacketizer.ingest(p) { aus.append(result) }
        }

        XCTAssertEqual(aus.count, 2)
        XCTAssertFalse(aus[0].lostBeforeThisAU)
        XCTAssertFalse(aus[1].lostBeforeThisAU)
    }

    func testDroppedPacketCorruptsAUAndSignalsLoss() {
        let nal1 = Data([0x41, 0xAA])
        let nal2 = Data([0x41, 0xBB])
        let nal3 = Data([0x41, 0xCC])

        let packetizer = H264Packetizer()
        let packets = packetizer.packetize(
            nals: [nal1, nal2, nal3], timestamp: 50, ssrc: 1, startSequence: 10
        )
        XCTAssertEqual(packets.count, 3)

        // reorderDepth: 1 so the reorder window gives up on the missing packet
        // as soon as one *newer* packet piles up behind the gap — i.e. this
        // exercises genuine loss, not the reorder-tolerance path. With the
        // default depth the depacketizer would (correctly) hold the gap open
        // waiting for the "missing" packet to arrive late.
        let depacketizer = H264Depacketizer(reorderDepth: 1)
        _ = depacketizer.ingest(packets[0])
        // Drop the middle packet (seq 11). packets[2] (seq 12) gets buffered
        // pending the gap, so no AU is emitted yet.
        let result = depacketizer.ingest(packets[2])
        XCTAssertNil(result)

        // The next frame's packet is the second to pile up behind the gap,
        // exceeding the depth-1 window: the depacketizer gives up on seq 11,
        // drops the torn AU, and flags the next clean AU as lost-before.
        let nal4 = Data([0x41, 0xDD])
        let next = packetizer.packetize(
            nals: [nal4], timestamp: 60, ssrc: 1, startSequence: 13
        )
        let au = depacketizer.ingest(next[0])
        XCTAssertNotNil(au)
        XCTAssertTrue(au?.lostBeforeThisAU ?? false)
    }

    func testReorderedPacketsRecoverWithoutLoss() throws {
        // A 3-NAL AU split across 3 packets, delivered out of order
        // (seq 10, 12, 11). The reorder buffer must hold seq 12, slot seq 11
        // in when it arrives, and emit a complete, in-order AU — no loss flag,
        // no dropped frame. This is the WAN reordering case loopback never hits.
        let nal1 = Data([0x41, 0xAA])
        let nal2 = Data([0x41, 0xBB])
        let nal3 = Data([0x41, 0xCC])
        let packets = H264Packetizer().packetize(
            nals: [nal1, nal2, nal3], timestamp: 50, ssrc: 1, startSequence: 10
        )
        XCTAssertEqual(packets.count, 3)

        let depacketizer = H264Depacketizer()
        XCTAssertNil(depacketizer.ingest(packets[0]))  // seq 10
        XCTAssertNil(depacketizer.ingest(packets[2]))  // seq 12 — held
        let au = try XCTUnwrap(depacketizer.ingest(packets[1]))  // seq 11 fills the gap

        XCTAssertFalse(au.lostBeforeThisAU)
        XCTAssertEqual(AVCCParser.nalUnits(from: au.avcc), [nal1, nal2, nal3])
    }

    func testDeepKeyframePileupTornByCountButHeldByTime() {
        // Regression (WAN keyframe stall): a keyframe spans hundreds of RTP
        // packets. A single early loss used to tear the whole AU because the
        // count-based reorder window (64 in NACK mode) overflowed in tens of
        // ms — long before a NACK retransmit could arrive ~1 RTT (~160 ms)
        // later. The retransmit then landed "behind" the advanced cursor and
        // was dropped as a straggler, so the keyframe never reassembled and
        // the viewer never installed parameter sets. In NACK mode the buffer
        // now holds a gap by TIME (`gapHoldNs`) under a generous hard cap, so
        // the late retransmit fills it and the frame stays whole.
        let t0: UInt64 = 1_000_000_000

        // Old behavior: count window 64. Pile 100 packets behind an early gap
        // (seq 101) → overflow → the gap is abandoned (torn) before any
        // retransmit could land.
        var countBased = RTPReorderBuffer(maxDepth: 64)
        _ = countBased.push(seq: 100, packet: Data([0]))
        var tornEarly = false
        for seq in 102...201 {
            let rel = countBased.push(seq: UInt16(seq), packet: Data([UInt8(seq & 0xff)]))
            if rel.contains(where: { $0.lostBefore }) { tornEarly = true }
        }
        XCTAssertTrue(tornEarly, "count-based window tears the keyframe on a deep pileup")

        // New behavior: hold the gap by time (250 ms) under a generous hard cap.
        var timeBased = RTPReorderBuffer(maxDepth: 512, gapHoldNs: 250_000_000)
        XCTAssertEqual(timeBased.push(seq: 100, packet: Data([0]), nowNs: t0).count, 1)
        for (i, seq) in (102...201).enumerated() {
            // ~0.3 ms apart — the whole 100-packet pileup lands within ~30 ms,
            // far inside the 250 ms hold.
            let rel = timeBased.push(
                seq: UInt16(seq), packet: Data([UInt8(seq & 0xff)]),
                nowNs: t0 &+ UInt64(i) &* 300_000)
            XCTAssertTrue(rel.isEmpty, "gap held while waiting for the retransmit")
        }
        // The retransmit of seq 101 lands ~160 ms later — within the hold.
        let filled = timeBased.push(seq: 101, packet: Data([101]), nowNs: t0 &+ 160_000_000)
        XCTAssertEqual(filled.count, 101, "seq 101..201 drain in order once the gap fills")
        XCTAssertFalse(
            filled.contains(where: { $0.lostBefore }), "no loss — the frame stays whole")
    }

    func testGapHeldByTimeStillDeclaresLossAfterDeadline() {
        // The hold is bounded: if the retransmit never comes, the gap must
        // still be abandoned once `gapHoldNs` elapses so a genuinely lost
        // packet can't wedge the stream forever.
        let t0: UInt64 = 1_000_000_000
        var buf = RTPReorderBuffer(maxDepth: 512, gapHoldNs: 200_000_000)
        XCTAssertEqual(buf.push(seq: 10, packet: Data([10]), nowNs: t0).count, 1)
        XCTAssertTrue(buf.push(seq: 12, packet: Data([12]), nowNs: t0).isEmpty)  // gap at 11 held
        // A packet arriving past the deadline abandons the gap (loss declared).
        let releases = buf.push(seq: 13, packet: Data([13]), nowNs: t0 &+ 250_000_000)
        XCTAssertEqual(releases.first?.lostBefore, true, "gap abandoned after the hold expires")
    }

    func testNACKModeDepacketizerReassemblesDeepKeyframeWithLateRetransmit() throws {
        // End-to-end at the depacketizer: a keyframe-sized AU (100 packets)
        // loses an early packet; its retransmit arrives ~160 ms later. In NACK
        // mode (deep window + time hold) the AU must reassemble whole, with no
        // loss flag — the exact path that used to tear the keyframe (the
        // count-based window overflowed in tens of ms) and wedge the viewer.
        let t0: UInt64 = 1_000_000_000
        let nals = (0..<100).map { Data([0x41, UInt8($0)]) }
        let packets = H264Packetizer().packetize(
            nals: nals, timestamp: 50, ssrc: 1, startSequence: 1000)
        XCTAssertEqual(packets.count, 100)

        let depacketizer = H264Depacketizer(reorderDepth: 512, gapHoldNs: 300_000_000)
        // Deliver every packet except seq 1001 (index 1), spread over ~30 ms.
        for (i, pkt) in packets.enumerated() where i != 1 {
            let au = depacketizer.ingest(pkt, nowNs: t0 &+ UInt64(i) &* 300_000)
            XCTAssertNil(au, "AU withheld while the early gap is open")
        }
        // The retransmit of seq 1001 lands ~160 ms later — inside the hold.
        let au = try XCTUnwrap(depacketizer.ingest(packets[1], nowNs: t0 &+ 160_000_000))
        XCTAssertFalse(au.lostBeforeThisAU, "keyframe reassembled intact")
        XCTAssertEqual(AVCCParser.nalUnits(from: au.avcc), nals)
    }

    func testDuplicatePacketIsIgnored() throws {
        // DERP can duplicate packets. A duplicate of an already-released
        // sequence number must be dropped silently, not treated as loss.
        let nal1 = Data([0x41, 0xAA])
        let nal2 = Data([0x41, 0xBB])
        let packets = H264Packetizer().packetize(
            nals: [nal1, nal2], timestamp: 50, ssrc: 1, startSequence: 10
        )
        XCTAssertEqual(packets.count, 2)

        let depacketizer = H264Depacketizer()
        XCTAssertNil(depacketizer.ingest(packets[0]))  // seq 10
        XCTAssertNil(depacketizer.ingest(packets[0]))  // seq 10 again (dup) — dropped
        let au = try XCTUnwrap(depacketizer.ingest(packets[1]))  // seq 11, marker

        XCTAssertFalse(au.lostBeforeThisAU)
        XCTAssertEqual(AVCCParser.nalUnits(from: au.avcc), [nal1, nal2])
    }

    func testSSRCChangeResetsState() throws {
        let nal = Data([0x41, 0x01])
        let packetizer = H264Packetizer()
        let firstSession = packetizer.packetize(
            nals: [nal], timestamp: 1, ssrc: 0xAAAA, startSequence: 50
        )
        // New session (server restart): different SSRC, sequence starts over.
        let secondSession = packetizer.packetize(
            nals: [nal], timestamp: 1, ssrc: 0xBBBB, startSequence: 0
        )

        let depacketizer = H264Depacketizer()
        _ = depacketizer.ingest(firstSession[0])
        // Without SSRC reset, seq=0 after seq=50 would look like a wild
        // jump and the AU would be flagged as lost. SSRC change should
        // wipe state and treat the second session as fresh.
        let au = try XCTUnwrap(depacketizer.ingest(secondSession[0]))
        XCTAssertFalse(au.lostBeforeThisAU)
    }

    // MARK: - HEVC

    /// HEVC NAL header: F=0, Type=t, LayerId=0, TID=1.
    /// byte 0 = (t & 0x3F) << 1; byte 1 = 0x01 (TID=1).
    private static func hevcHeader(type: UInt8) -> [UInt8] {
        return [(type & 0x3F) << 1, 0x01]
    }

    func testHEVCPayloadTypeIsDistinct() {
        XCTAssertNotEqual(RTPHeader.h264PayloadType, RTPHeader.hevcPayloadType)
    }

    func testHEVCSingleNALRoundTrip() throws {
        // VPS=32, SPS=33, PPS=34, IDR_W_RADL=19.
        let vps = Data(Self.hevcHeader(type: 32) + [0x00, 0x00])
        let sps = Data(Self.hevcHeader(type: 33) + [0x11, 0x22])
        let pps = Data(Self.hevcHeader(type: 34) + [0x33])
        var idr = Data(Self.hevcHeader(type: 19))
        idr.append(contentsOf: [0xAA, 0xBB, 0xCC])

        let packets = H265Packetizer().packetize(
            nals: [vps, sps, pps, idr], timestamp: 11_111, ssrc: 0xCAFE_F00D, startSequence: 9
        )
        XCTAssertEqual(packets.count, 4)
        for (i, p) in packets.enumerated() {
            let (header, _) = try XCTUnwrap(RTPHeader.decode(from: p))
            XCTAssertEqual(header.payloadType, RTPHeader.hevcPayloadType)
            XCTAssertEqual(header.sequenceNumber, UInt16(9 + i))
            XCTAssertEqual(header.marker, i == packets.count - 1)
        }

        let depacketizer = H265Depacketizer()
        var au: VideoAccessUnit?
        for p in packets {
            if let result = depacketizer.ingest(p) { au = result }
        }
        let unwrapped = try XCTUnwrap(au)
        XCTAssertEqual(unwrapped.codec, .hevc)
        XCTAssertTrue(unwrapped.containsIDR)
        XCTAssertEqual(unwrapped.timestamp, 11_111)
        XCTAssertFalse(unwrapped.lostBeforeThisAU)
        XCTAssertEqual(AVCCParser.nalUnits(from: unwrapped.avcc), [vps, sps, pps, idr])
    }

    func testHEVCFragmentedNALRoundTrip() throws {
        let bodySize = H265Packetizer.maxPayloadBytes * 3 + 211
        var slice = Data(Self.hevcHeader(type: 19))  // IDR slice
        slice.append(contentsOf: (0..<bodySize).map { UInt8(($0 * 7) & 0xFF) })

        let packets = H265Packetizer().packetize(
            nals: [slice], timestamp: 22_222, ssrc: 1, startSequence: 0xFFFD
        )

        // FU mode reserves 3 bytes per packet (PayloadHdr 2 + FU header 1).
        let fragSize = H265Packetizer.maxPayloadBytes - 3
        let expected = (bodySize + fragSize - 1) / fragSize
        XCTAssertEqual(packets.count, expected)

        // Validate first/last fragment headers.
        let first = packets.first!
        let firstPayload = first.suffix(from: first.startIndex + RTPHeader.size)
        let firstHdr0 = firstPayload[firstPayload.startIndex]
        let firstFU = firstPayload[firstPayload.startIndex + 2]
        XCTAssertEqual((firstHdr0 >> 1) & 0x3F, 49)  // FU type
        XCTAssertEqual(firstFU & 0x3F, 19)  // original type carried in FU header
        XCTAssertNotEqual(firstFU & 0x80, 0)  // S bit on first
        XCTAssertEqual(firstFU & 0x40, 0)  // E bit clear

        let last = packets.last!
        let lastPayload = last.suffix(from: last.startIndex + RTPHeader.size)
        let lastFU = lastPayload[lastPayload.startIndex + 2]
        XCTAssertEqual(lastFU & 0x80, 0)  // S bit clear
        XCTAssertNotEqual(lastFU & 0x40, 0)  // E bit on last

        let depacketizer = H265Depacketizer()
        var au: VideoAccessUnit?
        for p in packets {
            if let result = depacketizer.ingest(p) { au = result }
        }
        let unwrapped = try XCTUnwrap(au)
        XCTAssertEqual(unwrapped.codec, .hevc)
        XCTAssertTrue(unwrapped.containsIDR)
        XCTAssertFalse(unwrapped.lostBeforeThisAU)
        XCTAssertEqual(AVCCParser.nalUnits(from: unwrapped.avcc), [slice])
    }

    func testHEVCDroppedPacketCorruptsAUAndSignalsLoss() {
        let n1 = Data(Self.hevcHeader(type: 1) + [0xAA])
        let n2 = Data(Self.hevcHeader(type: 1) + [0xBB])
        let n3 = Data(Self.hevcHeader(type: 1) + [0xCC])

        let packetizer = H265Packetizer()
        let packets = packetizer.packetize(
            nals: [n1, n2, n3], timestamp: 50, ssrc: 1, startSequence: 10
        )
        XCTAssertEqual(packets.count, 3)

        // reorderDepth: 1 — see the H.264 sibling test; forces the window to
        // give up on the missing packet rather than hold the gap open.
        let depacketizer = H265Depacketizer(reorderDepth: 1)
        _ = depacketizer.ingest(packets[0])
        let result = depacketizer.ingest(packets[2])
        XCTAssertNil(result)  // seq 12 buffered behind the gap; nothing emitted

        let n4 = Data(Self.hevcHeader(type: 1) + [0xDD])
        let next = packetizer.packetize(
            nals: [n4], timestamp: 60, ssrc: 1, startSequence: 13
        )
        let au = depacketizer.ingest(next[0])  // second pile-up: gap given up
        XCTAssertNotNil(au)
        XCTAssertTrue(au?.lostBeforeThisAU ?? false)
    }

    func testHEVCReorderedPacketsRecoverWithoutLoss() throws {
        let n1 = Data(Self.hevcHeader(type: 1) + [0xAA])
        let n2 = Data(Self.hevcHeader(type: 1) + [0xBB])
        let n3 = Data(Self.hevcHeader(type: 1) + [0xCC])
        let packets = H265Packetizer().packetize(
            nals: [n1, n2, n3], timestamp: 50, ssrc: 1, startSequence: 10
        )
        XCTAssertEqual(packets.count, 3)

        let depacketizer = H265Depacketizer()
        XCTAssertNil(depacketizer.ingest(packets[0]))  // seq 10
        XCTAssertNil(depacketizer.ingest(packets[2]))  // seq 12 — held
        let au = try XCTUnwrap(depacketizer.ingest(packets[1]))  // seq 11 fills the gap

        XCTAssertFalse(au.lostBeforeThisAU)
        XCTAssertEqual(AVCCParser.nalUnits(from: au.avcc), [n1, n2, n3])
    }

    func testMultiCodecDepacketizerRoutesByPayloadType() throws {
        // H.264 single NAL packet.
        let h264NAL = Data([0x67, 0x42, 0x00, 0x1F, 0xAC])
        let h264Packets = H264Packetizer().packetize(
            nals: [h264NAL], timestamp: 1, ssrc: 1, startSequence: 0
        )

        // HEVC IDR single NAL packet.
        var hevcNAL = Data(Self.hevcHeader(type: 19))
        hevcNAL.append(contentsOf: [0xDE, 0xAD])
        let hevcPackets = H265Packetizer().packetize(
            nals: [hevcNAL], timestamp: 2, ssrc: 2, startSequence: 100
        )

        let mux = MultiCodecDepacketizer()
        let h264AU = try XCTUnwrap(mux.ingest(h264Packets[0]))
        XCTAssertEqual(h264AU.codec, .h264)
        let hevcAU = try XCTUnwrap(mux.ingest(hevcPackets[0]))
        XCTAssertEqual(hevcAU.codec, .hevc)
        XCTAssertTrue(hevcAU.containsIDR)
    }

    // MARK: - Buffer-pool correctness

    /// Repeatedly packetize through a single instance, retaining every
    /// prior batch the whole time. If the pool ever mutated a buffer that
    /// a previous consumer was still holding, the held bytes would change
    /// out from under them. We verify that doesn't happen by saving each
    /// batch and re-decoding it after many subsequent calls.
    func testPacketizerReuseAcrossManyCallsDoesNotAliasPriorBatches() throws {
        let packetizer = H264Packetizer()
        var saved: [(seq: UInt16, ts: UInt32, packets: [Data])] = []

        // Build a NAL that fits in one MTU so each call's packet count is
        // small and deterministic — keeps the test focused on correctness,
        // not throughput.
        let nal = Data([0x41] + (0..<200).map { UInt8($0 & 0xFF) })

        var seq: UInt16 = 0
        for i in 0..<32 {
            let ts = UInt32(1000 + i * 90)
            let packets = packetizer.packetize(
                nals: [nal], timestamp: ts, ssrc: 0xABCD, startSequence: seq
            )
            saved.append((seq, ts, packets))
            seq &+= UInt16(packets.count)
        }

        // Decode every saved batch through fresh depacketizers; if the
        // pool aliased the bytes of an earlier batch, the seq/ts here
        // would have been overwritten with later values.
        for entry in saved {
            let depacketizer = H264Depacketizer()
            var au: VideoAccessUnit?
            for p in entry.packets {
                if let result = depacketizer.ingest(p) { au = result }
            }
            let unwrapped = try XCTUnwrap(au)
            XCTAssertEqual(unwrapped.timestamp, entry.ts)
            XCTAssertEqual(AVCCParser.nalUnits(from: unwrapped.avcc), [nal])

            // And the RTP header's seq matches what we asked for.
            let (header, _) = try XCTUnwrap(RTPHeader.decode(from: entry.packets[0]))
            XCTAssertEqual(header.sequenceNumber, entry.seq)
            XCTAssertEqual(header.timestamp, entry.ts)
        }
    }

    /// Same test for HEVC, exercising the parallel `H265Packetizer` path.
    func testHEVCPacketizerReuseDoesNotAliasPriorBatches() throws {
        let packetizer = H265Packetizer()
        var saved: [(seq: UInt16, ts: UInt32, packets: [Data])] = []

        var nal = Data(Self.hevcHeader(type: 1))
        nal.append(contentsOf: (0..<200).map { UInt8($0 & 0xFF) })

        var seq: UInt16 = 0
        for i in 0..<32 {
            let ts = UInt32(2000 + i * 90)
            let packets = packetizer.packetize(
                nals: [nal], timestamp: ts, ssrc: 0xCAFE, startSequence: seq
            )
            saved.append((seq, ts, packets))
            seq &+= UInt16(packets.count)
        }

        for entry in saved {
            let depacketizer = H265Depacketizer()
            var au: VideoAccessUnit?
            for p in entry.packets {
                if let result = depacketizer.ingest(p) { au = result }
            }
            let unwrapped = try XCTUnwrap(au)
            XCTAssertEqual(unwrapped.timestamp, entry.ts)
            XCTAssertEqual(AVCCParser.nalUnits(from: unwrapped.avcc), [nal])
        }
    }

    /// Stress the FU-A path so each call returns ≥ 2 packets. Verifies
    /// that buffer reuse across calls produces correct fragment layout
    /// (S/E bits, fragment bytes, marker on last) every time.
    func testPacketizerReuseWithFragmentedNALs() throws {
        let packetizer = H264Packetizer()

        // Each NAL forces ~5 fragments (5500 bytes body ÷ ~1098 per frag).
        let body: [UInt8] = (0..<5500).map { UInt8(($0 * 7) & 0xFF) }
        var nal = Data([0x65])
        nal.append(contentsOf: body)

        var savedBatches: [[Data]] = []
        for i in 0..<20 {
            let packets = packetizer.packetize(
                nals: [nal],
                timestamp: UInt32(10_000 + i * 90),
                ssrc: 0xBEEF,
                startSequence: UInt16(i * 10)
            )
            XCTAssertGreaterThan(packets.count, 1)  // ensure fragmented
            savedBatches.append(packets)
        }

        // Round-trip every saved batch — bytes must still be intact.
        for batch in savedBatches {
            let dp = H264Depacketizer()
            var au: VideoAccessUnit?
            for p in batch {
                if let result = dp.ingest(p) { au = result }
            }
            let unwrapped = try XCTUnwrap(au)
            XCTAssertEqual(AVCCParser.nalUnits(from: unwrapped.avcc), [nal])

            // Marker bit must be set ONLY on the last packet of each batch.
            for (i, p) in batch.enumerated() {
                let isLast = i == batch.count - 1
                let (header, _) = try XCTUnwrap(RTPHeader.decode(from: p))
                XCTAssertEqual(header.marker, isLast, "packet \(i) marker mismatch")
            }
        }
    }

    /// Marker bit on the last packet must be set even when reusing a
    /// pooled buffer that, in a *previous* batch, was the marker-bearing
    /// packet for that batch. Header encode writes byte 1 fresh, so the
    /// marker from the prior packet should not leak.
    func testMarkerBitDoesNotLeakAcrossPooledReuse() throws {
        let packetizer = H264Packetizer()

        // First batch: 3 packets. Last gets marker.
        let nal = Data([0x41, 0x01, 0x02, 0x03])
        let b1 = packetizer.packetize(nals: [nal, nal, nal], timestamp: 100, ssrc: 1, startSequence: 0)
        XCTAssertEqual(b1.count, 3)
        let (h1_0, _) = try XCTUnwrap(RTPHeader.decode(from: b1[0]))
        let (h1_1, _) = try XCTUnwrap(RTPHeader.decode(from: b1[1]))
        let (h1_2, _) = try XCTUnwrap(RTPHeader.decode(from: b1[2]))
        XCTAssertFalse(h1_0.marker)
        XCTAssertFalse(h1_1.marker)
        XCTAssertTrue(h1_2.marker)

        // Drop our hold on b1 so the pool's buffers go to refcount=1 and
        // can be reused in place on the next call.
        _ = b1.count  // ensure b1 isn't optimized away before this point
        // Second batch: 3 packets. The pool may hand us back the same
        // underlying buffers; the marker bit must reflect this batch's
        // own last-packet status, not the previous batch's.
        let b2 = packetizer.packetize(nals: [nal, nal, nal], timestamp: 200, ssrc: 1, startSequence: 10)
        XCTAssertEqual(b2.count, 3)
        let (h2_0, _) = try XCTUnwrap(RTPHeader.decode(from: b2[0]))
        let (h2_1, _) = try XCTUnwrap(RTPHeader.decode(from: b2[1]))
        let (h2_2, _) = try XCTUnwrap(RTPHeader.decode(from: b2[2]))
        XCTAssertFalse(h2_0.marker)
        XCTAssertFalse(h2_1.marker)
        XCTAssertTrue(h2_2.marker)
    }

    // MARK: - Depacketizer pre-allocation

    /// Large fragmented AU (~600 KB) should reassemble correctly. This
    /// exercises the pre-allocated `currentAU` buffer — if pre-allocation
    /// were sized wrong, Data would still grow on demand, but this test
    /// also verifies bytes survive that growth intact.
    func testLargeFragmentedAUDepacketizesCorrectly() throws {
        let packetizer = H264Packetizer()
        // Build a ~600 KB IDR slice (10x typical 60 KB P-frame).
        let bodySize = 600 * 1024
        var slice = Data([0x65])  // IDR slice NAL header
        slice.append(contentsOf: (0..<bodySize).map { UInt8(($0 * 31) & 0xFF) })

        let packets = packetizer.packetize(
            nals: [slice], timestamp: 5_000, ssrc: 1, startSequence: 0
        )
        XCTAssertGreaterThan(packets.count, 500)  // ~600 KB / ~1098 frag

        let depacketizer = H264Depacketizer()
        var au: VideoAccessUnit?
        for p in packets {
            if let result = depacketizer.ingest(p) { au = result }
        }
        let unwrapped = try XCTUnwrap(au)
        XCTAssertTrue(unwrapped.containsIDR)
        XCTAssertEqual(AVCCParser.nalUnits(from: unwrapped.avcc), [slice])
    }

    /// Many AUs in a row through one depacketizer instance — the buffer
    /// pre-allocation should keep `currentAU` capacity stable across
    /// flushes (each new AU starts with the pre-reserved capacity, not
    /// growing from zero).
    func testDepacketizerHandlesManyAUsInARow() throws {
        let packetizer = H264Packetizer()
        let depacketizer = H264Depacketizer()

        let nal = Data([0x41] + (0..<500).map { UInt8($0 & 0xFF) })

        for i in 0..<100 {
            let packets = packetizer.packetize(
                nals: [nal], timestamp: UInt32(i * 90), ssrc: 1, startSequence: UInt16(i)
            )
            var au: VideoAccessUnit?
            for p in packets {
                if let result = depacketizer.ingest(p) { au = result }
            }
            let unwrapped = try XCTUnwrap(au)
            XCTAssertEqual(unwrapped.timestamp, UInt32(i * 90))
            XCTAssertEqual(AVCCParser.nalUnits(from: unwrapped.avcc), [nal])
        }
    }
}

extension Data {
    fileprivate mutating func appendBE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}

final class HelloAckTests: XCTestCase {
    func testEncodeProducesFiveBytes() {
        let data = ScreenShareControlMessage.encodeHelloAck(ssrc: 0xDEADBEEF)
        XCTAssertEqual(data.count, 5)
        XCTAssertEqual(data[0], 0x04)
        XCTAssertEqual(data[1], 0xDE)
        XCTAssertEqual(data[2], 0xAD)
        XCTAssertEqual(data[3], 0xBE)
        XCTAssertEqual(data[4], 0xEF)
    }

    func testDecodeRoundtrip() {
        let data = ScreenShareControlMessage.encodeHelloAck(ssrc: 12345)
        XCTAssertEqual(ScreenShareControlMessage.decodeHelloAck(data), 12345)
    }

    func testDecodeRejectsWrongLength() {
        XCTAssertNil(ScreenShareControlMessage.decodeHelloAck(Data([0x04, 0x00, 0x00])))
    }

    func testDecodeRejectsWrongTag() {
        XCTAssertNil(ScreenShareControlMessage.decodeHelloAck(Data([0x00, 0x00, 0x00, 0x00, 0x00])))
    }

    func testLooksLikeControlStillTrueForHelloAck() {
        let data = ScreenShareControlMessage.encodeHelloAck(ssrc: 1)
        XCTAssertTrue(ScreenShareControlMessage.looksLikeControl(data))
    }

    func testRTPHeaderAACPayloadType() {
        XCTAssertEqual(RTPHeader.aacPayloadType, 98)
        XCTAssertEqual(RTPHeader.audioClockHz, 48_000)
    }
}

/// Wire codecs for the loss-recovery control messages (NACK / receiver report
/// / ping) and the capability handshake that negotiates them. Backward
/// compatibility is the load-bearing property: new bytes stay ≤ 0x7F so
/// `looksLikeControl` is untouched, and the extended HELLO_ACK is rejected by
/// the legacy 5-byte `decodeHelloAck` — that rejection is exactly what keeps an
/// old viewer on the PLI path.
final class LossRecoveryWireTests: XCTestCase {
    /// Round-trip only — the exact byte values (and the ≤ 0x7F control-range
    /// invariant across every case) are pinned by `WireByteRegistryTests`,
    /// the single source of truth for wire constants.
    func testNewControlBytesRoundTrip() {
        let kinds: [ScreenShareControlMessage] = [.nack, .receiverReport, .ping]
        for kind in kinds {
            let data = ScreenShareControlMessage.encode(kind)
            XCTAssertTrue(ScreenShareControlMessage.looksLikeControl(data))
            XCTAssertEqual(ScreenShareControlMessage.decode(data), kind)
        }
    }

    func testNACKRoundTrip() {
        let entries: [(pid: UInt16, blp: UInt16)] = [(0x0102, 0x0304), (0x1000, 0x00FF)]
        let data = ScreenShareControlMessage.encodeNACK(entries)
        XCTAssertEqual(data[data.startIndex], 0x0A)
        XCTAssertEqual(data.count, 2 + entries.count * 4)
        let decoded = ScreenShareControlMessage.decodeNACK(data)
        XCTAssertEqual(decoded.count, entries.count)
        XCTAssertEqual(decoded[0].pid, 0x0102)
        XCTAssertEqual(decoded[0].blp, 0x0304)
        XCTAssertEqual(decoded[1].pid, 0x1000)
        XCTAssertEqual(decoded[1].blp, 0x00FF)
    }

    func testNACKWrapSpanningEntriesRoundTrip() {
        // A gap set spanning the 65535 → 0 wrap packs into two FCI groups
        // (packFCI's numeric sort splits at the boundary — pinned in
        // NACKSchedulerTests); the wire codec must carry both groups intact.
        let entries = NACKScheduler.packFCI([65534, 65535, 0, 1])
        let data = ScreenShareControlMessage.encodeNACK(entries)
        let decoded = ScreenShareControlMessage.decodeNACK(data)
        XCTAssertEqual(decoded.count, entries.count)
        for (got, sent) in zip(decoded, entries) {
            XCTAssertEqual(got.pid, sent.pid)
            XCTAssertEqual(got.blp, sent.blp)
        }
    }

    func testNACKCapsAtSixteenEntries() {
        let entries = (0..<40).map { (pid: UInt16($0), blp: UInt16(0)) }
        let data = ScreenShareControlMessage.encodeNACK(entries)
        XCTAssertEqual(ScreenShareControlMessage.decodeNACK(data).count, 16)
    }

    func testNACKDecodeRejectsTruncated() {
        // Claims 2 entries but carries only one entry's worth of bytes.
        let bad = Data([0x0A, 0x02, 0x00, 0x01, 0x00, 0x02])
        XCTAssertTrue(ScreenShareControlMessage.decodeNACK(bad).isEmpty)
    }

    func testReceiverReportRoundTrip() {
        let report = ReceiverReport(
            fracLostQ8: 42, extHighestSeq: 0x0001_2345, jitterTicks: 987,
            lastPingTs: 0x0102_0304_0506_0708, delaySincePingMs: 250)
        let data = ScreenShareControlMessage.encodeReceiverReport(report)
        XCTAssertEqual(data.count, 20)
        XCTAssertEqual(data[data.startIndex], 0x0B)
        XCTAssertEqual(ScreenShareControlMessage.decodeReceiverReport(data), report)
    }

    func testReceiverReportRejectsShort() {
        XCTAssertNil(ScreenShareControlMessage.decodeReceiverReport(Data([0x0B, 0x00])))
    }

    func testPingRoundTrip() {
        let data = ScreenShareControlMessage.encodePing(serverUptimeNs: 0xDEAD_BEEF_CAFE_F00D)
        XCTAssertEqual(data.count, 9)
        XCTAssertEqual(ScreenShareControlMessage.decodePing(data), 0xDEAD_BEEF_CAFE_F00D)
    }

    func testHelloCapsHandshake() {
        let caps: ScreenShareCaps = [.nack, .receiverReport]
        let hello = ScreenShareControlMessage.encodeHello(caps: caps)
        XCTAssertEqual(hello, Data([0x00, 0x03]))
        XCTAssertEqual(ScreenShareControlMessage.decodeHelloCaps(hello), caps)
        // Legacy 1-byte HELLO advertises no capabilities.
        XCTAssertEqual(ScreenShareControlMessage.decodeHelloCaps(Data([0x00])), [])
    }

    // MARK: - FEC (0x0D) wire codec + extended receiver report

    func testFECControlByteIsDistinctAndInControlRange() {
        XCTAssertEqual(ScreenShareControlMessage.fec.rawValue, 0x0D)
        let minimalBody = Data(count: FECCodec.minBodyBytes)
        let data = ScreenShareControlMessage.encodeFEC(baseSeq: 1, count: 2, body: minimalBody)
        XCTAssertTrue(ScreenShareControlMessage.looksLikeControl(data))
        XCTAssertLessThanOrEqual(ScreenShareControlMessage.fec.rawValue, 0x7F)
        XCTAssertEqual(ScreenShareControlMessage.decode(data), .fec)
        // Legacy-peer proof: an old peer's decode of the raw byte is what the
        // unknown-byte → nil contract covers (0x0D was exactly such a byte to
        // pre-FEC peers, as 0x0E is to us today); pin that contract, and that
        // the caps bit is the advertised one.
        XCTAssertNil(ScreenShareControlMessage.decode(Data([0x0E])), "unknown control bytes decode to nil")
        XCTAssertEqual(ScreenShareCaps.fec.rawValue, 1 << 2)
    }

    func testFECRoundTrip() {
        var body = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11])
        body.append(contentsOf: (0..<64).map { UInt8($0) })
        let data = ScreenShareControlMessage.encodeFEC(baseSeq: 0xFFFE, count: 10, body: body)
        XCTAssertEqual(data.count, 4 + body.count)
        let decoded = ScreenShareControlMessage.decodeFEC(data)
        XCTAssertEqual(decoded?.baseSeq, 0xFFFE)
        XCTAssertEqual(decoded?.count, 10)
        XCTAssertEqual(decoded?.body, body)
    }

    func testFECRoundTripMaxSizeBody() {
        // Max envelope: 7-byte XOR prefix + a full 1100-byte payload region —
        // same MTU reasoning as a media packet.
        let body = Data((0..<(7 + H264Packetizer.maxPayloadBytes)).map { UInt8($0 & 0xFF) })
        let data = ScreenShareControlMessage.encodeFEC(baseSeq: 42, count: 16, body: body)
        let decoded = ScreenShareControlMessage.decodeFEC(data)
        XCTAssertEqual(decoded?.baseSeq, 42)
        XCTAssertEqual(decoded?.count, 16)
        XCTAssertEqual(decoded?.body, body)
    }

    func testFECDecodeRejectsTruncatedAndGarbage() {
        XCTAssertNil(ScreenShareControlMessage.decodeFEC(Data([0x0D])), "no header")
        XCTAssertNil(ScreenShareControlMessage.decodeFEC(Data([0x0D, 0x00, 0x01, 0x02])), "no body")
        XCTAssertNil(
            ScreenShareControlMessage.decodeFEC(Data([0x0D, 0x00, 0x01, 0x02, 0xAA, 0xBB])),
            "body shorter than the XOR prefix")
        let okBody = Data(count: FECCodec.minBodyBytes)
        XCTAssertNil(
            ScreenShareControlMessage.decodeFEC(
                ScreenShareControlMessage.encodeFEC(baseSeq: 0, count: 1, body: okBody)),
            "count below minGroupSize")
        XCTAssertNil(
            ScreenShareControlMessage.decodeFEC(
                ScreenShareControlMessage.encodeFEC(baseSeq: 0, count: 17, body: okBody)),
            "count above maxGroupSize")
        var wrongTag = ScreenShareControlMessage.encodeFEC(baseSeq: 0, count: 2, body: okBody)
        wrongTag[wrongTag.startIndex] = 0x0C
        XCTAssertNil(ScreenShareControlMessage.decodeFEC(wrongTag), "wrong control byte")
        // Body-length sanity cap: nothing legitimate exceeds the XOR prefix
        // plus one full MTU payload region.
        let oversized = Data(count: FECCodec.maxBodyBytes + 1)
        XCTAssertNil(
            ScreenShareControlMessage.decodeFEC(
                ScreenShareControlMessage.encodeFEC(baseSeq: 0, count: 2, body: oversized)),
            "oversized body must reject")
        let maxOK = Data(count: FECCodec.maxBodyBytes)
        XCTAssertNotNil(
            ScreenShareControlMessage.decodeFEC(
                ScreenShareControlMessage.encodeFEC(baseSeq: 0, count: 2, body: maxOK)),
            "exactly max-sized body must decode")
    }

    func testExtendedReceiverReportBothLengths() {
        let report = ReceiverReport(
            fracLostQ8: 3, extHighestSeq: 0x0002_0001, jitterTicks: 0,
            lastPingTs: 77, delaySincePingMs: 9, fecRecovered: 1234)
        // Default encode stays the exact legacy 20-byte layout.
        let legacy = ScreenShareControlMessage.encodeReceiverReport(report)
        XCTAssertEqual(legacy.count, 20)
        let legacyDecoded = ScreenShareControlMessage.decodeReceiverReport(legacy)
        XCTAssertEqual(legacyDecoded?.fecRecovered, 0, "20-byte form reads fecRecovered as 0")
        XCTAssertEqual(legacyDecoded?.fracLostQ8, 3)
        // Extended 24-byte form round-trips the recovery fields.
        let extended = ScreenShareControlMessage.encodeReceiverReport(report, includeRecoveryFields: true)
        XCTAssertEqual(extended.count, 24)
        XCTAssertEqual(ScreenShareControlMessage.decodeReceiverReport(extended), report)
        // And the extended form is still one tolerant decode away for a
        // NACK-era server (its `>= 20` guard reads the first 20 bytes).
        XCTAssertEqual(ScreenShareControlMessage.decodeReceiverReport(extended)?.fracLostQ8, 3)
    }

    func testReceiverReportNackRecoveredRoundTrip() {
        // The FEC arm reconstructs raw link loss as residual + recovered. NACK
        // recoveries mask loss too (a served retransmit counts as received), so
        // without carrying the NACK-recovered count the arm can't see raw loss
        // once NACK is working — FEC never gates on a high-RTT lossy link. The
        // 24-byte extended RR carries both recovery counters.
        let report = ReceiverReport(
            fracLostQ8: 3, extHighestSeq: 0x0002_0001, jitterTicks: 0,
            lastPingTs: 77, delaySincePingMs: 9, fecRecovered: 1234, nackRecovered: 567)
        let extended = ScreenShareControlMessage.encodeReceiverReport(report, includeRecoveryFields: true)
        XCTAssertEqual(extended.count, 24)
        XCTAssertEqual(ScreenShareControlMessage.decodeReceiverReport(extended), report)

        // A 22-byte (FEC-era, pre-NACK-counter) report reads nackRecovered as 0
        // but still round-trips fecRecovered.
        var short22 = extended
        short22.removeLast(2)
        XCTAssertEqual(short22.count, 22)
        XCTAssertEqual(ScreenShareControlMessage.decodeReceiverReport(short22)?.nackRecovered, 0)
        XCTAssertEqual(ScreenShareControlMessage.decodeReceiverReport(short22)?.fecRecovered, 1234)

        // Legacy 20-byte reads both counters as 0.
        let legacy = ScreenShareControlMessage.encodeReceiverReport(report)
        XCTAssertEqual(legacy.count, 20)
        XCTAssertEqual(ScreenShareControlMessage.decodeReceiverReport(legacy)?.nackRecovered, 0)
    }

    func testExtendedHelloAckBackCompat() {
        let extended = ScreenShareControlMessage.encodeHelloAck(ssrc: 0xAABB_CCDD, caps: [.nack])
        XCTAssertEqual(extended.count, 6)
        // The compat mechanism: legacy strict decode rejects the 6-byte form.
        XCTAssertNil(ScreenShareControlMessage.decodeHelloAck(extended))
        // The tolerant decode reads both forms.
        let parsedExtended = ScreenShareControlMessage.decodeHelloAckCaps(extended)
        XCTAssertEqual(parsedExtended?.ssrc, 0xAABB_CCDD)
        XCTAssertEqual(parsedExtended?.caps, [.nack])
        let legacy = ScreenShareControlMessage.encodeHelloAck(ssrc: 12345)
        let parsedLegacy = ScreenShareControlMessage.decodeHelloAckCaps(legacy)
        XCTAssertEqual(parsedLegacy?.ssrc, 12345)
        XCTAssertEqual(parsedLegacy?.caps, [])
    }
}
