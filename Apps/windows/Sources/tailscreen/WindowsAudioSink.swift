import Foundation
import WASAPIKit

import struct TailscreenViewer.AudioOutputFormat
import protocol TailscreenViewer.AudioSink
import class TailscreenViewer.MonoPCMConverter

/// `AudioSink` backed by WASAPI shared-mode rendering.
///
/// Mirrors `ALSAAudioSink` on Linux — a device failure is logged and dropped,
/// never propagated, so audio can't take the video path down with it.
///
/// Opens lazily, on the first buffer: COM apartment state is per-thread, so
/// the thread that opens must be the thread that writes, and this sink is
/// always wrapped in a `ThreadedAudioSink` whose single drain thread is where
/// that has to happen.
///
/// Not thread-safe, and doesn't need to be: `ThreadedAudioSink` calls `play`
/// from one thread only.
final class WASAPIAudioSink: AudioSink {
    private enum State {
        case unopened
        case open(WASAPI.Player, MonoPCMConverter)
        /// Opening or writing failed. Stays silent for the rest of the
        /// session rather than retrying 50x/s against a device that's gone.
        /// Known limitation: also swallows a recoverable fault (switching
        /// default output device mid-call), which then needs a restart.
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

    /// stderr rather than a logger: the only channel that reaches a user not
    /// attached to a debugger.
    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
