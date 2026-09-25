import ALSAKit
import Foundation
import TailscreenAudio

/// `ALSA.PCMRecorder` behind the portable `BlockingPCMSource` seam.
/// Deliberately small: thread, mute latch, resampling, framing, RTP all live
/// in `TailscreenAudio`. What's left here is a period size and format translation.
final class ALSAMicrophoneSource: BlockingPCMSource {
    private let recorder: ALSA.PCMRecorder
    private let framesPerRead: Int

    init(recorder: ALSA.PCMRecorder) {
        self.recorder = recorder
        self.framesPerRead = max(1, recorder.periodFrames)
    }

    /// **Mono, whatever the hardware is.** `PCMRecorder.read` already folds
    /// channels down; reporting `recorder.format.channels` here would make
    /// `CapturePCMConverter` downmix a second time, halving the rate and
    /// dropping everyone's voice an octave. Rate is passed through as
    /// negotiated — resampled portably rather than refused.
    var inputFormat: AudioInputFormat {
        AudioInputFormat(sampleRate: Int(recorder.format.sampleRate), channelCount: 1)
    }

    /// Blocks in `snd_pcm_readi` until the device has a period, which is what
    /// `BlockingPCMSource` wants.
    ///
    /// `discontinuity` is always false: an ALSA overrun (`-EPIPE`) IS a
    /// discontinuity, but `PCMRecorder.read` recovers internally without
    /// telling anyone. Surfacing it needs an ALSAKit return-type change.
    func readPCM() throws -> CapturedPCM {
        CapturedPCM(samples: try recorder.read(frames: framesPerRead))
    }

    /// `snd_pcm_drop`, which also unblocks a `readPCM` parked in
    /// `snd_pcm_readi`. Failures swallowed — runs on the way out, and
    /// `PCMRecorder.deinit` closes the handle anyway.
    func closePCM() {
        try? recorder.stop()
    }
}

/// Build the Linux microphone: an ALSA capture stream pumped by the portable
/// `ThreadedMicrophone`.
///
/// - Throws: `ALSA.Error` when no capture device can be opened. Callers must
///   treat that as no microphone and withhold the feature, not show a mute
///   button that does nothing.
public func makeALSAMicrophone(device: String = "default") throws -> MicrophoneCapturing {
    let recorder = try ALSA.PCMRecorder(device: device)
    return ThreadedMicrophone(source: ALSAMicrophoneSource(recorder: recorder))
}
