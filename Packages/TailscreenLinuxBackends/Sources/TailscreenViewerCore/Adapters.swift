import ALSAKit
import Foundation
// VIDEO half moved to Packages/TailscreenVideoFFmpeg so the Windows viewer can
// take the decoder without ALSA/X11; re-exported so existing call sites keep working.
@_exported import TailscreenVideoFFmpeg
import TailscreenViewer

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
