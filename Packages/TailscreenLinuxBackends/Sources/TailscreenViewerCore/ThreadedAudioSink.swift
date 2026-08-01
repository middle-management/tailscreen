import ALSAKit
import Foundation
import TailscreenViewer

// `ThreadedAudioSink` itself moved to Packages/TailscreenKit's TailscreenViewer
// target: it is thread + queue over the `AudioSink` protocol with nothing
// Linux-specific in it, and the Windows viewer needs the identical wrapper for
// the identical reason (a blocking device write on the UI thread freezes video).
// What stays here is the one piece that genuinely names ALSA.

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
