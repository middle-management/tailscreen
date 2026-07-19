import CFFmpeg
import XCTest

@testable import FFmpegKit

/// Proves the libavcodec wrapper actually decodes — real H.264 encoded in
/// process is fed back through `FFmpeg.VideoDecoder` and the recovered frames
/// are checked for size and luma. The pure NAL-container conversion is tested
/// without any codec. Mirrors OpusKit's "prove it runs on whatever platform CI
/// builds it" approach.
final class DecodeTests: XCTestCase {

    // MARK: - Pure NAL-container conversion (no codec needed)

    func testAVCCToAnnexBConversion() throws {
        // Two NALs, 4-byte big-endian length prefixes.
        let avcc = Data([
            0x00, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC,
            0x00, 0x00, 0x00, 0x02, 0xDD, 0xEE,
        ])
        let annexB = try XCTUnwrap(NALUnit.avccToAnnexB(avcc))
        XCTAssertEqual(
            [UInt8](annexB),
            [
                0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC,
                0x00, 0x00, 0x00, 0x01, 0xDD, 0xEE,
            ])
    }

    func testAVCCMalformedRejected() {
        // Declares a 9-byte NAL but only 3 bytes follow → nil, not a partial
        // stream fed to the decoder.
        let truncated = Data([0x00, 0x00, 0x00, 0x09, 0xAA, 0xBB, 0xCC])
        XCTAssertNil(NALUnit.avccToAnnexB(truncated))
        // Zero-length NAL is rejected.
        XCTAssertNil(NALUnit.avccToAnnexB(Data([0x00, 0x00, 0x00, 0x00])))
        // A length field that itself runs off the end.
        XCTAssertNil(NALUnit.avccToAnnexB(Data([0x00, 0x00])))
    }

    func testTwoByteLengthPrefix() throws {
        let avcc = Data([0x00, 0x03, 0x01, 0x02, 0x03])
        let annexB = try XCTUnwrap(NALUnit.avccToAnnexB(avcc, nalLengthSize: 2))
        XCTAssertEqual([UInt8](annexB), [0x00, 0x00, 0x00, 0x01, 0x01, 0x02, 0x03])
    }

    // MARK: - Decoder availability

    func testH264DecoderAvailable() {
        XCTAssertTrue(FFmpeg.isDecoderAvailable(.h264), "libavcodec should ship an H.264 decoder")
    }

    // MARK: - Real encode → decode round trip

    func testH264EncodeDecodeRoundTrip() throws {
        let width = 64, height = 48
        guard let encoder = TestH264Encoder(width: Int32(width), height: Int32(height)) else {
            throw XCTSkip("no H.264 encoder in this libavcodec build")
        }

        // Encode a short run of solid-grey frames (Y = 128).
        let frameCount = 5
        var annexBUnits: [Data] = []
        for i in 0..<frameCount {
            annexBUnits.append(contentsOf: encoder.encode(luma: 128, chroma: 128, pts: Int64(i)))
        }
        annexBUnits.append(contentsOf: encoder.flush())
        XCTAssertGreaterThan(annexBUnits.count, 0, "encoder produced no access units")

        let decoder = try FFmpeg.VideoDecoder(codec: .h264)
        var decoded: [FFmpeg.Frame] = []
        for au in annexBUnits {
            decoded.append(contentsOf: try decoder.decode(annexB: au))
        }
        decoded.append(contentsOf: try decoder.flush())

        XCTAssertGreaterThan(decoded.count, 0, "decoder produced no frames")
        let first = try XCTUnwrap(decoded.first)
        XCTAssertEqual(first.width, width)
        XCTAssertEqual(first.height, height)
        XCTAssertEqual(first.yPlane.count, width * height)
        XCTAssertEqual(first.uPlane.count, ((width + 1) / 2) * ((height + 1) / 2))
        // Lossy, so not exactly 128 — but a solid-grey frame must decode to a
        // roughly uniform mid-luma plane, nowhere near black or white.
        let centre = first.yPlane[(height / 2) * width + (width / 2)]
        XCTAssertGreaterThan(centre, 96)
        XCTAssertLessThan(centre, 160)
    }

    /// The AVCC entry point: re-wrap the encoder's Annex-B output as AVCC and
    /// prove `decode(avcc:)` reaches the same frames.
    func testDecodeAVCCPath() throws {
        let width = 32, height = 32
        guard let encoder = TestH264Encoder(width: Int32(width), height: Int32(height)) else {
            throw XCTSkip("no H.264 encoder in this libavcodec build")
        }
        var units: [Data] = []
        for i in 0..<3 { units.append(contentsOf: encoder.encode(luma: 80, chroma: 128, pts: Int64(i))) }
        units.append(contentsOf: encoder.flush())

        let decoder = try FFmpeg.VideoDecoder(codec: .h264)
        var decoded: [FFmpeg.Frame] = []
        for annexB in units {
            decoded.append(contentsOf: try decoder.decode(avcc: annexBToAVCC(annexB)))
        }
        decoded.append(contentsOf: try decoder.flush())
        XCTAssertGreaterThan(decoded.count, 0)
        XCTAssertEqual(decoded.first?.width, width)
    }

    // MARK: - Test-only Annex-B → AVCC (inverse of the wrapper's converter)

    /// Split an Annex-B buffer on `00 00 00 01` / `00 00 01` start codes and
    /// re-emit each NAL with a 4-byte length prefix. Test scaffolding only.
    private func annexBToAVCC(_ annexB: Data) -> Data {
        let bytes = [UInt8](annexB)
        var starts: [Int] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else if i + 4 <= bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0,
                bytes[i + 3] == 1
            {
                starts.append(i + 4)
                i += 4
            } else {
                i += 1
            }
        }
        var out = Data()
        for (idx, start) in starts.enumerated() {
            let end = idx + 1 < starts.count ? nalPayloadEnd(bytes, before: starts[idx + 1]) : bytes.count
            let nal = bytes[start..<end]
            let len = UInt32(nal.count)
            out.append(UInt8((len >> 24) & 0xFF))
            out.append(UInt8((len >> 16) & 0xFF))
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
            out.append(contentsOf: nal)
        }
        return out
    }

    /// Given the payload start of the *next* NAL, back up over its start code
    /// to find where the current NAL's payload ends.
    private func nalPayloadEnd(_ bytes: [UInt8], before nextStart: Int) -> Int {
        // nextStart points just past a start code; strip the 3- or 4-byte code.
        var end = nextStart - 3
        if end - 1 >= 0, bytes[end - 1] == 0 { end -= 1 }  // 4-byte start code
        return end
    }
}

/// Minimal in-process H.264 encoder built straight on libavcodec, used only to
/// generate real bitstream for the decoder tests. Configured for
/// no-reorder / low-latency output (one Annex-B access unit per input frame,
/// SPS/PPS in-band) so the round trip is 1:1.
private final class TestH264Encoder {
    private let ctx: UnsafeMutablePointer<AVCodecContext>
    private let pkt: UnsafeMutablePointer<AVPacket>
    private let frame: UnsafeMutablePointer<AVFrame>
    private let width: Int32
    private let height: Int32

    init?(width: Int32, height: Int32) {
        guard let codec = avcodec_find_encoder(AV_CODEC_ID_H264) else { return nil }
        guard let cctx = avcodec_alloc_context3(codec) else { return nil }
        cctx.pointee.width = width
        cctx.pointee.height = height
        cctx.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        cctx.pointee.time_base = AVRational(num: 1, den: 30)
        cctx.pointee.framerate = AVRational(num: 30, den: 1)
        cctx.pointee.gop_size = 30
        cctx.pointee.max_b_frames = 0
        // libx264 knobs: fastest encode, no lookahead/B-frames → each frame
        // comes out immediately as one Annex-B access unit.
        av_opt_set(cctx.pointee.priv_data, "preset", "ultrafast", 0)
        av_opt_set(cctx.pointee.priv_data, "tune", "zerolatency", 0)
        if avcodec_open2(cctx, codec, nil) < 0 {
            var tmp: UnsafeMutablePointer<AVCodecContext>? = cctx
            avcodec_free_context(&tmp)
            return nil
        }
        guard let p = av_packet_alloc(), let f = av_frame_alloc() else {
            var tmp: UnsafeMutablePointer<AVCodecContext>? = cctx
            avcodec_free_context(&tmp)
            return nil
        }
        f.pointee.format = Int32(AV_PIX_FMT_YUV420P.rawValue)
        f.pointee.width = width
        f.pointee.height = height
        if av_frame_get_buffer(f, 0) < 0 {
            return nil
        }
        ctx = cctx
        pkt = p
        frame = f
        self.width = width
        self.height = height
    }

    deinit {
        var c: UnsafeMutablePointer<AVCodecContext>? = ctx
        avcodec_free_context(&c)
        var p: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&p)
        var f: UnsafeMutablePointer<AVFrame>? = frame
        av_frame_free(&f)
    }

    /// Encode one solid-colour frame; returns the Annex-B access unit(s).
    func encode(luma: UInt8, chroma: UInt8, pts: Int64) -> [Data] {
        guard av_frame_make_writable(frame) >= 0 else { return [] }
        fill(
            frame.pointee.data.0, stride: Int(frame.pointee.linesize.0),
            width: Int(width), height: Int(height), value: luma)
        let cw = Int(width) / 2, ch = Int(height) / 2
        fill(frame.pointee.data.1, stride: Int(frame.pointee.linesize.1), width: cw, height: ch, value: chroma)
        fill(frame.pointee.data.2, stride: Int(frame.pointee.linesize.2), width: cw, height: ch, value: chroma)
        frame.pointee.pts = pts
        return drain(sending: frame)
    }

    func flush() -> [Data] { drain(sending: nil) }

    private func drain(sending f: UnsafeMutablePointer<AVFrame>?) -> [Data] {
        var out: [Data] = []
        guard avcodec_send_frame(ctx, f) >= 0 else { return out }
        while true {
            let r = avcodec_receive_packet(ctx, pkt)
            if r == ffk_averror_eagain() || r == ffk_averror_eof() { break }
            if r < 0 { break }
            if let data = pkt.pointee.data {
                out.append(Data(bytes: data, count: Int(pkt.pointee.size)))
            }
            av_packet_unref(pkt)
        }
        return out
    }

    private func fill(_ p: UnsafeMutablePointer<UInt8>?, stride: Int, width: Int, height: Int, value: UInt8) {
        guard let p else { return }
        for row in 0..<height {
            memset(p + row * stride, Int32(value), width)
        }
    }
}
