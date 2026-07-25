import CFFmpeg
import Foundation

/// Minimal libavcodec H.264 encoder producing a real bitstream (SPS/PPS in-band,
/// no B-frames, low latency) for the test sharer. Draws a moving bar over a
/// gradient so a viewer can tell live video from a frozen frame at a glance.
///
/// Mirrors the encoder in `PipelineIntegrationTests` — kept separate rather than
/// shared because that one is test scaffolding and this one draws real content.
final class H264TestEncoder {
    private let ctx: UnsafeMutablePointer<AVCodecContext>
    private let pkt: UnsafeMutablePointer<AVPacket>
    private let frame: UnsafeMutablePointer<AVFrame>
    let width: Int32
    let height: Int32

    init?(width: Int32, height: Int32, fps: Int32) {
        guard let codec = avcodec_find_encoder(AV_CODEC_ID_H264) else { return nil }
        guard let cctx = avcodec_alloc_context3(codec) else { return nil }
        cctx.pointee.width = width
        cctx.pointee.height = height
        cctx.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        cctx.pointee.time_base = AVRational(num: 1, den: fps)
        cctx.pointee.framerate = AVRational(num: fps, den: 1)
        // Frequent keyframes: a viewer joining mid-stream (or recovering from a
        // PLI) gets parameter sets + an IDR quickly.
        cctx.pointee.gop_size = fps
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

    /// Ask for an IDR on the next `encode` (answers a viewer PLI).
    func requestKeyframe() {
        frame.pointee.pict_type = AV_PICTURE_TYPE_I
    }

    /// Encode frame `index`: a vertical gradient with a bright bar sweeping
    /// left→right, so motion is obvious in the viewer. Returns Annex-B AUs.
    func encodeFrame(index: Int) -> [Data] {
        guard av_frame_make_writable(frame) >= 0 else { return [] }
        let w = Int(width)
        let h = Int(height)
        let barX = (index * 7) % max(1, w)
        let barWidth = max(8, w / 12)

        if let y = frame.pointee.data.0 {
            let stride = Int(frame.pointee.linesize.0)
            for row in 0..<h {
                // Vertical gradient background.
                let base = UInt8(32 + (row * 120) / max(1, h))
                memset(y + row * stride, Int32(base), w)
                // Moving bright bar (wraps).
                for i in 0..<barWidth {
                    let x = (barX + i) % w
                    (y + row * stride + x).pointee = 235
                }
            }
        }
        let cw = w / 2
        let ch = h / 2
        // Tint the chroma planes slowly over time so color shifts too.
        let u = UInt8(truncatingIfNeeded: 110 + (index / 3) % 40)
        let v = UInt8(truncatingIfNeeded: 150 - (index / 5) % 40)
        fill(frame.pointee.data.1, stride: Int(frame.pointee.linesize.1), width: cw, height: ch, value: u)
        fill(frame.pointee.data.2, stride: Int(frame.pointee.linesize.2), width: cw, height: ch, value: v)

        frame.pointee.pts = Int64(index)
        let out = drain(sending: frame)
        frame.pointee.pict_type = AV_PICTURE_TYPE_NONE  // clear any forced IDR
        return out
    }

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

    /// Split an Annex-B buffer into raw NAL bodies (start codes stripped) — the
    /// form `H264Packetizer.packetize(nals:)` expects.
    static func annexBToNALs(_ annexB: Data) -> [Data] {
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
