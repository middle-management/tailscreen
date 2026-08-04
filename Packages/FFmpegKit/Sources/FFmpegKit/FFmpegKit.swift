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

    /// True if this FFmpeg build has `name` as an *encoder* (`"libx264"`,
    /// `"h264_vaapi"`, `"h264_nvenc"`, …). Unlike decoders, encoders are
    /// frequently absent: libx264/libx265 are GPL-licensed opt-ins and the
    /// hardware ones need matching drivers, so a sharer must probe rather
    /// than assume.
    public static func isEncoderAvailable(_ name: String) -> Bool {
        avcodec_find_encoder_by_name(name) != nil
    }

    /// The first available encoder for `codec` from `preferring`, falling back
    /// to libavcodec's default for the codec id. Lets a sharer ask for
    /// hardware first and land on software without branching.
    public static func firstAvailableEncoder(
        for codec: Codec, preferring names: [String]
    ) -> String? {
        for n in names where isEncoderAvailable(n) { return n }
        guard let c = avcodec_find_encoder(codec.avID), let namePtr = c.pointee.name else { return nil }
        return String(cString: namePtr)
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

    /// Stateful H.264/HEVC **encoder** — the sharer-side counterpart of
    /// ``VideoDecoder``, and the video half of a non-Apple `CaptureEncoding`
    /// backend.
    ///
    /// Configured for the constraints Tailscreen's transport imposes rather
    /// than for archival quality: **no B-frames** (they reorder output, and
    /// the RTP path assumes an access unit per input frame), a keyframe only
    /// when asked (`requestKeyframe`) plus a GOP backstop, and in-band
    /// parameter sets on every keyframe (`AV_CODEC_FLAG_GLOBAL_HEADER` is
    /// deliberately *not* set) — because that is what the viewer relies on to
    /// join mid-stream and to recover from a PLI without out-of-band
    /// extradata.
    ///
    /// Output is converted to **AVCC** here, so callers deal only in the
    /// wire's container. `setBitrate` and `requestKeyframe` map directly onto
    /// the two congestion levers `CaptureEncoding` exposes.
    public final class VideoEncoder: @unchecked Sendable {
        private let ctx: UnsafeMutablePointer<AVCodecContext>
        private let pkt: UnsafeMutablePointer<AVPacket>
        private let frame: UnsafeMutablePointer<AVFrame>
        private var nextPTS: Int64 = 0
        private var forceKeyframe = false

        public let width: Int
        public let height: Int
        public let codec: Codec
        /// The libavcodec encoder actually selected — worth logging, since the
        /// same `Codec` may resolve to libx264 on one host and VA-API on
        /// another, with quite different behaviour under rate control.
        public let encoderName: String

        /// An encoded access unit, in AVCC.
        public struct EncodedAU: Sendable {
            public let data: Data
            public let isKeyframe: Bool
            public init(data: Data, isKeyframe: Bool) {
                self.data = data
                self.isKeyframe = isKeyframe
            }
        }

        /// - Parameters:
        ///   - encoderName: an explicit libavcodec encoder, or nil to take
        ///     libavcodec's default for `codec`. Use
        ///     ``FFmpeg/firstAvailableEncoder(for:preferring:)`` to pick.
        ///   - bitrate: target bits per second. Also sets the rate-control
        ///     ceiling; see ``setBitrate(_:)`` for the live-retune path.
        public init(
            codec: Codec,
            width: Int,
            height: Int,
            fps: Int,
            bitrate: Int,
            encoderName: String? = nil
        ) throws {
            guard width > 0, height > 0, fps > 0 else {
                throw DecodeError(message: "invalid encoder geometry \(width)x\(height)@\(fps)")
            }
            let enc: UnsafePointer<AVCodec>? =
                encoderName.flatMap { avcodec_find_encoder_by_name($0) } ?? avcodec_find_encoder(codec.avID)
            guard let enc else {
                throw DecodeError(message: "no encoder for \(codec)\(encoderName.map { " (\($0))" } ?? "")")
            }
            guard let c = avcodec_alloc_context3(enc) else {
                throw DecodeError(message: "avcodec_alloc_context3 failed")
            }
            // Even widths/heights: 4:2:0 chroma is half-resolution in both
            // axes, and an odd dimension gives libavcodec a partial chroma row.
            c.pointee.width = Int32(width & ~1)
            c.pointee.height = Int32(height & ~1)
            c.pointee.pix_fmt = AV_PIX_FMT_YUV420P
            c.pointee.time_base = AVRational(num: 1, den: Int32(fps))
            c.pointee.framerate = AVRational(num: Int32(fps), den: 1)
            c.pointee.bit_rate = Int64(bitrate)
            c.pointee.rc_max_rate = Int64(bitrate)
            // One second of buffering: enough for the encoder to spend an IDR
            // burst without the rate controller starving the frames after it.
            c.pointee.rc_buffer_size = Int32(clamping: bitrate)
            c.pointee.max_b_frames = 0
            // Backstop only — real keyframes come from `requestKeyframe` when a
            // viewer PLIs or a new viewer joins.
            c.pointee.gop_size = Int32(fps * 2)
            // x264/x265 knobs; a no-op (and harmless) on encoders without them.
            av_opt_set(c.pointee.priv_data, "preset", "ultrafast", 0)
            av_opt_set(c.pointee.priv_data, "tune", "zerolatency", 0)
            if avcodec_open2(c, enc, nil) < 0 {
                var tmp: UnsafeMutablePointer<AVCodecContext>? = c
                avcodec_free_context(&tmp)
                throw DecodeError(message: "avcodec_open2 failed for \(codec)")
            }
            guard let p = av_packet_alloc(), let f = av_frame_alloc() else {
                var tmp: UnsafeMutablePointer<AVCodecContext>? = c
                avcodec_free_context(&tmp)
                throw DecodeError(message: "packet/frame allocation failed")
            }
            f.pointee.format = Int32(AV_PIX_FMT_YUV420P.rawValue)
            f.pointee.width = c.pointee.width
            f.pointee.height = c.pointee.height
            guard av_frame_get_buffer(f, 0) >= 0 else {
                var tmp: UnsafeMutablePointer<AVCodecContext>? = c
                avcodec_free_context(&tmp)
                throw DecodeError(message: "av_frame_get_buffer failed")
            }
            ctx = c
            pkt = p
            frame = f
            self.width = Int(c.pointee.width)
            self.height = Int(c.pointee.height)
            self.codec = codec
            self.encoderName = enc.pointee.name.map { String(cString: $0) } ?? "?"
        }

        deinit {
            var c: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&c)
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
        }

        /// Make the next encoded frame an IDR — the sharer's answer to a
        /// viewer PLI, and what a joining viewer needs before it can decode.
        public func requestKeyframe() {
            forceKeyframe = true
        }

        /// Retune the target bitrate live: the congestion controller's primary
        /// lever, applied without recreating the session so the stream never
        /// breaks. Software x264 picks this up on the next frame; some
        /// hardware encoders only honour it at the next IDR, which is why a
        /// keyframe is requested alongside.
        public func setBitrate(_ bps: Int) {
            guard bps > 0 else { return }
            ctx.pointee.bit_rate = Int64(bps)
            ctx.pointee.rc_max_rate = Int64(bps)
            ctx.pointee.rc_buffer_size = Int32(clamping: bps)
            requestKeyframe()
        }

        /// Encode one tightly-packed I420 frame. Plane sizes must be
        /// `width×height` and `⌈w/2⌉×⌈h/2⌉`; anything else is rejected rather
        /// than read out of bounds.
        public func encode(yPlane: [UInt8], uPlane: [UInt8], vPlane: [UInt8]) throws -> [EncodedAU] {
            let cw = (width + 1) / 2
            let ch = (height + 1) / 2
            guard yPlane.count >= width * height, uPlane.count >= cw * ch, vPlane.count >= cw * ch else {
                throw DecodeError(message: "plane sizes don't match \(width)x\(height)")
            }
            guard av_frame_make_writable(frame) >= 0 else {
                throw DecodeError(message: "av_frame_make_writable failed")
            }
            copyIn(yPlane, plane: 0, width: width, height: height)
            copyIn(uPlane, plane: 1, width: cw, height: ch)
            copyIn(vPlane, plane: 2, width: cw, height: ch)
            // AV_PICTURE_TYPE_I asks x264 for an IDR; clearing it back to NONE
            // afterwards is essential, or *every* subsequent frame is a
            // keyframe and the bitrate never comes back down.
            frame.pointee.pict_type = forceKeyframe ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE
            forceKeyframe = false
            frame.pointee.pts = nextPTS
            nextPTS += 1
            let r = avcodec_send_frame(ctx, frame)
            guard r >= 0 else { throw DecodeError(r) }
            return try drainPackets()
        }

        /// Flush the encoder's internal delay and return whatever is left.
        public func flush() throws -> [EncodedAU] {
            _ = avcodec_send_frame(ctx, nil)
            return try drainPackets()
        }

        private func copyIn(_ src: [UInt8], plane: Int, width: Int, height: Int) {
            let dst: UnsafeMutablePointer<UInt8>?
            let stride: Int
            switch plane {
            case 0: (dst, stride) = (frame.pointee.data.0, Int(frame.pointee.linesize.0))
            case 1: (dst, stride) = (frame.pointee.data.1, Int(frame.pointee.linesize.1))
            default: (dst, stride) = (frame.pointee.data.2, Int(frame.pointee.linesize.2))
            }
            guard let dst else { return }
            src.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                for row in 0..<height {
                    memcpy(dst + row * stride, base + row * width, width)
                }
            }
        }

        private func drainPackets() throws -> [EncodedAU] {
            var out: [EncodedAU] = []
            while true {
                let r = avcodec_receive_packet(ctx, pkt)
                if r == ffk_averror_eagain() || r == ffk_averror_eof() { break }
                if r < 0 { throw DecodeError(r) }
                defer { av_packet_unref(pkt) }
                if let data = pkt.pointee.data, pkt.pointee.size > 0 {
                    let annexB = Data(bytes: data, count: Int(pkt.pointee.size))
                    // libavcodec emits Annex-B; the wire carries AVCC.
                    if let avcc = NALUnit.annexBToAVCC(annexB) {
                        out.append(
                            EncodedAU(data: avcc, isKeyframe: pkt.pointee.flags & AV_PKT_FLAG_KEY != 0))
                    }
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
/// platform (see plans/porting-plan.md problem #3).
public enum NALUnit {
    /// Convert an AVCC access unit to Annex-B. `nalLengthSize` is the width of
    /// each NAL's length prefix (1, 2, or 4 bytes; H.264/HEVC avcC records use
    /// 4). Returns nil if the buffer is malformed — a length that runs past
    /// the end, or a zero-length NAL — so a corrupt packet can't be fed to the
    /// decoder as a partial stream.
    /// Split an Annex-B buffer into its constituent NAL payloads (start codes
    /// removed). Accepts both the 3-byte `00 00 01` and 4-byte `00 00 00 01`
    /// forms, which encoders mix freely within one access unit. Trailing
    /// zero-bytes (`trailing_zero_8bits`) are trimmed, since they belong to the
    /// stream framing rather than the NAL.
    public static func annexBNALs(_ annexB: Data) -> [Data] {
        let bytes = [UInt8](annexB)
        var starts: [(index: Int, codeLength: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i + 3, 3))
                    i += 3
                    continue
                }
                if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i + 4, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        var out: [Data] = []
        for (n, s) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].index - starts[n + 1].codeLength : bytes.count
            guard s.index < end else { continue }
            var slice = bytes[s.index..<end]
            while let last = slice.last, last == 0 { slice = slice.dropLast() }
            if !slice.isEmpty { out.append(Data(slice)) }
        }
        return out
    }

    /// Convert an Annex-B access unit to AVCC — the direction a non-Apple
    /// *sharer* needs, since libavcodec emits Annex-B and the wire carries
    /// AVCC. The inverse of ``avccToAnnexB(_:nalLengthSize:)``.
    ///
    /// Returns nil if a NAL is too large for `nalLengthSize` to describe,
    /// rather than silently truncating the length field into a stream the peer
    /// would mis-parse.
    public static func annexBToAVCC(_ annexB: Data, nalLengthSize: Int = 4) -> Data? {
        guard (1...4).contains(nalLengthSize) else { return nil }
        let maxLength = nalLengthSize == 4 ? Int(UInt32.max) : (1 << (8 * nalLengthSize)) - 1
        var out = Data()
        for nal in annexBNALs(annexB) {
            guard nal.count <= maxLength else { return nil }
            for shift in stride(from: (nalLengthSize - 1) * 8, through: 0, by: -8) {
                out.append(UInt8((nal.count >> shift) & 0xFF))
            }
            out.append(nal)
        }
        return out
    }

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
