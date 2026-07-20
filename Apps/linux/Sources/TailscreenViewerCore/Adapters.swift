import ALSAKit
import FFmpegKit
import Foundation
import SDLKit
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
    private var decoder: FFmpeg.VideoDecoder?
    private var currentCodec: VideoCodec?

    public init() {}

    public func decode(accessUnit: Data, codec: VideoCodec, isKeyframe: Bool) throws -> [DecodedVideoFrame] {
        let dec = try decoderFor(codec)
        let frames = try dec.decode(avcc: accessUnit)
        return frames.map {
            DecodedVideoFrame(
                width: $0.width, height: $0.height,
                yPlane: $0.yPlane, uPlane: $0.uPlane, vPlane: $0.vPlane
            )
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

// MARK: - Video render (SDL → VideoSink)

/// Adapts `SDLKit`'s YUV window to the viewer core's `VideoSink`. `present`
/// throwing (SDL upload/copy failure, or a bad plane size) is logged and
/// dropped rather than propagated — one bad frame shouldn't tear the session
/// down, and the next keyframe recovers the display.
public final class SDLVideoSink: VideoSink {
    private let window: SDL.VideoWindow
    /// The most recent frame, retained so `repaint()` can re-present it when no
    /// new frame is decoding. Video is event-driven (a frame only arrives when
    /// the sharer's screen changes), but an X window must be redrawn to stay
    /// on-screen — otherwise it blanks to white on the next expose. The mac
    /// renderer solves this with a continuous display-link; here the run loop
    /// calls `repaint()` each tick to the same effect.
    private var lastFrame: DecodedVideoFrame?

    public init(window: SDL.VideoWindow) {
        self.window = window
    }

    public func present(_ frame: DecodedVideoFrame) {
        lastFrame = frame
        draw(frame)
    }

    /// Re-present the last decoded frame (no-op until the first frame). Cheap
    /// and idempotent; called from the run loop so a static screen stays
    /// painted instead of blanking to white.
    public func repaint() {
        if let lastFrame { draw(lastFrame) }
    }

    private func draw(_ frame: DecodedVideoFrame) {
        do {
            try window.present(
                width: frame.width, height: frame.height,
                yPlane: frame.yPlane, uPlane: frame.uPlane, vPlane: frame.vPlane
            )
        } catch {
            FileHandle.standardError.write(Data("SDL present failed: \(error)\n".utf8))
        }
    }

    /// Pump the SDL event queue; true when the user closed the window.
    public func pollShouldClose() -> Bool { window.pollShouldClose() }
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
