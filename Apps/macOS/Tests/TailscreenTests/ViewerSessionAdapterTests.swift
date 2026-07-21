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

    // MARK: - Live VideoToolbox decode through the adapter

    /// Feed a real, in-process-encoded access unit (params prepended in-band,
    /// as the wire carries them on a keyframe) through `VTVideoDecoderAdapter`
    /// and assert a decoded `CVPixelBufferBox` is delivered on the callback
    /// queue — the load-bearing proof that the mac decode adapter actually
    /// drives VideoToolbox and produces the zero-copy frame the convergence
    /// depends on. Self-skips (via `encodeSyntheticAUs`) on a virtualized CI
    /// runner with no hardware video path.
    func testAdapterDecodesRealFrameToPixelBufferBox() async throws {
        let synth = try await TailscreenE2E.encodeSyntheticAUs()

        let codec: VideoCodec
        let paramNALs: [Data]
        switch synth.params {
        case .h264(let sps, let pps):
            codec = .h264
            paramNALs = [sps, pps]
        case .hevc(let vps, let sps, let pps):
            codec = .hevc
            paramNALs = [vps, sps, pps]
        }
        // The server prepends parameter sets in-band on keyframes; do the same
        // so the adapter's own extraction installs them before decoding.
        let firstAU = avcc(paramNALs) + synth.aus[0].data

        let queue = DispatchQueue(label: "test.vt-adapter")
        let adapter = VTVideoDecoderAdapter(callbackQueue: queue)
        let delivered = expectation(description: "a decoded CVPixelBufferBox is delivered")
        delivered.assertForOverFulfill = false
        let lock = NSLock()
        var received: CVPixelBufferBox?
        adapter.onDecodedFrame = { frame in
            lock.lock()
            if received == nil { received = frame as? CVPixelBufferBox }
            lock.unlock()
            delivered.fulfill()
        }

        adapter.decode(accessUnit: firstAU, codec: codec, isKeyframe: true)
        for au in synth.aus.dropFirst() {
            adapter.decode(accessUnit: au.data, codec: codec, isKeyframe: au.isKey)
        }

        await fulfillment(of: [delivered], timeout: 15)

        lock.lock()
        let box = received
        lock.unlock()
        let unwrapped = try XCTUnwrap(box, "a CVPixelBufferBox should have been delivered")
        XCTAssertGreaterThan(unwrapped.width, 0)
        XCTAssertGreaterThan(unwrapped.height, 0)
    }
}
