import XCTest

@testable import FFmpegKit

/// Proves the sharer-side half of the wrapper: `FFmpeg.VideoEncoder` produces
/// real, decodable AVCC access units, and the Annex-B→AVCC conversion it relies
/// on round-trips against the existing AVCC→Annex-B direction.
///
/// The encoder is the video half of a non-Apple `CaptureEncoding` backend, so
/// what's asserted here is what that seam promises: AVCC out, keyframes on
/// demand, in-band parameter sets on every keyframe (so a viewer can join
/// mid-stream without extradata), and no B-frames.
final class EncodeTests: XCTestCase {

    // MARK: - Pure NAL-container conversion (no codec needed)

    func testAnnexBToAVCCConversion() throws {
        let annexB = Data([
            0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC,
            0x00, 0x00, 0x00, 0x01, 0xDD, 0xEE
        ])
        let avcc = try XCTUnwrap(NALUnit.annexBToAVCC(annexB))
        XCTAssertEqual(
            [UInt8](avcc),
            [
                0x00, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC,
                0x00, 0x00, 0x00, 0x02, 0xDD, 0xEE
            ])
    }

    /// Encoders mix 3- and 4-byte start codes within a single access unit
    /// (x264 emits 4-byte before parameter sets and 3-byte between slices), so
    /// the splitter has to handle both or it silently swallows NALs.
    func testThreeAndFourByteStartCodesBothParsed() throws {
        let annexB = Data([
            0x00, 0x00, 0x00, 0x01, 0x67, 0x11,  // 4-byte
            0x00, 0x00, 0x01, 0x68, 0x22, 0x33,  // 3-byte
            0x00, 0x00, 0x01, 0x65, 0x44  // 3-byte
        ])
        let nals = NALUnit.annexBNALs(annexB)
        XCTAssertEqual(nals.count, 3)
        XCTAssertEqual([UInt8](nals[0]), [0x67, 0x11])
        XCTAssertEqual([UInt8](nals[1]), [0x68, 0x22, 0x33])
        XCTAssertEqual([UInt8](nals[2]), [0x65, 0x44])
    }

    /// Trailing zero bytes are stream framing (`trailing_zero_8bits`), not NAL
    /// payload — including them would change the NAL length on the wire.
    func testTrailingZeroesTrimmed() {
        let annexB = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x11, 0x00, 0x00])
        let nals = NALUnit.annexBNALs(annexB)
        XCTAssertEqual(nals.count, 1)
        XCTAssertEqual([UInt8](nals[0]), [0x67, 0x11])
    }

    func testAVCCAnnexBRoundTrip() throws {
        let original = Data([
            0x00, 0x00, 0x00, 0x04, 0x67, 0x42, 0x00, 0x1E,
            0x00, 0x00, 0x00, 0x02, 0x68, 0xCE,
            0x00, 0x00, 0x00, 0x05, 0x65, 0x01, 0x02, 0x03, 0x04
        ])
        let annexB = try XCTUnwrap(NALUnit.avccToAnnexB(original))
        let back = try XCTUnwrap(NALUnit.annexBToAVCC(annexB))
        XCTAssertEqual(back, original)
    }

    /// A NAL too large for the length field must be refused, not truncated: a
    /// truncated length field produces a stream the peer silently mis-parses.
    func testOversizedNALForLengthSizeRejected() {
        var annexB = Data([0x00, 0x00, 0x00, 0x01])
        annexB.append(Data(repeating: 0xAA, count: 300))
        XCTAssertNil(NALUnit.annexBToAVCC(annexB, nalLengthSize: 1))
        XCTAssertNotNil(NALUnit.annexBToAVCC(annexB, nalLengthSize: 2))
    }

    // MARK: - Real encode

    private func makeFrame(width: Int, height: Int, shift: Int) -> ([UInt8], [UInt8], [UInt8]) {
        let cw = (width + 1) / 2
        let ch = (height + 1) / 2
        var y = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                // Gradient plus a moving bar, so consecutive frames genuinely
                // differ — a static image encodes to near-nothing and would
                // make the inter-frame assertions vacuous.
                let bar = abs(col - shift) < 8 ? 200 : 0
                y[row * width + col] = UInt8(min(255, (row * 255) / max(1, height) / 2 + bar))
            }
        }
        return (y, [UInt8](repeating: 128, count: cw * ch), [UInt8](repeating: 128, count: cw * ch))
    }

    func testEncoderAvailability() {
        // Every mainstream libavcodec has an H.264 *decoder*; encoders are
        // build options, so this documents what the host actually has.
        let name = FFmpeg.firstAvailableEncoder(for: .h264, preferring: ["libx264"])
        XCTAssertNotNil(name, "no H.264 encoder in this libavcodec build")
    }

    func testEncodeProducesDecodableAVCC() throws {
        guard FFmpeg.firstAvailableEncoder(for: .h264, preferring: ["libx264"]) != nil else {
            throw XCTSkip("no H.264 encoder in this libavcodec build")
        }
        let width = 160
        let height = 96
        let encoder = try FFmpeg.VideoEncoder(
            codec: .h264, width: width, height: height, fps: 30, bitrate: 800_000)

        var aus: [FFmpeg.VideoEncoder.EncodedAU] = []
        for i in 0..<10 {
            let (y, u, v) = makeFrame(width: width, height: height, shift: i * 12)
            aus += try encoder.encode(yPlane: y, uPlane: u, vPlane: v)
        }
        aus += try encoder.flush()

        XCTAssertFalse(aus.isEmpty, "encoder produced no access units")
        XCTAssertTrue(aus[0].isKeyframe, "first access unit must be a keyframe")

        // The whole point of AVCC output: feed it straight back through the
        // viewer's own decode path, unconverted.
        let decoder = try FFmpeg.VideoDecoder(codec: .h264)
        var frames: [FFmpeg.Frame] = []
        for au in aus {
            frames += try decoder.decode(avcc: au.data)
        }
        frames += try decoder.flush()
        XCTAssertFalse(frames.isEmpty, "no frames decoded from encoder output")
        XCTAssertEqual(frames[0].width, width)
        XCTAssertEqual(frames[0].height, height)
    }

    /// The viewer joins mid-stream and recovers from loss by asking for a
    /// keyframe — which only works if parameter sets ride *every* keyframe
    /// rather than being handed over once as extradata. Assert a decoder that
    /// has never seen the start of the stream can still decode from a later
    /// keyframe.
    func testKeyframesCarryInBandParameterSets() throws {
        guard FFmpeg.firstAvailableEncoder(for: .h264, preferring: ["libx264"]) != nil else {
            throw XCTSkip("no H.264 encoder in this libavcodec build")
        }
        let width = 160
        let height = 96
        let encoder = try FFmpeg.VideoEncoder(
            codec: .h264, width: width, height: height, fps: 30, bitrate: 800_000)

        var tail: [FFmpeg.VideoEncoder.EncodedAU] = []
        for i in 0..<12 {
            let (y, u, v) = makeFrame(width: width, height: height, shift: i * 12)
            if i == 6 { encoder.requestKeyframe() }
            let out = try encoder.encode(yPlane: y, uPlane: u, vPlane: v)
            if i >= 6 { tail += out }
        }
        let mid = try XCTUnwrap(tail.first)
        XCTAssertTrue(mid.isKeyframe, "requestKeyframe() did not produce an IDR")

        // NAL types 7 (SPS) and 8 (PPS) must be present in the keyframe AU.
        let annexB = try XCTUnwrap(NALUnit.avccToAnnexB(mid.data))
        let types = Set(NALUnit.annexBNALs(annexB).compactMap { $0.first.map { $0 & 0x1F } })
        XCTAssertTrue(types.contains(7), "keyframe carries no SPS")
        XCTAssertTrue(types.contains(8), "keyframe carries no PPS")

        // A fresh decoder — which never saw the stream's opening keyframe —
        // decodes the tail, exactly as a late-joining viewer does.
        let joiner = try FFmpeg.VideoDecoder(codec: .h264)
        var frames: [FFmpeg.Frame] = []
        for au in tail { frames += try joiner.decode(avcc: au.data) }
        frames += try joiner.flush()
        XCTAssertFalse(frames.isEmpty, "late joiner decoded nothing from a mid-stream keyframe")
    }

    /// One access unit per input frame, and no reordering: the RTP path stamps
    /// timestamps in capture order and has no reorder buffer of its own, which
    /// B-frames would break.
    func testNoBFrameReordering() throws {
        guard FFmpeg.firstAvailableEncoder(for: .h264, preferring: ["libx264"]) != nil else {
            throw XCTSkip("no H.264 encoder in this libavcodec build")
        }
        let encoder = try FFmpeg.VideoEncoder(
            codec: .h264, width: 160, height: 96, fps: 30, bitrate: 800_000)
        var produced = 0
        for i in 0..<15 {
            let (y, u, v) = makeFrame(width: 160, height: 96, shift: i * 10)
            produced += try encoder.encode(yPlane: y, uPlane: u, vPlane: v).count
        }
        let flushed = try encoder.flush().count
        XCTAssertEqual(flushed, 0, "encoder held frames back — B-frames or lookahead are enabled")
        XCTAssertEqual(produced, 15, "expected one access unit per input frame")
    }

    /// Odd dimensions would leave libavcodec a partial chroma row; the encoder
    /// rounds down to even and reports the geometry it actually used, so a
    /// caller can size its scaler correctly.
    func testOddDimensionsRoundedDown() throws {
        guard FFmpeg.firstAvailableEncoder(for: .h264, preferring: ["libx264"]) != nil else {
            throw XCTSkip("no H.264 encoder in this libavcodec build")
        }
        let encoder = try FFmpeg.VideoEncoder(
            codec: .h264, width: 161, height: 97, fps: 30, bitrate: 500_000)
        XCTAssertEqual(encoder.width, 160)
        XCTAssertEqual(encoder.height, 96)
    }

    func testMismatchedPlaneSizesRejected() throws {
        guard FFmpeg.firstAvailableEncoder(for: .h264, preferring: ["libx264"]) != nil else {
            throw XCTSkip("no H.264 encoder in this libavcodec build")
        }
        let encoder = try FFmpeg.VideoEncoder(
            codec: .h264, width: 160, height: 96, fps: 30, bitrate: 500_000)
        XCTAssertThrowsError(
            try encoder.encode(yPlane: [0, 1, 2], uPlane: [0], vPlane: [0]),
            "short planes must be rejected, not read out of bounds")
    }
}
