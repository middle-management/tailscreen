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

        /// The endpoint flagged a glitch immediately before these samples: the
        /// audio stream has a hole in it that is not represented by any gap in
        /// `mono`.
        ///
        /// It is surfaced rather than swallowed because the consumer carries
        /// state across buffers — a resampler holds the previous buffer's last
        /// sample as its left neighbour — and interpolating across a
        /// discontinuity smears an artefact over both sides of a cut that was
        /// already going to be audible. Whoever holds that state resets it.
        public let discontinuity: Bool

        public init(mono: [Float], discontinuity: Bool) {
            self.mono = mono
            self.discontinuity = discontinuity
        }

        public var isEmpty: Bool { mono.isEmpty }
    }

    /// A started capture session on the default microphone endpoint.
    ///
    /// The counterpart of `Player`, and it inherits the same two rules.
    ///
    /// **Thread affinity:** create it and read from it on the SAME thread. COM
    /// apartment state is per-thread and `init` initialises the calling thread's
    /// apartment.
    ///
    /// **The format is the device's, not yours.** `format` reports what the
    /// endpoint negotiated; the samples come back at that rate. The channel
    /// adaptation is done here (an N-channel endpoint is mixed to mono, because
    /// every consumer of a microphone in this app wants exactly one channel and
    /// no consumer wants to reimplement that); the RATE adaptation is not, for
    /// the same reason `Player` does not do it — the resampler belongs somewhere
    /// Linux CI can exercise it, and `MonoPCMConverter` in TailscreenKit is that
    /// place. Its 48 kHz-mono-in contract is the inverse of what a 44.1 kHz
    /// microphone produces, so a capture path on such a device needs a
    /// rate conversion this package deliberately does not smuggle in.
    ///
    /// **Reads do not block.** `read()` returns whatever has arrived since the
    /// last call, which is frequently nothing. The caller owns the polling
    /// cadence, because it also owns the 20 ms framing that Opus wants.
    public final class Recorder {
        public let format: Format

        #if os(Windows)
        /// `ts_wasapi_capture` is incomplete in the header, so Swift imports
        /// every pointer to it as `OpaquePointer` — nothing here can reach
        /// inside it, which is the point.
        private var handle: OpaquePointer?
        /// Interleaved device-format scratch, allocated once and reused. Sized
        /// to the engine buffer the shim reported, which is the largest a single
        /// capture packet can be — so `TS_WASAPI_ERR_BUFFER_TOO_SMALL` is
        /// unreachable from here by construction rather than by hoping.
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

    /// Average interleaved device frames down to one channel.
    ///
    /// Pure arithmetic, deliberately outside `#if os(Windows)`: it is the only
    /// part of the capture path that can be tested anywhere, so it is the part
    /// that carries the decisions.
    ///
    /// **Average, not sum.** Summing a stereo microphone whose two channels
    /// carry the same signal clips at 2.0, which is how the macOS mic path
    /// (`MicCapture`) came to pick channel 0 explicitly rather than let
    /// `AVAudioConverter` sum a 3-channel voice-processing layout to a peak
    /// of ~6.0. Averaging cannot clip, so this does not need that escape.
    ///
    /// **Every channel, not just the first.** macOS's channel-0 pick is right
    /// for the layout it faces — a voice-processing tap delivers `[mic, ref_L,
    /// ref_R]`, where channels 1+ are a loopback reference and averaging them in
    /// would mix the far end back into the near end. WASAPI shared-mode capture
    /// hands over the endpoint's own mix format with no such reference channels:
    /// a 2-channel capture device is a 2-channel microphone, and dropping half
    /// of it would be silently throwing audio away.
    ///
    /// The known cost: an interface that reports 6 channels with a single live
    /// input reads about 15 dB quiet. Compensating would mean guessing which
    /// channels are live from their content, and a gain that changes with what
    /// the room is doing is worse than one that is predictably wrong.
    ///
    /// A trailing partial frame is dropped — an interleaved buffer that is not a
    /// whole number of frames is already malformed, and inventing the missing
    /// channels would put a fabricated sample into the stream.
    static func downmixToMono(_ interleaved: ArraySlice<Float>, channels: Int) -> [Float] {
        // Also the guard for a nonsensical zero or negative channel count, which
        // would otherwise divide by zero. Passing the samples through matches
        // `AudioOutputFormat`'s clamp-rather-than-refuse stance on the same
        // input.
        guard channels > 1 else { return Array(interleaved) }

        let frames = interleaved.count / channels
        guard frames > 0 else { return [] }

        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        // `interleaved` is frequently a slice of a reused scratch buffer, whose
        // indices start wherever the slice does — never assume 0.
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
