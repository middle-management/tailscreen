import Foundation
import WASAPIKit

import protocol TailscreenAudio.BlockingPCMSource
import protocol TailscreenAudio.MicrophoneCapturing
import struct TailscreenAudio.AudioInputFormat
import struct TailscreenAudio.CapturedPCM
import class TailscreenAudio.ThreadedMicrophone

/// `WASAPI.Recorder` behind the portable `BlockingPCMSource` seam — the Windows
/// sibling of `ALSAMicrophoneSource`.
///
/// Two things here are Windows-specific, and both are the reason this file
/// exists rather than the recorder conforming directly.
///
/// **The poll.** WASAPI's read does not block: it hands back whatever has
/// arrived since the last call, which between device periods is nothing.
/// `BlockingPCMSource` promises the opposite, so the wait lives here, as a
/// sleep of roughly half a device period. Without it the capture thread returns
/// empty in a tight loop and burns a core for as long as the microphone is on —
/// a bug that would look like nothing at all except a hot laptop.
///
/// **The COM apartment.** `WASAPI.Recorder` must be created and read on the
/// *same* thread, because `init` initialises that thread's apartment. So the
/// recorder is opened lazily on the first `readPCM`, which `ThreadedMicrophone`
/// guarantees runs on its capture thread — exactly the reason
/// `WASAPIAudioSink` opens lazily too. Building it in this type's `init` would
/// open the apartment on whoever assembled the session.
final class WASAPIMicrophoneSource: BlockingPCMSource {
    /// Half of a typical 10 ms shared-mode device period. Short enough that
    /// polling never becomes the dominant term in mouth-to-ear latency, long
    /// enough that the thread is asleep almost all the time.
    private static let pollInterval: TimeInterval = 0.005

    private var recorder: WASAPI.Recorder?
    private var openFailure: Error?
    private var format = AudioInputFormat.wire

    /// **Mono, whatever the hardware is** — `WASAPI.Recorder.read` folds the
    /// endpoint's channels itself. Reporting `recorder.format.channelCount`
    /// here would make `CapturePCMConverter` downmix a second time and drop
    /// every voice an octave. See `MicrophoneCapturing.onPCM`.
    var inputFormat: AudioInputFormat { format }

    func readPCM() throws -> CapturedPCM {
        if let openFailure { throw openFailure }
        let recorder = try openedRecorder()
        let chunk = try recorder.read()
        if chunk.isEmpty {
            // Nothing queued yet. Sleeping *here* is what honours the seam's
            // blocking contract; returning empty immediately would spin the
            // pump.
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        return CapturedPCM(samples: chunk.mono, discontinuity: chunk.discontinuity)
    }

    /// Dropping the recorder closes the WASAPI client (its `deinit` does the
    /// work). No read can be blocked in the kernel — the reads do not block —
    /// so there is nothing to interrupt: the pump wakes from its poll sleep,
    /// finds the flag cleared and exits.
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
            // Latched: a machine with no microphone (or one the privacy setting
            // refuses) must not be retried 200×/s. The pump turns the throw
            // into `onStopped(error)` and the host withholds the feature.
            openFailure = error
            throw error
        }
    }
}

/// Build the Windows microphone: a WASAPI capture session pumped by the
/// portable `ThreadedMicrophone`.
///
/// Never fails here — the device is opened on the capture thread (see above),
/// so "there is no microphone" surfaces as `onStopped(error)` shortly after
/// `start()` rather than as a throw from this call. A host must therefore treat
/// that callback, not this return, as the capability signal.
func makeWASAPIMicrophone() -> MicrophoneCapturing {
    ThreadedMicrophone(source: WASAPIMicrophoneSource(), threadName: "tailscreen.microphone")
}
