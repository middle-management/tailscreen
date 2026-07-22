import ALSAKit
import FFmpegKit
import Foundation
import TailscreenProtocol
import TailscreenViewer

// Concrete backends adapted to the portable `ViewerSession` seam. Each is a
// thin bridge — no policy, no buffering beyond what the backend already does —
// so the interesting logic all stays in the tested portable core and these
// stay glue.

// MARK: - Video decode (FFmpeg → VideoDecoding)

/// Adapts `FFmpegKit`'s libavcodec decoder to the viewer core's `VideoDecoding`
/// protocol. The decoder is created lazily on the first access unit because
/// libavcodec needs the codec up front, while `ViewerSession` learns it from
/// the RTP payload type and forwards it per-AU (`codec:`). A mid-stream codec
/// change (rare — only a sharer H.264↔HEVC fallback) recreates the decoder.
public final class FFmpegVideoDecoder: VideoDecoding {
    public var onDecodedFrame: ((any DecodedFrame) -> Void)?
    public var onDecodeFailure: (() -> Void)?

    private var decoder: FFmpeg.VideoDecoder?
    private var currentCodec: VideoCodec?

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
                        yPlane: frame.yPlane, uPlane: frame.uPlane, vPlane: frame.vPlane
                    )
                )
            }
        } catch {
            onDecodeFailure?()
        }
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

// MARK: - Audio output (ALSA → AudioSink)

/// Adapts `ALSAKit`'s PCM player to the viewer core's `AudioSink`. A write
/// failure (device gone, unrecoverable underrun) is logged and dropped — audio
/// is best-effort and must never stall the video path.
public final class ALSAAudioSink: AudioSink {
    private let player: ALSA.PCMPlayer

    public init(player: ALSA.PCMPlayer) {
        self.player = player
    }

    public func play(_ pcm: [Float]) {
        do {
            try player.write(pcm)
        } catch {
            FileHandle.standardError.write(Data("ALSA write failed: \(error)\n".utf8))
        }
    }
}
