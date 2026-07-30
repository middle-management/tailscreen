import Foundation
import WASAPIKit

import struct TailscreenViewer.AudioOutputFormat
import protocol TailscreenViewer.AudioSink
import class TailscreenViewer.MonoPCMConverter

/// `AudioSink` backed by WASAPI shared-mode rendering.
///
/// Mirrors `ALSAAudioSink` on Linux — same seam, same best-effort rule: a device
/// failure is logged and dropped, never propagated, because audio must not be
/// able to take the video path down with it.
///
/// **Opens lazily, on the first buffer.** Two reasons, and the first is not
/// optional: COM apartment state is per-thread, so the thread that calls
/// `ts_wasapi_open` must be the thread that writes. This sink is always wrapped
/// in a `ThreadedAudioSink`, whose single drain thread is therefore where the
/// open has to happen — doing it in `init` would open on whichever thread built
/// the session. The second reason is a bonus: a machine with no audio endpoint
/// costs nothing until audio actually arrives.
///
/// Not thread-safe, and does not need to be: `ThreadedAudioSink` calls `play`
/// from one thread only.
final class WASAPIAudioSink: AudioSink {
    private enum State {
        case unopened
        case open(WASAPI.Player, MonoPCMConverter)
        /// Opening or writing failed. Stays silent for the rest of the session
        /// rather than retrying 50×/s against a device that is not coming back.
        ///
        /// Known limitation: this also swallows a *recoverable* fault — the user
        /// switching default output device mid-call — which then needs the
        /// session restarted to get audio back. Reopening on the next buffer
        /// would fix that, and wants a retry budget so a permanently absent
        /// device does not thrash; deferred rather than guessed at.
        case failed
    }

    private var state: State = .unopened

    func play(_ pcm: [Float]) {
        guard !pcm.isEmpty else { return }

        switch state {
        case .failed:
            return

        case .unopened:
            do {
                let player = try WASAPI.Player()
                let converter = MonoPCMConverter(
                    destination: AudioOutputFormat(
                        sampleRate: player.format.sampleRate,
                        channelCount: player.format.channelCount))
                log(
                    "audio: WASAPI open at \(player.format.sampleRate) Hz, "
                        + "\(player.format.channelCount) ch")
                state = .open(player, converter)
                write(pcm, to: player, through: converter)
            } catch {
                log("audio: could not open the output device — continuing without sound (\(error))")
                state = .failed
            }

        case .open(let player, let converter):
            write(pcm, to: player, through: converter)
        }
    }

    private func write(_ pcm: [Float], to player: WASAPI.Player, through converter: MonoPCMConverter) {
        let interleaved = converter.convert(pcm)
        guard !interleaved.isEmpty else { return }
        do {
            try player.write(interleaved)
        } catch {
            log("audio: playback stopped (\(error))")
            state = .failed
        }
    }

    /// stderr rather than a logger: this file's failures are diagnosed from the
    /// captured console output of a downloaded artifact, which is the only
    /// channel that reaches a user who is not attached to a debugger.
    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
