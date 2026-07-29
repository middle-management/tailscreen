import Foundation

/// An audio device's output format: interleaved Float32 at this rate and
/// channel count.
public struct AudioOutputFormat: Equatable, Sendable {
    /// Samples per second per channel.
    public let sampleRate: Int
    /// Interleaved channel count.
    public let channelCount: Int

    /// The format `AudioSink.play` is documented to receive, and the one
    /// `OpusVoiceDecoder` produces.
    public static let viewerNative = AudioOutputFormat(sampleRate: 48_000, channelCount: 1)

    /// - Note: both values are clamped to at least 1. A device reporting zero
    ///   for either is nonsense, and a zero rate would divide by zero in the
    ///   resample ratio; refusing to construct would push the same decision onto
    ///   every caller for a case that should never occur.
    public init(sampleRate: Int, channelCount: Int) {
        self.sampleRate = max(1, sampleRate)
        self.channelCount = max(1, channelCount)
    }
}

/// Converts the viewer's 48 kHz mono Float32 PCM to an arbitrary device format.
///
/// Lives in the portable tier for the same reason `I420Converter` does: it is
/// pure arithmetic that every platform backend needs and that no platform can
/// test. WASAPI shared mode requires the stream to match the device's mix
/// format exactly, and that format is whatever the user's endpoint reports —
/// commonly 48 kHz stereo, but 44.1 kHz and 6-channel both occur.
///
/// Deliberately NOT delegating this to the OS. WASAPI can resample for you
/// (`AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM`) and its sample-rate converter is
/// better than the linear interpolation here. But that would put the conversion
/// on a path that only runs on Windows, only on the machines whose device is not
/// 48 kHz, and that nothing in this repo can exercise. Converting here means the
/// code that runs is the code the tests cover, and in the overwhelmingly common
/// 48 kHz case the resampler is bypassed entirely.
///
/// Not thread-safe: it carries resampler state between calls. `ThreadedAudioSink`
/// guarantees the single-threaded access this relies on.
public final class MonoPCMConverter {
    public let destination: AudioOutputFormat

    /// Input samples consumed per output sample. 1.0 when no resampling is
    /// needed, in which case the resampler is skipped and the input passes
    /// through untouched.
    private let ratio: Double
    private let resamples: Bool

    /// The final sample of the previous buffer — the left neighbour for output
    /// positions that fall before this buffer's first sample. Without it every
    /// buffer boundary would restart from silence and click ~50×/s.
    private var previous: Float = 0
    /// Where the next output sample sits, in input-sample units relative to the
    /// current buffer's index 0. Starts at -1 (i.e. at `previous`) and is
    /// carried across calls.
    private var phase: Double = -1

    public init(destination: AudioOutputFormat) {
        self.destination = destination
        let source = AudioOutputFormat.viewerNative.sampleRate
        self.ratio = Double(source) / Double(destination.sampleRate)
        self.resamples = source != destination.sampleRate
    }

    /// Convert one buffer of mono 48 kHz PCM into interleaved device frames.
    ///
    /// - Parameter mono: 48 kHz mono Float32, typically 960 samples (20 ms).
    /// - Returns: interleaved Float32, `frames * destination.channelCount`
    ///   values. May be empty when a short input produces no whole output frame.
    public func convert(_ mono: [Float]) -> [Float] {
        guard !mono.isEmpty else { return [] }
        let frames = resamples ? resample(mono) : mono
        return interleave(frames)
    }

    /// Drop the carried resampler state. Call on a discontinuity (a new session,
    /// a device change) so a stale neighbouring sample cannot bleed across it.
    public func reset() {
        previous = 0
        phase = -1
    }

    /// Linear interpolation between neighbouring input samples.
    ///
    /// Linear rather than windowed-sinc on purpose: the only rates this runs at
    /// are 48 k → 44.1 k (ratio 1.088) and 48 k → 96 k, where linear artefacts
    /// sit far below what a voice channel over a lossy link already carries.
    /// The correctness that matters is continuity ACROSS buffers, which is what
    /// `previous` and `phase` exist for.
    private func resample(_ input: [Float]) -> [Float] {
        let n = input.count
        var out: [Float] = []
        // Ceiling of the count the ratio implies, so the reserve is never short.
        out.reserveCapacity(Int(Double(n) / ratio) + 2)

        var position = phase
        // An output sample at `position` interpolates indices floor(position)
        // and floor(position)+1. Index -1 is `previous`; the highest usable
        // right-hand neighbour is n-1, so positions must stay below n-1.
        let limit = Double(n) - 1
        while position < limit {
            let lower = position.rounded(.down)
            let index = Int(lower)
            let fraction = Float(position - lower)
            let a = index < 0 ? previous : input[index]
            let b = input[index + 1]
            out.append(a + (b - a) * fraction)
            position += ratio
        }

        // Re-base onto the next buffer, whose index 0 is this buffer's index n
        // and whose `previous` is this buffer's last sample. `position` is at
        // least n-1 here, so the new phase is at least -1 — the invariant the
        // interpolation's `index < 0` branch relies on.
        phase = position - Double(n)
        previous = input[n - 1]
        return out
    }

    /// Spread mono frames across the device's channels.
    ///
    /// The signal goes to the first two channels and silence to the rest, rather
    /// than to every channel. On a 5.1 endpoint, duplicating into all six would
    /// put full-range voice through the LFE and the surrounds; front left/right
    /// is what a mono source should sound like.
    private func interleave(_ frames: [Float]) -> [Float] {
        let channels = destination.channelCount
        if channels == 1 { return frames }

        var out = [Float](repeating: 0, count: frames.count * channels)
        let voiced = min(2, channels)
        for (frame, sample) in frames.enumerated() {
            let base = frame * channels
            for channel in 0..<voiced {
                out[base + channel] = sample
            }
        }
        return out
    }
}
