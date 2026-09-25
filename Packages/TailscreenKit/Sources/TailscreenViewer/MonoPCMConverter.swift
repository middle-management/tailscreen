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

    /// - Note: both values are clamped to at least 1 — a zero rate would
    ///   divide by zero in the resample ratio.
    public init(sampleRate: Int, channelCount: Int) {
        self.sampleRate = max(1, sampleRate)
        self.channelCount = max(1, channelCount)
    }
}

/// Converts the viewer's 48 kHz mono Float32 PCM to an arbitrary device format.
/// WASAPI shared mode requires the stream to match the device's exact mix
/// format (commonly 48 kHz stereo, but 44.1 kHz and 6-channel both occur).
///
/// Deliberately NOT delegated to the OS resampler (`AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM`):
/// that path would only run on Windows with a non-48kHz device, so nothing in
/// this repo could test it. Converting here keeps the shipped code under test,
/// and in the common 48 kHz case the resampler is bypassed entirely.
///
/// Not thread-safe: carries resampler state between calls. `ThreadedAudioSink`
/// guarantees the single-threaded access this relies on.
public final class MonoPCMConverter {
    public let destination: AudioOutputFormat

    /// Input samples consumed per output sample. 1.0 when no resampling is
    /// needed, and the resampler is skipped.
    private let ratio: Double
    private let resamples: Bool

    /// Last sample of the previous buffer — left neighbour for positions
    /// before this buffer's first sample. Without it every buffer boundary
    /// would restart from silence and click ~50×/s.
    private var previous: Float = 0
    /// Next output sample's position, in input-sample units relative to this
    /// buffer's index 0. Starts at -1 (i.e. at `previous`), carried across calls.
    private var phase: Double = -1

    public init(destination: AudioOutputFormat) {
        self.destination = destination
        let source = AudioOutputFormat.viewerNative.sampleRate
        self.ratio = Double(source) / Double(destination.sampleRate)
        self.resamples = source != destination.sampleRate
    }

    /// Converts one buffer of mono 48 kHz PCM into interleaved device frames.
    ///
    /// - Parameter mono: 48 kHz mono Float32, typically 960 samples (20 ms).
    /// - Returns: interleaved Float32, `frames * destination.channelCount`
    ///   values; may be empty if a short input produces no whole output frame.
    public func convert(_ mono: [Float]) -> [Float] {
        guard !mono.isEmpty else { return [] }
        let frames = resamples ? resample(mono) : mono
        return interleave(frames)
    }

    /// Drops carried resampler state. Call on a discontinuity (new session,
    /// device change) so a stale neighbouring sample can't bleed across it.
    public func reset() {
        previous = 0
        phase = -1
    }

    /// Linear interpolation between neighbouring input samples. Linear rather
    /// than windowed-sinc: the only rates this runs at (48k→44.1k, 48k→96k)
    /// put linear artefacts far below what a lossy voice link already
    /// carries. Continuity ACROSS buffers is what matters, hence `previous`/`phase`.
    private func resample(_ input: [Float]) -> [Float] {
        let n = input.count
        var out: [Float] = []
        // Ceiling of the count the ratio implies, so the reserve is never short.
        out.reserveCapacity(Int(Double(n) / ratio) + 2)

        var position = phase
        // A sample at `position` interpolates floor(position) and +1. Index
        // -1 is `previous`; the highest right-hand neighbour is n-1, so
        // positions must stay below n-1.
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

        // Re-base onto the next buffer (its index 0 = this buffer's n,
        // `previous` = this buffer's last sample). `position` is >= n-1 here,
        // so the new phase is >= -1, as `index < 0` above relies on.
        phase = position - Double(n)
        previous = input[n - 1]
        return out
    }

    /// Spreads mono frames across the device's channels: front left/right
    /// only, silence elsewhere — duplicating into all channels on a 5.1
    /// endpoint would put full-range voice through the LFE and surrounds.
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
