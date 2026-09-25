import Foundation
import WASAPIKit

import struct TailscreenAudio.AudioInputFormat
import protocol TailscreenAudio.BlockingPCMSource
import struct TailscreenAudio.CapturedPCM
import protocol TailscreenAudio.MicrophoneCapturing
import class TailscreenAudio.ThreadedMicrophone

/// `WASAPI.Recorder` behind the portable `BlockingPCMSource` seam — the
/// Windows sibling of `ALSAMicrophoneSource`.
///
/// Two Windows-specific things: **the poll** — WASAPI's read doesn't block,
/// so `BlockingPCMSource`'s blocking contract is honoured with a sleep of
/// roughly half a device period, or the capture thread spins and burns a
/// core. **The COM apartment** — `WASAPI.Recorder` must be created and read
/// on the same thread, so it's opened lazily on the first `readPCM`, which
/// `ThreadedMicrophone` guarantees runs on its capture thread.
final class WASAPIMicrophoneSource: BlockingPCMSource {
    /// Half of a typical 10 ms shared-mode device period. Short enough that
    /// polling never becomes the dominant term in mouth-to-ear latency, long
    /// enough that the thread is asleep almost all the time.
    private static let pollInterval: TimeInterval = 0.005

    private var recorder: WASAPI.Recorder?
    private var openFailure: Error?
    private var format = AudioInputFormat.wire

    /// Mono, whatever the hardware is — `WASAPI.Recorder.read` folds the
    /// endpoint's channels itself. Reporting `recorder.format.channelCount`
    /// would make `CapturePCMConverter` downmix a second time.
    var inputFormat: AudioInputFormat { format }

    func readPCM() throws -> CapturedPCM {
        if let openFailure { throw openFailure }
        let recorder = try openedRecorder()
        let chunk = try recorder.read()
        if chunk.isEmpty {
            // Nothing queued yet; sleeping here honours the seam's blocking contract.
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        return CapturedPCM(samples: chunk.mono, discontinuity: chunk.discontinuity)
    }

    /// Dropping the recorder closes the WASAPI client. No read blocks in the
    /// kernel, so there's nothing to interrupt — the pump wakes from its poll
    /// sleep and exits.
    func closePCM() {
        recorder = nil
    }

    private func openedRecorder() throws -> WASAPI.Recorder {
        if let recorder { return recorder }
        do {
            let fresh = try WASAPI.Recorder()
            recorder = fresh
            format = AudioInputFormat(sampleRate: fresh.format.sampleRate, channelCount: 1)
            return fresh
        } catch {
            // Latched: a machine with no microphone must not be retried 200x/s.
            openFailure = error
            throw error
        }
    }
}

/// Build the Windows microphone: a WASAPI capture session pumped by the
/// portable `ThreadedMicrophone`. Never fails here — "there is no
/// microphone" surfaces as `onStopped(error)` shortly after `start()`.
func makeWASAPIMicrophone() -> MicrophoneCapturing {
    ThreadedMicrophone(source: WASAPIMicrophoneSource(), threadName: "tailscreen.microphone")
}
