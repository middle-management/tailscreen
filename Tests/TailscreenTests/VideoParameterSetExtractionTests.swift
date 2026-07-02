import XCTest

@testable import Tailscreen

/// Unit tests for `TailscaleScreenShareClient.extractParameterSets` — the
/// viewer-side pull of in-band parameter sets out of an IDR access unit.
/// The server prepends SPS+PPS (H.264) or VPS+SPS+PPS (HEVC) on every
/// keyframe so a late joiner can decode the first AU it sees; this is the
/// parsing that makes that work.
final class VideoParameterSetExtractionTests: XCTestCase {

    private func avcc(_ nals: [Data]) -> Data {
        var out = Data()
        for nal in nals {
            out.appendBE(UInt32(nal.count))
            out.append(nal)
        }
        return out
    }

    private func au(_ nals: [Data], codec: VideoCodec) -> VideoAccessUnit {
        VideoAccessUnit(
            avcc: avcc(nals), containsIDR: true, timestamp: 9000,
            lostBeforeThisAU: false, codec: codec)
    }

    // H.264 NAL type lives in the low 5 bits of byte 0.
    private let h264SPS = Data([0x67, 0x42, 0x00, 0x1F, 0xAC])  // type 7
    private let h264PPS = Data([0x68, 0xCE, 0x3C, 0x80])  // type 8
    private let h264IDR = Data([0x65] + Array(repeating: UInt8(0x99), count: 20))  // type 5

    // HEVC NAL type lives in bits 1-6 of byte 0 (two-byte NAL header).
    private let hevcVPS = Data([0x40, 0x01, 0x0C, 0x01])  // type 32
    private let hevcSPS = Data([0x42, 0x01, 0x01, 0x01])  // type 33
    private let hevcPPS = Data([0x44, 0x01, 0xC0, 0x62])  // type 34
    private let hevcIDR = Data([0x26, 0x01] + Array(repeating: UInt8(0x99), count: 20))  // type 19

    func testH264KeyframeYieldsSPSAndPPS() throws {
        let params = TailscaleScreenShareClient.extractParameterSets(
            from: au([h264SPS, h264PPS, h264IDR], codec: .h264))
        XCTAssertEqual(params, .h264(sps: h264SPS, pps: h264PPS))
    }

    func testH264MissingPPSYieldsNil() {
        XCTAssertNil(
            TailscaleScreenShareClient.extractParameterSets(
                from: au([h264SPS, h264IDR], codec: .h264)))
    }

    func testH264SliceOnlyAUYieldsNil() {
        // An AU flagged IDR but without in-band parameter sets (shouldn't
        // happen with our server, but a lossy reassembly could tear them
        // off) must not fabricate parameters.
        XCTAssertNil(
            TailscaleScreenShareClient.extractParameterSets(
                from: au([h264IDR], codec: .h264)))
    }

    func testHEVCKeyframeYieldsVPSSPSAndPPS() throws {
        let params = TailscaleScreenShareClient.extractParameterSets(
            from: au([hevcVPS, hevcSPS, hevcPPS, hevcIDR], codec: .hevc))
        XCTAssertEqual(params, .hevc(vps: hevcVPS, sps: hevcSPS, pps: hevcPPS))
    }

    func testHEVCMissingVPSYieldsNil() {
        // HEVC needs all three; two out of three is not decodable.
        XCTAssertNil(
            TailscaleScreenShareClient.extractParameterSets(
                from: au([hevcSPS, hevcPPS, hevcIDR], codec: .hevc)))
    }

    func testCodecFieldSelectsTheParsingRules() {
        // The same bytes read as H.264 must not be misread as HEVC
        // parameters: an H.264 SPS (0x67) parsed under HEVC rules is NAL
        // type (0x67 >> 1) & 0x3F = 51 — not a parameter set.
        XCTAssertNil(
            TailscaleScreenShareClient.extractParameterSets(
                from: au([h264SPS, h264PPS, h264IDR], codec: .hevc)))
    }

    func testEmptyAUYieldsNil() {
        XCTAssertNil(
            TailscaleScreenShareClient.extractParameterSets(from: au([], codec: .h264)))
        XCTAssertNil(
            TailscaleScreenShareClient.extractParameterSets(from: au([], codec: .hevc)))
    }

    func testLastParameterSetWinsOnDuplicates() throws {
        // If an AU somehow carries two SPS NALs the later one wins — mirrors
        // the decoder installing the freshest parameters.
        let altSPS = Data([0x67, 0x64, 0x00, 0x28])
        let params = TailscaleScreenShareClient.extractParameterSets(
            from: au([h264SPS, altSPS, h264PPS, h264IDR], codec: .h264))
        XCTAssertEqual(params, .h264(sps: altSPS, pps: h264PPS))
    }
}
