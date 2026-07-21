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

/// Adapts `SDLKit`'s YUV window to the viewer core's `VideoSink`, driving **all**
/// SDL calls from a single dedicated thread.
///
/// SDL's window, renderer, and event queue must be created and used from one
/// consistent thread. The transport that feeds this sink runs as a Swift
/// `@MainActor` async loop, whose executor is not guaranteed to stay on one OS
/// thread across `await` points on Linux — so presenting directly from there
/// left the window silently unpainted (SDL no-ops rendering off its owning
/// thread, no error). Instead this sink owns a render thread that creates the
/// window and runs a continuous loop: pump events, present the latest decoded
/// frame (re-presenting it when idle so a static screen doesn't blank to white
/// on expose — the mac renderer's display-link, by hand). `present()` just
/// hands over the newest frame under a lock; the transport never touches SDL.
public final class ThreadedSDLVideoSink: VideoSink, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: DecodedVideoFrame?
    private var closed = false
    private var startupError: Error?
    private let ready = DispatchSemaphore(value: 0)

    /// Spawns the render thread and blocks until the window is up (or throws if
    /// window creation failed on that thread).
    public init(title: String, width: Int, height: Int, softwareRenderer: Bool) throws {
        let thread = Thread { [self] in
            renderLoop(title: title, width: width, height: height, softwareRenderer: softwareRenderer)
        }
        thread.name = "sdl-render"
        thread.stackSize = 4 << 20
        thread.start()
        ready.wait()
        lock.lock()
        let err = startupError
        lock.unlock()
        if let err { throw err }
    }

    /// Hand the newest frame to the render thread (drops any not-yet-shown
    /// frame — only the latest matters for display). Never calls SDL.
    public func present(_ frame: DecodedVideoFrame) {
        lock.lock()
        latest = frame
        lock.unlock()
    }

    /// True once the user closed the window (observed on the render thread).
    public func pollShouldClose() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func renderLoop(title: String, width: Int, height: Int, softwareRenderer: Bool) {
        let window: SDL.VideoWindow
        do {
            window = try SDL.VideoWindow(
                title: title, width: width, height: height, softwareRenderer: softwareRenderer)
        } catch {
            lock.lock()
            startupError = error
            lock.unlock()
            ready.signal()
            return
        }
        ready.signal()

        while true {
            if window.pollShouldClose() {
                lock.lock()
                closed = true
                lock.unlock()
                break
            }
            lock.lock()
            let frame = latest
            lock.unlock()
            if let frame {
                do {
                    try window.present(
                        width: frame.width, height: frame.height,
                        yPlane: frame.yPlane, uPlane: frame.uPlane, vPlane: frame.vPlane)
                } catch {
                    FileHandle.standardError.write(Data("SDL present failed: \(error)\n".utf8))
                }
            }
            Thread.sleep(forTimeInterval: 1.0 / 60.0)
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
