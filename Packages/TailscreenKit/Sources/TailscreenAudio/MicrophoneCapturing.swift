import Foundation

/// The device's PCM format, as a capture backend reports it. A separate type
/// from the viewer's `AudioOutputFormat` (identical fields, opposite
/// direction) so the audio tier doesn't depend on the viewer tier for a pair
/// of integers.
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

/// A microphone, as the portable voice path needs one. The third
/// host-supplied backend seam alongside `CaptureEncoding`/`InputInjecting`:
/// callbacks out, commands in, no platform type in the signature.
///
/// **Threading.** `onPCM` fires on whatever thread the backend captures on
/// (ALSA's read loop, WASAPI's event thread, an audio unit's render thread) —
/// never the main actor, and consumers must not do anything slow in it.
///
/// **Capability, not configuration.** A host with no working microphone
/// supplies no backend at all, like `InputInjecting` on a machine with no XTEST.
public protocol MicrophoneCapturing: AnyObject, Sendable {
    /// Interleaved Float32 frames at `format`.
    ///
    /// **`format` describes the buffer, not the device.** Both shipped
    /// backends fold to mono themselves but separately publish the device's
    /// own channel count for UI purposes — forwarding *that* alongside
    /// already-mono samples makes `CapturePCMConverter` downmix a second
    /// time (halves the rate, drops the pitch an octave, with no error). A
    /// mono-handing backend reports `channelCount: 1` regardless of hardware.
    ///
    /// Passed with every buffer, not read once, since a device can be
    /// reconfigured mid-stream.
    var onPCM: (([Float], AudioInputFormat) -> Void)? { get set }

    /// The capture stopped. Nil means the caller asked; an error means the
    /// device went away — unplugged, stolen by exclusive mode, suspended.
    var onStopped: ((Error?) -> Void)? { get set }

    func start() throws
    func stop()
}

/// Device-native interleaved Float32 → 48 kHz mono, the inverse of the
/// viewer's `MonoPCMConverter`. A separate type, not one parameterized by
/// direction — downmixing and spreading are different operations.
public final class CapturePCMConverter {
    /// The format last seen from the device. Nil until the first buffer.
    /// Tracked, not fixed at init, so a mid-stream device change reconfigures
    /// instead of resampling against a stale rate.
    private var source: AudioInputFormat?
    /// The previous output sample, so a buffer boundary interpolates from
    /// where the last one ended instead of clicking ~50×/s. Same role as
    /// `MonoPCMConverter.previous`.
    private var previous: Float = 0
    private var phase: Double = -1

    public init() {}

    /// Downmix to mono, then resample to 48 kHz — cheaper this order, and
    /// resampling first would interpolate each channel for nothing.
    public func convert(_ interleaved: [Float], from format: AudioInputFormat) -> [Float] {
        guard !interleaved.isEmpty, format.channelCount > 0, format.sampleRate > 0 else {
            return []
        }
        if source != format {
            // A discontinuity: the carried neighbour belongs to the old rate.
            source = format
            previous = 0
            phase = -1
        }
        let mono = downmix(interleaved, channels: format.channelCount)
        guard format.sampleRate != AudioInputFormat.wire.sampleRate else {
            // No resampling, but still carry the last sample for a later rate change.
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

    /// Average the channels of one interleaved frame. Not channel 0: a mono
    /// mic presented as stereo may put the signal on either channel.
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

    /// Linear interpolation, buffer-boundary continuous. Linear, not
    /// windowed-sinc: realistic ratios (44.1k→48k, 96k→48k) put the artefacts
    /// well below what a lossy voice link already carries.
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
        // Carry the fractional remainder — dropping it would re-align to a
        // sample boundary every ~20 ms and smear the pitch.
        phase = position - Double(n)
        return out
    }
}
