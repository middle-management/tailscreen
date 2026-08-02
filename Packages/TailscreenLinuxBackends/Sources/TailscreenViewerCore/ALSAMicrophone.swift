import ALSAKit
import Foundation
import TailscreenAudio

/// `ALSA.PCMRecorder` behind the portable `BlockingPCMSource` seam.
///
/// The whole Linux-specific part of the microphone path, and deliberately this
/// small: the thread, the mute latch, the resampling, the framing and the RTP
/// all live in `TailscreenAudio` where Linux CI tests them. What is left here
/// is a period size and a format translation.
///
/// Kept in Core beside `makeThreadedALSAAudioSink` for the same reason that one
/// is: `ALSAKit` stays an internal detail, and callers see only portable types.
final class ALSAMicrophoneSource: BlockingPCMSource {
    private let recorder: ALSA.PCMRecorder
    private let framesPerRead: Int

    init(recorder: ALSA.PCMRecorder) {
        self.recorder = recorder
        self.framesPerRead = max(1, recorder.periodFrames)
    }

    /// **Mono, whatever the hardware is.** `PCMRecorder.read` folds the
    /// device's channels down itself, so reporting `recorder.format.channels`
    /// here — the obvious thing, and the thing the recorder publishes for the
    /// sharer's own information — would make `CapturePCMConverter` downmix a
    /// second time, reading N mono samples as N/2 stereo frames. That halves
    /// the rate and drops everyone's voice an octave, with nothing to catch it
    /// but an ear.
    ///
    /// The rate is passed through as negotiated: a 44.1 kHz-only device is
    /// resampled portably rather than being refused.
    var inputFormat: AudioInputFormat {
        AudioInputFormat(sampleRate: Int(recorder.format.sampleRate), channelCount: 1)
    }

    /// Blocks in `snd_pcm_readi` until the device has a period, which is what
    /// `BlockingPCMSource` wants — no polling loop needed on this platform.
    ///
    /// `discontinuity` is always false, and that is a known gap rather than a
    /// claim: an ALSA **overrun** (`-EPIPE`) is exactly a discontinuity, and
    /// `PCMRecorder.read` recovers from one internally without telling anyone.
    /// Surfacing it means a return-type change in ALSAKit; until then the cost
    /// is one interpolated sample pair across a hole that is already audible,
    /// which is the same cost the whole path paid before this flag existed.
    func readPCM() throws -> CapturedPCM {
        CapturedPCM(samples: try recorder.read(frames: framesPerRead))
    }

    /// `snd_pcm_drop` — which is also what unblocks a `readPCM` parked in
    /// `snd_pcm_readi`, the property `BlockingPCMSource` requires. Failures are
    /// swallowed: this runs on the way out, and there is nothing a caller can
    /// do about a device that will not stop except close the handle, which
    /// `PCMRecorder.deinit` does anyway.
    func closePCM() {
        try? recorder.stop()
    }
}

/// Build the Linux microphone: an ALSA capture stream pumped by the portable
/// `ThreadedMicrophone`.
///
/// - Throws: `ALSA.Error` when no capture device can be opened. Callers must
///   treat that as **no microphone** and withhold the feature rather than
///   showing a mute button that does nothing — the same capability-not-
///   configuration rule `InputInjecting` follows on a machine with no XTEST.
public func makeALSAMicrophone(device: String = "default") throws -> MicrophoneCapturing {
    let recorder = try ALSA.PCMRecorder(device: device)
    return ThreadedMicrophone(source: ALSAMicrophoneSource(recorder: recorder))
}
