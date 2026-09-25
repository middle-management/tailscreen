import Foundation

#if os(Windows)
import CWASAPI
#endif

extension WASAPI {
    /// One read from the microphone: the samples, plus whether the endpoint
    /// admitted to having dropped something before them.
    public struct Chunk: Equatable, Sendable {
        /// Mono Float32 at `Recorder.format.sampleRate` — the device's rate, NOT
        /// resampled to 48 kHz. Empty when nothing was queued, which is the
        /// ordinary answer between device periods.
        public let mono: [Float]

        /// The endpoint flagged a glitch immediately before these samples —
        /// a hole not represented by any gap in `mono`. Surfaced rather than
        /// swallowed since a resampler holding cross-buffer state (the
        /// previous buffer's last sample) must reset it here.
        public let discontinuity: Bool

        public init(mono: [Float], discontinuity: Bool) {
            self.mono = mono
            self.discontinuity = discontinuity
        }

        public var isEmpty: Bool { mono.isEmpty }
    }

    /// A started capture session on the default microphone endpoint. The
    /// counterpart of `Player`, inheriting the same thread-affinity rule
    /// (create and read on the SAME thread — COM apartment state is per-thread).
    ///
    /// **The format is the device's, not yours.** Channel adaptation happens
    /// here (mixed to mono); rate adaptation does not — that belongs where
    /// Linux CI can exercise it, `MonoPCMConverter` in TailscreenKit.
    ///
    /// **Reads do not block.** `read()` returns whatever arrived since the
    /// last call, often nothing. The caller owns the polling cadence (and
    /// the 20ms framing Opus wants).
    public final class Recorder {
        public let format: Format

        #if os(Windows)
        /// `ts_wasapi_capture` is incomplete in the header, so this is
        /// `OpaquePointer` — nothing here can reach inside it.
        private var handle: OpaquePointer?
        /// Interleaved device-format scratch, allocated once and reused,
        /// sized to the largest a single capture packet can be — so
        /// `TS_WASAPI_ERR_BUFFER_TOO_SMALL` is unreachable by construction.
        private var scratch: [Float]
        private let capacityFrames: Int
        #endif

        public init() throws {
            #if os(Windows)
            var pointer: OpaquePointer?
            var rate: UInt32 = 0
            var channels: UInt32 = 0
            var bufferFrames: UInt32 = 0
            let code = ts_wasapi_capture_open(&pointer, &rate, &channels, &bufferFrames)
            guard code == 0, let pointer else {
                throw Error.from(code: code)
            }
            self.handle = pointer
            self.format = Format(sampleRate: Int(rate), channelCount: Int(channels))
            self.capacityFrames = Int(bufferFrames)
            self.scratch = [Float](repeating: 0, count: Int(bufferFrames) * Int(max(channels, 1)))
            #else
            throw Error.unsupportedPlatform
            #endif
        }

        deinit {
            #if os(Windows)
            ts_wasapi_capture_close(handle)
            #endif
        }

        /// Take everything the endpoint has queued right now.
        ///
        /// - Returns: mono samples at the device's rate. An empty chunk means
        ///   nothing had arrived yet — poll again, do not treat it as the end of
        ///   the stream.
        public func read() throws -> Chunk {
            #if os(Windows)
            guard let handle else { throw Error.invalidArgument }
            var frames: UInt32 = 0
            var discontinuity: Int32 = 0
            let code = scratch.withUnsafeMutableBufferPointer { buffer in
                ts_wasapi_capture_read(
                    handle, buffer.baseAddress, UInt32(capacityFrames), &frames, &discontinuity)
            }
            guard code == 0 else { throw Error.from(code: code) }
            let glitched = discontinuity != 0
            guard frames > 0 else { return Chunk(mono: [], discontinuity: glitched) }
            let samples = Int(frames) * format.channelCount
            return Chunk(
                mono: WASAPI.downmixToMono(scratch[0..<samples], channels: format.channelCount),
                discontinuity: glitched)
            #else
            throw Error.unsupportedPlatform
            #endif
        }
    }

    /// Average interleaved device frames down to one channel. Pure
    /// arithmetic, deliberately outside `#if os(Windows)` so it's testable anywhere.
    ///
    /// **Average, not sum** — summing a stereo mic with identical channels
    /// clips at 2.0. **Every channel, not just the first** — unlike macOS's
    /// voice-processing tap (`[mic, ref_L, ref_R]`, where averaging in the
    /// reference channels would mix the far end back in), WASAPI's shared-mode
    /// capture has no reference channels: a 2-channel device is a 2-channel
    /// microphone, and dropping half would throw audio away.
    ///
    /// Known cost: an interface reporting 6 channels with one live input
    /// reads ~15 dB quiet — compensating would mean guessing which channels
    /// are live, worse than a predictable error.
    ///
    /// A trailing partial frame is dropped rather than fabricated.
    static func downmixToMono(_ interleaved: ArraySlice<Float>, channels: Int) -> [Float] {
        // Also guards a nonsensical zero/negative channel count.
        guard channels > 1 else { return Array(interleaved) }

        let frames = interleaved.count / channels
        guard frames > 0 else { return [] }

        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        // `interleaved` is often a slice of a reused scratch buffer — never assume index 0.
        var index = interleaved.startIndex
        for frame in 0..<frames {
            var sum: Float = 0
            for _ in 0..<channels {
                sum += interleaved[index]
                index += 1
            }
            mono[frame] = sum * scale
        }
        return mono
    }

    /// `[Float]` convenience over the slice form.
    static func downmixToMono(_ interleaved: [Float], channels: Int) -> [Float] {
        downmixToMono(interleaved[...], channels: channels)
    }
}
