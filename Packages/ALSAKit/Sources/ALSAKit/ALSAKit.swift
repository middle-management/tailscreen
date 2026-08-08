import CALSA
import Foundation

/// Thin Swift wrapper over ALSA (libasound) for the Linux viewer's audio
/// output. The macOS viewer plays decoded audio through AVAudioEngine; on
/// Linux this `ALSA.PCMPlayer` is the equivalent sink — it takes the exact
/// samples Tailscreen's audio path already produces (mono, 48 kHz, Float32 in
/// `[-1, 1]`, one 20 ms Opus frame = 960 samples) and writes them to a PCM
/// device.
///
/// ALSA output also works on PipeWire/PulseAudio systems through their
/// ALSA-compatibility PCM plugins, so it's a safe portable first backend
/// before a dedicated PipeWire path.
///
/// Namespaced under `ALSA` so `ALSA.PCMPlayer` / `ALSA.Error` don't collide
/// with libasound's own `snd_pcm_*` C surface.
public enum ALSA {
    /// libasound error surfaced to Swift. `code` is the raw negative errno the
    /// ALSA call returned; `message` is `snd_strerror`.
    public struct Error: Swift.Error, Equatable {
        public let code: Int32
        public let message: String

        init(_ code: Int32) {
            self.code = code
            self.message = String(cString: snd_strerror(code))
        }
    }

    /// A blocking PCM playback stream. One instance per output stream, driven
    /// from a single thread — libasound's PCM handle is not thread-safe.
    ///
    /// Uses the interleaved little-endian Float32 format (`FLOAT_LE`) so a
    /// Swift `[Float]` in `[-1, 1]` writes straight through with no conversion
    /// on little-endian hosts (every platform Tailscreen targets). Soft
    /// resampling is enabled so the stream still opens if the hardware can't do
    /// 48 kHz natively.
    public final class PCMPlayer {
        private let pcm: OpaquePointer
        private let channels: UInt32

        /// Open a playback stream.
        ///
        /// - Parameters:
        ///   - sampleRate: frames per second. Tailscreen's pipeline is 48 kHz.
        ///   - channels: interleaved channel count. Tailscreen's audio is mono.
        ///   - device: ALSA PCM name. `"default"` routes to the user's
        ///     configured output (often PipeWire/PulseAudio via their ALSA
        ///     plugin); `"null"` is the always-present discard device, useful
        ///     for headless testing.
        /// - Throws: `ALSA.Error` if the device can't be opened or configured.
        public init(sampleRate: UInt32 = 48_000, channels: UInt32 = 1, device: String = "default") throws {
            var handle: OpaquePointer?
            let openResult = snd_pcm_open(&handle, device, SND_PCM_STREAM_PLAYBACK, 0)
            guard openResult == 0, let handle else {
                throw Error(openResult)
            }

            // The simple all-in-one configuration path: format, access,
            // channels, rate, soft-resample on, and a target latency (in
            // microseconds) from which ALSA derives the buffer/period sizes.
            let paramResult = snd_pcm_set_params(
                handle,
                SND_PCM_FORMAT_FLOAT_LE,
                SND_PCM_ACCESS_RW_INTERLEAVED,
                channels,
                sampleRate,
                1,  // soft_resample: let ALSA resample if the HW can't do this rate
                50_000  // latency target in µs (50 ms)
            )
            guard paramResult == 0 else {
                snd_pcm_close(handle)
                throw Error(paramResult)
            }

            self.pcm = handle
            self.channels = channels
        }

        deinit {
            snd_pcm_close(pcm)
        }

        /// Write one buffer of interleaved Float32 samples, blocking until ALSA
        /// accepts them. `samples` is the raw interleaved stream — for mono
        /// that's simply the frame count; for N channels it must be a multiple
        /// of N.
        ///
        /// On an underrun (`-EPIPE`, the buffer drained before more audio
        /// arrived — expected on a jittery source) the stream is recovered with
        /// `snd_pcm_recover` and the write is retried once. Any other negative
        /// return, or a second underrun, is surfaced as `ALSA.Error`.
        ///
        /// - Returns: the number of frames (samples per channel) written.
        @discardableResult
        public func write(_ samples: [Float]) throws -> Int {
            guard !samples.isEmpty else { return 0 }
            let frames = snd_pcm_uframes_t(samples.count / Int(channels))

            func attempt() -> Int {
                samples.withUnsafeBufferPointer { buffer in
                    Int(snd_pcm_writei(pcm, buffer.baseAddress, frames))
                }
            }

            var written = attempt()
            if written == alsakit_EPIPE() {
                // Underrun: prepare/reset the stream, then retry once.
                let recovered = snd_pcm_recover(pcm, Int32(written), 1)
                if recovered < 0 { throw Error(recovered) }
                written = attempt()
            }
            guard written >= 0 else { throw Error(Int32(written)) }
            return written
        }

        /// Block until every queued sample has been played, then stop the
        /// stream. Call before shutting an output down so trailing audio isn't
        /// clipped.
        public func drain() throws {
            let result = snd_pcm_drain(pcm)
            guard result == 0 else { throw Error(result) }
        }
    }
}
