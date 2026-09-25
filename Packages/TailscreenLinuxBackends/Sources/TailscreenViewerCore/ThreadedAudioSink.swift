import ALSAKit
import Foundation
import TailscreenViewer

// `ThreadedAudioSink` itself moved to TailscreenKit's TailscreenViewer target
// (nothing Linux-specific; Windows needs the identical wrapper). What stays
// here is the one piece that genuinely names ALSA.

/// Build the Linux viewer's default audio sink: an `ALSAAudioSink` fronted by a
/// `ThreadedAudioSink` so the blocking device write never runs on the caller's
/// thread. Keeps `ALSAKit` an internal detail of Core — callers only see
/// `AudioSink`.
///
/// - Throws: `ALSA.Error` if the PCM device can't be opened/configured. Callers
///   treat audio as best-effort and continue video-only on failure.
public func makeThreadedALSAAudioSink(device: String = "default") throws -> AudioSink {
    let player = try ALSA.PCMPlayer(device: device)
    return ThreadedAudioSink(wrapping: ALSAAudioSink(player: player))
}
