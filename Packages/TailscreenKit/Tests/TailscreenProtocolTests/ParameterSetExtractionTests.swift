import XCTest

@testable import TailscreenProtocol

/// Tests for `ParameterSetExtraction` — the shared "which NAL is the SPS"
/// step every libavcodec-based `CaptureEncoding` backend performs.
///
/// The bug worth pinning is not "it failed to find a parameter set". It is
/// that H.264 and HEVC carry the NAL type in DIFFERENT bits of the header
/// byte, so reading one with the other's mask yields a plausible-looking
/// wrong number instead of an error. That failure is silent in the worst way:
/// the sharer's own preview is perfect, the encoder is fine, viewers just
/// never receive parameter sets and sit on black. So the interesting cases
/// here are the crossed ones.
final class ParameterSetExtractionTests: XCTestCase {
    /// An H.264 NAL: type in the low five bits, high bit zero.
    private func h264NAL(type: UInt8, body: [UInt8] = [0xAA, 0xBB]) -> Data {
        Data([type & 0x1F] + body)
    }

    /// An HEVC NAL: type in bits 1–6, so the header byte is `type << 1`.
    private func hevcNAL(type: UInt8, body: [UInt8] = [0xCC, 0xDD]) -> Data {
        Data([(type & 0x3F) << 1, 0x01] + body)
    }

    // MARK: H.264

    func testH264FindsSPSAndPPS() {
        let sps = h264NAL(type: 7, body: [0x01])
        let pps = h264NAL(type: 8, body: [0x02])
        // Interleaved with an ordinary IDR slice, which is what a real
        // keyframe looks like — the extractor must ignore it.
        let nals = [sps, pps, h264NAL(type: 5, body: [0x03])]

        guard
            case .h264(let gotSPS, let gotPPS)? =
                ParameterSetExtraction.parameterSets(fromAnnexBNALs: nals, codec: .h264)
        else { return XCTFail("expected h264 parameter sets") }
        XCTAssertEqual(gotSPS, sps)
        XCTAssertEqual(gotPPS, pps)
    }

    func testH264MissingPPSYieldsNil() {
        let nals = [h264NAL(type: 7), h264NAL(type: 5)]
        XCTAssertNil(ParameterSetExtraction.parameterSets(fromAnnexBNALs: nals, codec: .h264))
    }

    // MARK: HEVC

    func testHEVCFindsVPSSPSAndPPS() {
        let vps = hevcNAL(type: 32, body: [0x01])
        let sps = hevcNAL(type: 33, body: [0x02])
        let pps = hevcNAL(type: 34, body: [0x03])
        let nals = [vps, sps, pps, hevcNAL(type: 19, body: [0x04])]

        guard
            case .hevc(let gotVPS, let gotSPS, let gotPPS)? =
                ParameterSetExtraction.parameterSets(fromAnnexBNALs: nals, codec: .hevc)
        else { return XCTFail("expected hevc parameter sets") }
        XCTAssertEqual(gotVPS, vps)
        XCTAssertEqual(gotSPS, sps)
        XCTAssertEqual(gotPPS, pps)
    }

    func testHEVCMissingVPSYieldsNil() {
        // SPS and PPS present, VPS absent: all-or-nothing, because a partial
        // set only moves the failure to the viewer's decoder.
        let nals = [hevcNAL(type: 33), hevcNAL(type: 34)]
        XCTAssertNil(ParameterSetExtraction.parameterSets(fromAnnexBNALs: nals, codec: .hevc))
    }

    // MARK: The masks are not interchangeable

    func testHEVCNALsReadAsH264YieldNil() {
        // HEVC VPS/SPS/PPS are header bytes 0x40/0x42/0x44. Masked with the
        // H.264 `& 0x1F` those read as types 0, 2 and 4 — none of which is 7
        // or 8, so the answer is a clean nil rather than a wrong set.
        let nals = [hevcNAL(type: 32), hevcNAL(type: 33), hevcNAL(type: 34)]
        XCTAssertNil(ParameterSetExtraction.parameterSets(fromAnnexBNALs: nals, codec: .h264))
    }

    func testH264NALsReadAsHEVCYieldNil() {
        let nals = [h264NAL(type: 7), h264NAL(type: 8)]
        XCTAssertNil(ParameterSetExtraction.parameterSets(fromAnnexBNALs: nals, codec: .hevc))
    }

    func testH264MaskIgnoresTheTopThreeBits() {
        // nal_ref_idc lives in bits 5–6 and the forbidden_zero_bit in bit 7.
        // A real encoder sets nal_ref_idc on parameter sets, so a naive
        // whole-byte comparison would miss every one of them.
        let sps = Data([0x67, 0x01])  // nal_ref_idc = 3, type 7
        let pps = Data([0x68, 0x02])
        guard
            case .h264? =
                ParameterSetExtraction.parameterSets(fromAnnexBNALs: [sps, pps], codec: .h264)
        else { return XCTFail("expected the reference-idc bits to be masked off") }
    }

    // MARK: Degenerate input

    func testEmptyNALsAreSkippedNotIndexed() {
        // A zero-length NAL has no header byte. It must be dropped, not
        // indexed under some default type where it could displace a real one.
        let sps = h264NAL(type: 7)
        let pps = h264NAL(type: 8)
        guard
            case .h264(let gotSPS, _)? = ParameterSetExtraction.parameterSets(
                fromAnnexBNALs: [Data(), sps, Data(), pps], codec: .h264)
        else { return XCTFail("expected parameter sets around the empty NALs") }
        XCTAssertEqual(gotSPS, sps)
    }

    func testNoNALsYieldNil() {
        XCTAssertNil(ParameterSetExtraction.parameterSets(fromAnnexBNALs: [], codec: .h264))
        XCTAssertNil(ParameterSetExtraction.parameterSets(fromAnnexBNALs: [], codec: .hevc))
    }

    func testDuplicateTypeKeepsTheFirst() {
        let first = h264NAL(type: 7, body: [0x11])
        let second = h264NAL(type: 7, body: [0x22])
        guard
            case .h264(let gotSPS, _)? = ParameterSetExtraction.parameterSets(
                fromAnnexBNALs: [first, second, h264NAL(type: 8)], codec: .h264)
        else { return XCTFail("expected h264 parameter sets") }
        XCTAssertEqual(gotSPS, first, "the documented rule is first-wins")
    }
}
