import CFFmpeg
import Foundation

/// Thin Swift wrapper over libavcodec for Tailscreen's portable video-decode
/// path (the Linux/Windows viewer). Foundation + FFmpeg only: the same source
/// builds on macOS, Linux, and Windows against a system FFmpeg.
///
/// Namespaced under `FFmpeg` so the types read as `FFmpeg.VideoDecoder` /
/// `FFmpeg.Frame` and don't collide with libavcodec's own C symbols.
public enum FFmpeg {
    /// The video codecs Tailscreen carries on the wire (RTP payload type 96 =
    /// H.264, 97 = HEVC). The viewer auto-detects which from the payload type.
    public enum Codec: Sendable, CustomStringConvertible {
        case h264
        case hevc

        var avID: AVCodecID { self == .h264 ? AV_CODEC_ID_H264 : AV_CODEC_ID_HEVC }
        public var description: String { self == .h264 ? "H.264" : "HEVC" }
    }

    /// A libavcodec error surfaced to Swift. `code` is the raw AVERROR return
    /// value; `message` is `av_strerror` (or a wrapper-supplied reason).
    public struct DecodeError: Error {
        public let code: Int32
        public let message: String

        init(_ code: Int32) {
            self.code = code
            var buf = [CChar](repeating: 0, count: 256)
            av_strerror(code, &buf, 256)
            self.message = buf.withUnsafeBufferPointer {
                $0.baseAddress.map { String(cString: $0) } ?? ""
            }
        }

        init(message: String) {
            self.code = 0
            self.message = message
        }
    }

    /// One decoded frame as 8-bit planar YUV 4:2:0 — the format libavcodec's
    /// software H.264/HEVC decoders emit. Planes are packed (row stride ==
    /// plane width, decoder padding removed) so a renderer can upload them
    /// directly. The chroma planes are ⌈w/2⌉ × ⌈h/2⌉. (RGB conversion is left
    /// to the renderer — a GPU shader does it for free — so this stays a
    /// libavcodec-only module with no libswscale dependency.)
    public struct Frame: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let yPlane: [UInt8]
        public let uPlane: [UInt8]
        public let vPlane: [UInt8]

        public init(width: Int, height: Int, yPlane: [UInt8], uPlane: [UInt8], vPlane: [UInt8]) {
            self.width = width
            self.height = height
            self.yPlane = yPlane
            self.uPlane = uPlane
            self.vPlane = vPlane
        }
    }

    /// True if this FFmpeg build can decode `codec`. Software H.264/HEVC
    /// decoders ship in every mainstream libavcodec, but a stripped build
    /// might omit one — call this before assuming a stream is decodable.
    public static func isDecoderAvailable(_ codec: Codec) -> Bool {
        avcodec_find_decoder(codec.avID) != nil
    }

    /// Stateful H.264/HEVC decoder — one instance per stream (it carries
    /// reference frames across access units), driven from a single thread.
    /// Feed it Annex-B access units (`decode(annexB:)`) or Tailscreen's native
    /// AVCC ones (`decode(avcc:)`); parameter sets (SPS/PPS/VPS) are expected
    /// in-band, exactly as the sharer sends them on every keyframe, so no
    /// out-of-band extradata is needed.
    public final class VideoDecoder: @unchecked Sendable {
        private let ctx: UnsafeMutablePointer<AVCodecContext>
        private let pkt: UnsafeMutablePointer<AVPacket>
        private let frame: UnsafeMutablePointer<AVFrame>

        public init(codec: Codec) throws {
            guard let c = avcodec_find_decoder(codec.avID) else {
                throw DecodeError(message: "no libavcodec decoder for \(codec)")
            }
            guard let cctx = avcodec_alloc_context3(c) else {
                throw DecodeError(message: "avcodec_alloc_context3 failed")
            }
            let openRet = avcodec_open2(cctx, c, nil)
            if openRet < 0 {
                var tmp: UnsafeMutablePointer<AVCodecContext>? = cctx
                avcodec_free_context(&tmp)
                throw DecodeError(openRet)
            }
            guard let p = av_packet_alloc(), let f = av_frame_alloc() else {
                var tmp: UnsafeMutablePointer<AVCodecContext>? = cctx
                avcodec_free_context(&tmp)
                throw DecodeError(message: "packet/frame allocation failed")
            }
            ctx = cctx
            pkt = p
            frame = f
        }

        deinit {
            var c: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&c)
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
        }

        /// Decode one Annex-B access unit (start-code-prefixed NALs; may bundle
        /// SPS/PPS ahead of the slice). Returns every frame that became ready —
        /// usually one, sometimes zero while the decoder buffers reordering.
        public func decode(annexB data: Data) throws -> [Frame] {
            guard !data.isEmpty else { return [] }
            let sendRet: Int32 = data.withUnsafeBytes { raw in
                let n = Int32(raw.count)
                guard av_new_packet(pkt, n) == 0 else { return -1 }
                if let base = raw.baseAddress {
                    memcpy(pkt.pointee.data, base, Int(n))
                }
                return avcodec_send_packet(ctx, pkt)
            }
            av_packet_unref(pkt)
            if sendRet < 0 && sendRet != ffk_averror_eagain() {
                throw DecodeError(sendRet)
            }
            return try drain()
        }

        /// Decode one AVCC access unit — length-prefixed NALs, the format
        /// VideoToolbox produces and Tailscreen puts on the wire. Converts to
        /// Annex-B (`NALUnit.avccToAnnexB`) then decodes.
        public func decode(avcc data: Data, nalLengthSize: Int = 4) throws -> [Frame] {
            guard let annexB = NALUnit.avccToAnnexB(data, nalLengthSize: nalLengthSize) else {
                throw DecodeError(message: "malformed AVCC access unit")
            }
            return try decode(annexB: annexB)
        }

        /// Flush the decoder at end-of-stream: emit any frames it was holding
        /// for reordering. Call once when the stream ends.
        public func flush() throws -> [Frame] {
            _ = avcodec_send_packet(ctx, nil)
            return try drain()
        }

        private func drain() throws -> [Frame] {
            var frames: [Frame] = []
            while true {
                let r = avcodec_receive_frame(ctx, frame)
                if r == ffk_averror_eagain() || r == ffk_averror_eof() { break }
                if r < 0 { throw DecodeError(r) }
                frames.append(try Self.makeFrame(frame))
                av_frame_unref(frame)
            }
            return frames
        }

        private static func makeFrame(_ f: UnsafeMutablePointer<AVFrame>) throws -> Frame {
            let w = Int(f.pointee.width)
            let h = Int(f.pointee.height)
            let fmt = f.pointee.format
            // Accept the 8-bit planar 4:2:0 family (YUVJ is the full-range
            // variant, same layout). Anything else — 10-bit, NV12, etc. — is a
            // renderer-PR concern; reject it loudly rather than mis-copy.
            let is420 = fmt == AV_PIX_FMT_YUV420P.rawValue || fmt == AV_PIX_FMT_YUVJ420P.rawValue
            guard is420 else {
                throw DecodeError(message: "unsupported pixel format \(fmt); this build handles 8-bit YUV 4:2:0")
            }
            let cw = (w + 1) / 2
            let ch = (h + 1) / 2
            let y = copyPlane(f.pointee.data.0, stride: Int(f.pointee.linesize.0), width: w, height: h)
            let u = copyPlane(f.pointee.data.1, stride: Int(f.pointee.linesize.1), width: cw, height: ch)
            let v = copyPlane(f.pointee.data.2, stride: Int(f.pointee.linesize.2), width: cw, height: ch)
            return Frame(width: w, height: h, yPlane: y, uPlane: u, vPlane: v)
        }

        /// Copy one plane, dropping the decoder's row padding (`stride` may
        /// exceed `width`) so the result is tightly packed `width × height`.
        private static func copyPlane(
            _ src: UnsafeMutablePointer<UInt8>?, stride: Int, width: Int, height: Int
        ) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: max(0, width * height))
            guard let src, width > 0, height > 0, stride >= width else { return out }
            out.withUnsafeMutableBytes { dst in
                guard let base = dst.baseAddress else { return }
                for row in 0..<height {
                    memcpy(base + row * width, src + row * stride, width)
                }
            }
            return out
        }
    }
}

/// NAL-unit container conversion. H.264/HEVC bitstreams travel either as
/// **AVCC** (each NAL prefixed by a big-endian length field — VideoToolbox's
/// and Tailscreen's wire format) or **Annex-B** (each NAL prefixed by a
/// `00 00 00 01` start code — what FFmpeg/libavcodec consume by default).
/// This conversion belongs in the shared adapter layer, not reinvented per
/// platform (see docs/porting-plan.md problem #3).
public enum NALUnit {
    /// Convert an AVCC access unit to Annex-B. `nalLengthSize` is the width of
    /// each NAL's length prefix (1, 2, or 4 bytes; H.264/HEVC avcC records use
    /// 4). Returns nil if the buffer is malformed — a length that runs past
    /// the end, or a zero-length NAL — so a corrupt packet can't be fed to the
    /// decoder as a partial stream.
    public static func avccToAnnexB(_ avcc: Data, nalLengthSize: Int = 4) -> Data? {
        guard (1...4).contains(nalLengthSize) else { return nil }
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var out = Data()
        var offset = 0
        let bytes = [UInt8](avcc)
        let count = bytes.count
        while offset < count {
            guard count - offset >= nalLengthSize else { return nil }
            var nalLength = 0
            for _ in 0..<nalLengthSize {
                nalLength = (nalLength << 8) | Int(bytes[offset])
                offset += 1
            }
            guard nalLength > 0, count - offset >= nalLength else { return nil }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[offset..<(offset + nalLength)])
            offset += nalLength
        }
        return out
    }
}
