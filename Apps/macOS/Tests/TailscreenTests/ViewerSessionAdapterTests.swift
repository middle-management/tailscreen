import CoreVideo
import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenViewer

/// Deterministic coverage for the macOS `ViewerSession` adapters (Phase B). The
/// live VideoToolbox decode + Metal render path is exercised end-to-end by the
/// existing on-CI `ScreenShareSyntheticFramesTests`; here we pin the pure,
/// backend-free pieces: the in-band parameter-set extraction the VT adapter
/// installs before decoding, and the `CVPixelBufferBox` frame wrapper the
/// zero-copy path rides on.
final class ViewerSessionAdapterTests: XCTestCase {

    /// Wrap NAL bodies as a length-prefixed AVCC blob (4-byte BE length each),
    /// matching what `AVCCParser.nalUnits` expects to split back apart.
    private func avcc(_ nals: [Data]) -> Data {
        var out = Data()
        for nal in nals {
            let len = UInt32(nal.count)
            out.append(UInt8((len >> 24) & 0xFF))
            out.append(UInt8((len >> 16) & 0xFF))
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(nal)
        }
        return out
    }

    // MARK: - Parameter-set extraction

    func testExtractsH264ParameterSets() {
        let sps = Data([0x67, 0x11, 0x22, 0x33])  // NAL type 7 (header & 0x1F)
        let pps = Data([0x68, 0x44])  // NAL type 8
        let au = avcc([sps, pps, Data([0x65, 0x01, 0x02])])  // + an IDR slice (type 5)

        XCTAssertEqual(
            VTVideoDecoderAdapter.parameterSets(fromAVCC: au, codec: .h264),
            .h264(sps: sps, pps: pps))
    }

    func testExtractsHEVCParameterSets() {
        let vps = Data([0x40, 0x01])  // (header >> 1) & 0x3F == 32
        let sps = Data([0x42, 0x02])  // == 33
        let pps = Data([0x44, 0x03])  // == 34
        let au = avcc([vps, sps, pps, Data([0x26, 0x01])])  // + an IDR_W_RADL slice (type 19)

        XCTAssertEqual(
            VTVideoDecoderAdapter.parameterSets(fromAVCC: au, codec: .hevc),
            .hevc(vps: vps, sps: sps, pps: pps))
    }

    func testMissingParameterSetYieldsNil() {
        // H.264 with only a PPS (no SPS) — incomplete, so no format description.
        let au = avcc([Data([0x68, 0x44]), Data([0x65, 0x01])])
        XCTAssertNil(VTVideoDecoderAdapter.parameterSets(fromAVCC: au, codec: .h264))

        // HEVC missing its VPS.
        let hevc = avcc([Data([0x42, 0x02]), Data([0x44, 0x03])])
        XCTAssertNil(VTVideoDecoderAdapter.parameterSets(fromAVCC: hevc, codec: .hevc))
    }

    // MARK: - CVPixelBufferBox

    func testPixelBufferBoxReportsDimensions() throws {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &pb)
        XCTAssertEqual(status, kCVReturnSuccess)

        let box = CVPixelBufferBox(buffer: try XCTUnwrap(pb), receiveUptimeNs: 42)
        XCTAssertEqual(box.width, 320)
        XCTAssertEqual(box.height, 240)
        XCTAssertEqual(box.receiveUptimeNs, 42)

        // It satisfies the opaque `DecodedFrame` seam the session routes on.
        let frame: any DecodedFrame = box
        XCTAssertEqual(frame.width, 320)
        XCTAssertEqual(frame.height, 240)
    }
}
