import FFmpegKit
import Foundation
import TailscreenProtocol
import TailscreenViewer

// libavcodec adapted to the portable `ViewerSession` seam. A thin bridge — no
// policy, no buffering beyond what the backend already does — so the
// interesting logic stays in the tested portable core and this stays glue.

// MARK: - Video decode (FFmpeg → VideoDecoding)

/// Adapts `FFmpegKit`'s libavcodec decoder to the viewer core's `VideoDecoding`
/// protocol. Created lazily on the first access unit, since libavcodec needs
/// the codec up front while `ViewerSession` learns it from the RTP payload
/// type per-AU. A mid-stream codec change (a sharer H.264↔HEVC fallback)
/// recreates the decoder.
///
/// `@unchecked Sendable`: every mutation happens on the one serialization
/// context the host drives the session on (`decode` per its threading
/// contract; `reset()` fired synchronously from the same context).
public final class FFmpegVideoDecoder: VideoDecoding, @unchecked Sendable {
    public var onDecodedFrame: ((any DecodedFrame) -> Void)?
    public var onDecodeFailure: (() -> Void)?

    private var decoder: FFmpeg.VideoDecoder?
    private var currentCodec: VideoCodec?

    /// Decode-error messages already reported, so a permanent failure names
    /// itself once instead of 60 times a second. Without this, a missing
    /// decoder (`avcodec_find_decoder` → nil) throws a Swift error, never
    /// reaches `av_log`, and is answered with a PLI — the viewer stays blank
    /// with nothing saying why.
    private var reportedFailures: Set<String> = []

    public init() {}

    /// libavcodec decodes synchronously, so frames are delivered through
    /// `onDecodedFrame` inside this call (satisfying the session's threading
    /// contract for free). A decode error routes to `onDecodeFailure` → PLI.
    public func decode(accessUnit: Data, codec: VideoCodec, isKeyframe: Bool) {
        do {
            let dec = try decoderFor(codec)
            let frames = try dec.decode(avcc: accessUnit)
            for frame in frames {
                onDecodedFrame?(
                    DecodedVideoFrame(
                        width: frame.width, height: frame.height,
                        yPlane: frame.yPlane, uPlane: frame.uPlane, vPlane: frame.vPlane,
                        colorInfo: Self.colorInfo(of: frame)
                    )
                )
            }
        } catch {
            report(error, codec: codec)
            onDecodeFailure?()
        }
    }

    /// Translate libavcodec's colour reporting into the portable tier's.
    /// `unspecified` → `.limited` (H.264/HEVC both define an absent
    /// `video_full_range_flag` this way), resolved here rather than inside
    /// FFmpegKit, so the raw "stream said nothing" answer stays visible.
    static func colorInfo(of frame: FFmpeg.Frame) -> VideoColorInfo {
        VideoColorInfo(
            range: frame.colorRange == .full ? .full : .limited,
            primaries: portablePrimaries(frame.colorPrimaries),
            transfer: portableTransfer(frame.colorTransfer))
    }

    private static func portablePrimaries(_ primaries: FFmpeg.ColorPrimaries) -> VideoColorPrimaries {
        switch primaries {
        case .bt709: return .bt709
        case .bt601: return .bt601
        case .displayP3: return .displayP3
        case .bt2020: return .bt2020
        case .unspecified: return .unspecified
        case .other(let code): return .other(code)
        }
    }

    private static func portableTransfer(_ transfer: FFmpeg.ColorTransfer) -> VideoTransferFunction {
        switch transfer {
        case .bt709: return .bt709
        case .srgb: return .srgb
        case .pq: return .pq
        case .hlg: return .hlg
        case .unspecified: return .unspecified
        case .other(let code): return .other(code)
        }
    }

    /// Drop the lazy libavcodec decoder so the next access unit builds a
    /// fresh one — the host-side answer to the escalation ladder's
    /// wedged-decoder rung. An internal reset rather than recreating the
    /// whole object: `ViewerSession` holds this for the session's lifetime,
    /// and the fresh decoder picks parameter sets back up from the next
    /// in-band keyframe. `reportedFailures` deliberately survives — a
    /// rebuilt decoder failing with the same message isn't news.
    public func reset() {
        decoder = nil
        currentCodec = nil
    }

    /// Name a decode failure on stderr, once per distinct message. stderr,
    /// not a logger: this package deliberately depends on neither
    /// TailscaleKit (would drag in libtailscale) nor any host.
    private func report(_ error: any Error, codec: VideoCodec) {
        let message = "\(error)"
        guard reportedFailures.insert(message).inserted else { return }
        FileHandle.standardError.write(
            Data("[video] \(codec) decode failed: \(message)\n".utf8))
    }

    /// Return the decoder for `codec`, (re)creating it if the codec changed.
    private func decoderFor(_ codec: VideoCodec) throws -> FFmpeg.VideoDecoder {
        if let decoder, currentCodec == codec { return decoder }
        let fresh = try FFmpeg.VideoDecoder(codec: codec.ffmpeg)
        decoder = fresh
        currentCodec = codec
        return fresh
    }
}

extension VideoCodec {
    /// Map the wire codec to FFmpegKit's codec selector.
    var ffmpeg: FFmpeg.Codec {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}
