import CFFmpeg
import Foundation
import XCTest

@testable import TailscreenProtocol
@testable import TailscreenViewer
@testable import TailscreenViewerCore

/// End-to-end coverage of the Linux viewer's real data path — the one thing the
/// per-backend unit suites (FFmpegKit / SDLKit / ALSAKit) and the portable
/// `ViewerSessionTests` each cover only in isolation. Here a *real* H.264
/// keyframe is encoded in process, RTP-packetized with the production
/// `H264Packetizer`, fed through a `ViewerPipeline` wired to the real
/// `FFmpegVideoDecoder`, and the decoded frame is observed at a collecting
/// `VideoSink`. No tsnet, no window, no audio device — so it runs on CI.
final class PipelineIntegrationTests: XCTestCase {

    // MARK: - Collecting sinks

    private final class CollectingVideoSink: VideoSink {
        var frames: [DecodedVideoFrame] = []
        func present(_ frame: DecodedVideoFrame) { frames.append(frame) }
    }

    // MARK: - Real decode reaches the sink

    func testRealH264StreamDecodesToSink() throws {
        let width = 64
        let height = 48
        guard let encoder = TestH264Encoder(width: Int32(width), height: Int32(height)) else {
            throw XCTSkip("no H.264 encoder in this libavcodec build")
        }

        // Encode a short run so the decoder has an IDR (SPS/PPS in-band) plus a
        // couple of P-frames — the same shape a live share produces.
        var annexBUnits: [Data] = []
        for i in 0..<4 {
            annexBUnits.append(contentsOf: encoder.encode(luma: 128, chroma: 128, pts: Int64(i)))
        }
        annexBUnits.append(contentsOf: encoder.flush())
        XCTAssertFalse(annexBUnits.isEmpty, "encoder produced no access units")

        let videoSink = CollectingVideoSink()
        let pipeline = ViewerPipeline(
            caps: [.nack, .receiverReport, .fec],
            decoder: FFmpegVideoDecoder(),
            videoSink: videoSink,
            audioSink: nil,
            onControlToSend: { _ in }
        )

        // Packetize each AU with the production H.264 packetizer and feed the
        // RTP datagrams through the pipeline in order (contiguous seqs → the
        // depacketizer reassembles and emits immediately).
        let packetizer = H264Packetizer()
        var seq: UInt16 = 0
        var clock: UInt64 = 0
        for (i, au) in annexBUnits.enumerated() {
            let nals = Self.annexBToNALs(au)
            let packets = packetizer.packetize(
                nals: nals, timestamp: UInt32(i * 3000), ssrc: 0, startSequence: seq)
            seq = seq &+ UInt16(packets.count)
            clock += 33_000_000  // ~30 fps
            pipeline.tick(nowNs: clock)
            for packet in packets { pipeline.receive(packet) }
        }

        XCTAssertFalse(videoSink.frames.isEmpty, "no decoded frame reached the sink")
        let first = try XCTUnwrap(videoSink.frames.first)
        XCTAssertEqual(first.width, width)
        XCTAssertEqual(first.height, height)
        XCTAssertEqual(first.yPlane.count, width * height)
        XCTAssertEqual(first.uPlane.count, ((width + 1) / 2) * ((height + 1) / 2))
        // A solid mid-grey source must decode to a roughly uniform mid-luma
        // plane (lossy, so not exactly 128) — proof the pixels are real, not
        // an all-zero placeholder.
        let centre = first.yPlane[(height / 2) * width + (width / 2)]
        XCTAssertGreaterThan(centre, 96)
        XCTAssertLessThan(centre, 160)
    }

    // MARK: - Decode failure asks for a keyframe

    /// A corrupt access unit (valid RTP framing, garbage payload) must not crash
    /// the pipeline; the decode throw is answered with a PLI so the stream can
    /// recover. This exercises the adapter's error path against the real
    /// FFmpeg decoder rather than a stub.
    func testCorruptAccessUnitRequestsKeyframe() throws {
        var controlBytes: [Data] = []
        let pipeline = ViewerPipeline(
            caps: [.nack, .receiverReport, .fec],
            decoder: FFmpegVideoDecoder(),
            videoSink: CollectingVideoSink(),
            audioSink: nil,
            onControlToSend: { controlBytes.append($0) }
        )

        // One NAL of junk that is not a valid H.264 access unit.
        let junk = Data([0x41, 0x9A, 0x00, 0xFF, 0x13, 0x37, 0x42, 0x24])
        let packetizer = H264Packetizer()
        let packets = packetizer.packetize(nals: [junk], timestamp: 0, ssrc: 0, startSequence: 0)
        pipeline.tick(nowNs: 1_000_000)
        for packet in packets { pipeline.receive(packet) }

        let kinds = controlBytes.compactMap { ScreenShareControlMessage.decode($0) }
        XCTAssertTrue(kinds.contains(.pli), "a decode failure should emit a PLI keyframe request")
    }

    // MARK: - Test scaffolding

    /// Split an Annex-B buffer into raw NAL bodies (start codes stripped), the
    /// form `H264Packetizer.packetize(nals:)` expects.
    private static func annexBToNALs(_ annexB: Data) -> [Data] {
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
        var nals: [Data] = []
        for (idx, start) in starts.enumerated() {
            let end: Int
            if idx + 1 < starts.count {
                // Back up over the next NAL's start code.
                var e = starts[idx + 1] - 3
                if e - 1 >= 0, bytes[e - 1] == 0 { e -= 1 }
                end = e
            } else {
                end = bytes.count
            }
            if end > start { nals.append(Data(bytes[start..<end])) }
        }
        return nals
    }
}

/// Minimal in-process H.264 encoder on libavcodec, used only to generate real
/// bitstream for the pipeline test (no-reorder / low-latency, SPS/PPS in-band,
/// one Annex-B access unit per input frame). Mirrors FFmpegKit's own test
/// encoder — duplicated here rather than made public API, since it's pure test
/// scaffolding.
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
        if av_frame_get_buffer(f, 0) < 0 { return nil }
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

    func encode(luma: UInt8, chroma: UInt8, pts: Int64) -> [Data] {
        guard av_frame_make_writable(frame) >= 0 else { return [] }
        fill(
            frame.pointee.data.0, stride: Int(frame.pointee.linesize.0),
            width: Int(width), height: Int(height), value: luma)
        let cw = Int(width) / 2
        let ch = Int(height) / 2
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
        for row in 0..<height { memset(p + row * stride, Int32(value), width) }
    }
}
