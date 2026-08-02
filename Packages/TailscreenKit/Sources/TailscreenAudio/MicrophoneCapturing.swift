import Foundation

/// The device's PCM format, as a capture backend reports it.
///
/// A separate type from the viewer's `AudioOutputFormat` despite the identical
/// fields, and deliberately so: that one lives in `TailscreenViewer` and names
/// where audio is *going*, this one lives beside the codec and names where it
/// is *coming from*. Sharing it would make the audio tier depend on the viewer
/// tier for a pair of integers.
public struct AudioInputFormat: Equatable, Sendable {
    /// Frames per second, as the device negotiated it — 44 100 and 48 000 are
    /// both common, and a backend must report what it actually got rather than
    /// what it asked for.
    public let sampleRate: Int
    /// Interleaved channel count. Two is normal even for a mono microphone,
    /// because shared-mode capture usually hands back the mix format.
    public let channelCount: Int

    /// What the wire wants: 48 kHz mono, matching `OpusVoiceEncoder`.
    public static let wire = AudioInputFormat(sampleRate: 48_000, channelCount: 1)

    public init(sampleRate: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// A microphone, as the portable voice path needs one.
///
/// The third host-supplied backend seam, alongside `CaptureEncoding` and
/// `InputInjecting`, and shaped like them on purpose: callbacks out, commands
/// in, no platform type anywhere in the signature. ALSA, WASAPI and
/// AVAudioEngine differ in every detail of how they hand over samples and
/// agree on the only thing that matters here — interleaved Float32 at a format
/// they will tell you.
///
/// **Threading.** `onPCM` fires on whatever thread the backend captures on:
/// ALSA's read loop, WASAPI's event thread, an audio unit's render thread.
/// Implementations must not assume the main actor, and consumers must not do
/// anything slow in the callback — which is why `MicrophonePipeline` does
/// arithmetic only and hands the encoded result on.
///
/// **Capability, not configuration.** A host with no working microphone
/// supplies no backend at all rather than one that silently produces nothing.
/// That is the same rule `InputInjecting` follows on a machine with no XTEST:
/// the absence is what makes the UI honest.
public protocol MicrophoneCapturing: AnyObject, Sendable {
    /// Interleaved Float32 frames at `format`. The format is passed with every
    /// buffer rather than read once, because a device can be reconfigured
    /// underneath a running stream and a pipeline that cached the old rate
    /// would resample against it forever.
    var onPCM: (([Float], AudioInputFormat) -> Void)? { get set }

    /// The capture stopped. Nil means the caller asked; an error means the
    /// device went away — unplugged, stolen by exclusive mode, suspended.
    var onStopped: ((Error?) -> Void)? { get set }

    func start() throws
    func stop()
}

/// Device-native interleaved Float32 → 48 kHz mono, the inverse of the
/// viewer's `MonoPCMConverter`.
///
/// Portable for the reason every other converter in this tier is: it is
/// arithmetic that each backend would otherwise reimplement, and none of them
/// can test it in place. The two directions are deliberately separate types
/// rather than one parameterized by direction — downmixing several channels to
/// one and spreading one channel across several are different operations, and
/// a shared implementation would be a switch statement pretending to be reuse.
public final class CapturePCMConverter {
    /// The format last seen from the device. Nil until the first buffer.
    ///
    /// Tracked rather than fixed at init so a mid-stream device change
    /// reconfigures instead of silently resampling against a stale rate — the
    /// reason `MicrophoneCapturing.onPCM` carries its format at all.
    private var source: AudioInputFormat?
    /// The previous output sample, so a buffer boundary interpolates from
    /// where the last one ended rather than restarting at silence and clicking
    /// ~50×/s. Same role as `MonoPCMConverter.previous`, and the same bug if
    /// omitted.
    private var previous: Float = 0
    private var phase: Double = -1

    public init() {}

    /// Downmix to mono, then resample to 48 kHz.
    ///
    /// In that order because downmixing first is cheaper — it divides the
    /// sample count by the channel count before the interpolation runs — and
    /// because averaging channels after resampling would interpolate each
    /// channel separately for a result that gets averaged away anyway.
    public func convert(_ interleaved: [Float], from format: AudioInputFormat) -> [Float] {
        guard !interleaved.isEmpty, format.channelCount > 0, format.sampleRate > 0 else {
            return []
        }
        if source != format {
            // A genuine discontinuity: the carried neighbour belongs to the
            // old rate and interpolating across it would produce a click at
            // exactly the moment something already went wrong.
            source = format
            previous = 0
            phase = -1
        }
        let mono = downmix(interleaved, channels: format.channelCount)
        guard format.sampleRate != AudioInputFormat.wire.sampleRate else {
            // No resampling: still carry the last sample, so a later rate
            // change starts from real audio rather than from silence.
            previous = mono.last ?? previous
            return mono
        }
        return resample(mono, ratio: Double(format.sampleRate) / 48_000.0)
    }

    /// Forget carried state — a new session, or a device swap.
    public func reset() {
        source = nil
        previous = 0
        phase = -1
    }

    /// Average the channels of one interleaved frame.
    ///
    /// Averaging rather than taking channel 0: a headset that presents a mono
    /// mic as stereo may put the signal on either channel, and picking one
    /// gives silence half the time on hardware nobody tested against.
    private func downmix(_ interleaved: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return interleaved }
        let frames = interleaved.count / channels
        guard frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames)
        let scale = 1.0 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            let base = frame * channels
            for channel in 0..<channels { sum += interleaved[base + channel] }
            out[frame] = sum * scale
        }
        return out
    }

    /// Linear interpolation, buffer-boundary continuous.
    ///
    /// Linear rather than windowed-sinc for the same reason the viewer's
    /// direction is: the realistic ratios are 44.1 k → 48 k and 96 k → 48 k,
    /// where the artefacts sit far below what a lossy voice link already
    /// carries. The correctness that matters is continuity across buffers.
    private func resample(_ input: [Float], ratio: Double) -> [Float] {
        let n = input.count
        var out: [Float] = []
        out.reserveCapacity(Int(Double(n) / ratio) + 2)

        var position = phase
        while true {
            let leftIndex = Int(position.rounded(.down))
            let rightIndex = leftIndex + 1
            guard rightIndex < n else { break }
            let left = leftIndex < 0 ? previous : input[leftIndex]
            let right = input[rightIndex]
            let t = Float(position - Double(leftIndex))
            out.append(left + (right - left) * t)
            position += ratio
        }
        previous = input[n - 1]
        // Carry the fractional remainder into the next buffer, expressed
        // relative to that buffer's index 0. Dropping it would re-align to a
        // sample boundary every ~20 ms and smear the pitch.
        phase = position - Double(n)
        return out
    }
}
