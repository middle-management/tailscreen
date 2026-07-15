import CoreGraphics
import CoreVideo
import VideoToolbox
import XCTest

@testable import Tailscreen

/// Pure-decision tests for the wide-gamut / 10-bit / HDR color pipeline.
/// No GPU, display, VideoToolbox session, or tsnet node — just the
/// `ColorInfo` model (space selection, VT-key + CGColorSpace mappings, bit-
/// depth fallback) and `VideoEncoder`'s fallback-ladder ordering, so these
/// run on CI where the live encode/decode/render paths can't.
final class ColorInfoTests: XCTestCase {

    // MARK: - Space selection for a display's capabilities

    func testForDisplaySDR() {
        let info = ColorInfo.forDisplay(wideGamut: false, hdrCapable: false, bitDepth: 8)
        XCTAssertEqual(info, ColorInfo.bt709FullRange8)
        XCTAssertEqual(info.primaries, .bt709)
        XCTAssertEqual(info.transfer, .bt709)
        XCTAssertEqual(info.matrix, .bt709)
        XCTAssertEqual(info.bitDepth, 8)
        XCTAssertTrue(info.fullRange)
    }

    func testForDisplayWideGamutStays709Transfer() {
        let info = ColorInfo.forDisplay(wideGamut: true, hdrCapable: false, bitDepth: 8)
        XCTAssertEqual(info.primaries, .displayP3)
        // "P3 in a 709 container": primaries widen, transfer/matrix stay 709.
        XCTAssertEqual(info.transfer, .bt709)
        XCTAssertEqual(info.matrix, .bt709)
        XCTAssertEqual(info.bitDepth, 8)
    }

    func testForDisplayWideGamut10Bit() {
        let info = ColorInfo.forDisplay(wideGamut: true, hdrCapable: false, bitDepth: 10)
        XCTAssertEqual(info.primaries, .displayP3)
        XCTAssertEqual(info.bitDepth, 10)
    }

    func testForDisplayHDRPicks2020PQ() {
        let info = ColorInfo.forDisplay(wideGamut: true, hdrCapable: true, bitDepth: 10)
        XCTAssertEqual(info.primaries, .bt2020)
        XCTAssertEqual(info.transfer, .pq)
        XCTAssertEqual(info.matrix, .bt2020)
        XCTAssertEqual(info.bitDepth, 10)
    }

    func testForDisplayHDRWithout10BitFallsToP3() {
        // HDR-capable but only 8-bit requested: no PQ, just wide gamut.
        let info = ColorInfo.forDisplay(wideGamut: true, hdrCapable: true, bitDepth: 8)
        XCTAssertEqual(info.primaries, .displayP3)
        XCTAssertEqual(info.transfer, .bt709)
        XCTAssertEqual(info.bitDepth, 8)
    }

    // MARK: - VideoToolbox key mappings

    func testPrimariesVTKeys() {
        let bt709 = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        let p3 = kCVImageBufferColorPrimaries_P3_D65 as String
        let bt2020 = kCVImageBufferColorPrimaries_ITU_R_2020 as String
        XCTAssertEqual(ColorInfo.Primaries.bt709.vtKey as String, bt709)
        XCTAssertEqual(ColorInfo.Primaries.displayP3.vtKey as String, p3)
        XCTAssertEqual(ColorInfo.Primaries.bt2020.vtKey as String, bt2020)
    }

    func testTransferVTKeys() {
        let bt709 = kCVImageBufferTransferFunction_ITU_R_709_2 as String
        let pq = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        let hlg = kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        XCTAssertEqual(ColorInfo.Transfer.bt709.vtKey as String, bt709)
        XCTAssertEqual(ColorInfo.Transfer.pq.vtKey as String, pq)
        XCTAssertEqual(ColorInfo.Transfer.hlg.vtKey as String, hlg)
    }

    func testMatrixVTKeys() {
        let bt709 = kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        let bt2020 = kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
        XCTAssertEqual(ColorInfo.Matrix.bt709.vtKey as String, bt709)
        XCTAssertEqual(ColorInfo.Matrix.bt2020.vtKey as String, bt2020)
    }

    // MARK: - Profile selection

    func testProfileLevelSelection() {
        let sdr = ColorInfo.bt709FullRange8
        let hdr = ColorInfo.forDisplay(wideGamut: true, hdrCapable: true, bitDepth: 10)
        let main = kVTProfileLevel_HEVC_Main_AutoLevel as String
        let main10 = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        let high = kVTProfileLevel_H264_High_AutoLevel as String
        XCTAssertEqual(sdr.profileLevel(for: .hevc) as String, main)
        XCTAssertEqual(hdr.profileLevel(for: .hevc) as String, main10)
        // H.264 is always High — this pipeline never emits 10-bit H.264.
        XCTAssertEqual(sdr.profileLevel(for: .h264) as String, high)
        XCTAssertEqual(hdr.profileLevel(for: .h264) as String, high)
    }

    // MARK: - Capture pixel format + colorspace

    func testCapturePixelFormat() {
        let sdr = ColorInfo.bt709FullRange8
        XCTAssertEqual(sdr.capturePixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let tenBit = ColorInfo.forDisplay(wideGamut: true, hdrCapable: true, bitDepth: 10)
        XCTAssertEqual(tenBit.capturePixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        var limited = sdr
        limited.fullRange = false
        XCTAssertEqual(limited.capturePixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    func testCaptureColorSpaceNameOnlyOverridesNon709() {
        // BT.709 leaves SCStream at its default (nil) — the shipped path.
        XCTAssertNil(ColorInfo.bt709FullRange8.captureColorSpaceName)
        let p3 = ColorInfo.forDisplay(wideGamut: true, hdrCapable: false, bitDepth: 8)
        XCTAssertEqual(p3.captureColorSpaceName as String?, CGColorSpace.displayP3 as String)
        let hdr = ColorInfo.forDisplay(wideGamut: true, hdrCapable: true, bitDepth: 10)
        XCTAssertEqual(hdr.captureColorSpaceName as String?, CGColorSpace.itur_2100_PQ as String)
    }

    // MARK: - Renderer-side colorspace derivation

    func testLayerColorSpaceNameFromPrimaries() {
        let bt709 = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        let p3 = kCVImageBufferColorPrimaries_P3_D65 as String
        let bt2020 = kCVImageBufferColorPrimaries_ITU_R_2020 as String
        let srgbName = CGColorSpace.sRGB as String
        XCTAssertEqual(ColorInfo.layerColorSpaceName(forPrimaries: nil) as String, srgbName)
        XCTAssertEqual(ColorInfo.layerColorSpaceName(forPrimaries: bt709) as String, srgbName)
        let p3Name = ColorInfo.layerColorSpaceName(forPrimaries: p3) as String
        XCTAssertEqual(p3Name, CGColorSpace.displayP3 as String)
        let bt2020Name = ColorInfo.layerColorSpaceName(forPrimaries: bt2020) as String
        XCTAssertEqual(bt2020Name, CGColorSpace.itur_2020 as String)
    }

    // MARK: - 8-bit downgrade

    func testDowngradeKeepsP3DropsHDR() {
        let hdr = ColorInfo.forDisplay(wideGamut: true, hdrCapable: true, bitDepth: 10)
        let down = hdr.downgradedTo8Bit()
        // BT.2020 has no 8-bit meaning here — drop to safe 709 SDR.
        XCTAssertEqual(down.primaries, .bt709)
        XCTAssertEqual(down.transfer, .bt709)
        XCTAssertEqual(down.bitDepth, 8)

        let p3 = ColorInfo.forDisplay(wideGamut: true, hdrCapable: false, bitDepth: 10)
        let p3Down = p3.downgradedTo8Bit()
        // P3 is still worth tagging at 8-bit — keep the primaries.
        XCTAssertEqual(p3Down.primaries, .displayP3)
        XCTAssertEqual(p3Down.bitDepth, 8)
    }

    // MARK: - Encoder fallback ladder ordering

    func testSessionAttemptsHEVC8Bit() {
        let attempts = VideoEncoder.sessionAttempts(preferredCodec: .hevc, colorInfo: .bt709FullRange8)
        // No 10-bit rung when the source is 8-bit: HEVC then H.264.
        XCTAssertEqual(attempts.map { $0.codec }, [.hevc, .h264])
        XCTAssertEqual(attempts.map { $0.colorInfo.bitDepth }, [8, 8])
    }

    func testSessionAttemptsHEVC10BitLadder() {
        let hdr = ColorInfo.forDisplay(wideGamut: true, hdrCapable: true, bitDepth: 10)
        let attempts = VideoEncoder.sessionAttempts(preferredCodec: .hevc, colorInfo: hdr)
        // Main 10 → HEVC 8-bit → H.264 8-bit.
        XCTAssertEqual(attempts.map { $0.codec }, [.hevc, .hevc, .h264])
        XCTAssertEqual(attempts.map { $0.colorInfo.bitDepth }, [10, 8, 8])
    }

    func testSessionAttemptsH264PreferredNeverEmits10Bit() {
        let tenBit = ColorInfo.forDisplay(wideGamut: true, hdrCapable: true, bitDepth: 10)
        let attempts = VideoEncoder.sessionAttempts(preferredCodec: .h264, colorInfo: tenBit)
        XCTAssertEqual(attempts.map { $0.codec }, [.h264])
        XCTAssertEqual(attempts.first?.colorInfo.bitDepth, 8)
    }

    // MARK: - Codable round-trip (so it can ride telemetry if ever needed)

    func testCodableRoundTrip() throws {
        let original = ColorInfo.forDisplay(wideGamut: true, hdrCapable: true, bitDepth: 10)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ColorInfo.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
