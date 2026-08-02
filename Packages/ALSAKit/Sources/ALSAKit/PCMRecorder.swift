import CALSA
import Foundation

extension ALSA {
    /// A blocking PCM **capture** stream — the microphone counterpart to
    /// `ALSA.PCMPlayer`. One instance per input stream, driven from a single
    /// thread, for the same reason: libasound's PCM handle is not thread-safe.
    ///
    /// Same format choice as playback (interleaved `FLOAT_LE`, soft resampling
    /// on), and it hands the caller **mono** Float32 in `[-1, 1]` — the shape
    /// `OpusVoiceEncoder` takes — by averaging the device's channels itself.
    ///
    /// Where it deliberately differs from `PCMPlayer`: the player *dictates* its
    /// format via `snd_pcm_set_params`, and that's fine for output because a
    /// share always has 48 kHz mono to play and the `default` PCM is a plug
    /// chain that will convert anything. A capture device is the other way
    /// round — it has a format and you get it. Asking a stereo-only mic for one
    /// channel through `snd_pcm_set_params` is an `-EINVAL` at open, i.e. "no
    /// microphone", when the honest answer is "a stereo microphone". So the
    /// recorder negotiates with `snd_pcm_hw_params_set_channels_near` /
    /// `_set_rate_near`, publishes what it actually got as ``format``, and
    /// folds the channels down in Swift.
    ///
    /// The **rate** half is not folded here: `MonoPCMConverter` (in
    /// TailscreenKit, where Linux CI tests it) already does 48 kHz mono ↔ a
    /// device rate for the playback direction, and duplicating a resampler
    /// behind libasound would put it on a path only a non-48 kHz machine ever
    /// runs. Hence ``format`` reports the rate rather than hiding it.
    public final class PCMRecorder {
        /// What the device actually gave us, which is not necessarily what was
        /// asked for. `channels` is what the recorder folds to mono — it's
        /// published because "your mic is mono" and "your mic is 8-channel and
        /// we averaged it" are different facts about the audio a user hears.
        public struct Format: Equatable, Sendable {
            public let sampleRate: UInt32
            public let channels: UInt32

            public init(sampleRate: UInt32, channels: UInt32) {
                self.sampleRate = sampleRate
                self.channels = channels
            }
        }

        private let pcm: OpaquePointer

        /// The negotiated device format. Read this before reading audio.
        public let format: Format

        /// ALSA's chosen period, in frames — the natural read size, and the
        /// granularity at which the device makes audio available.
        public let periodFrames: Int

        /// Open a capture stream and negotiate a format with the device.
        ///
        /// - Parameters:
        ///   - preferredSampleRate: the rate to ask for. Tailscreen's pipeline
        ///     is 48 kHz. The device may answer with a different one — see
        ///     ``format``.
        ///   - preferredChannels: the channel count to ask for. Mono is
        ///     preferred (it's what gets encoded), but a stereo-only device is
        ///     accepted and folded.
        ///   - device: ALSA PCM name. `"default"` routes to the user's
        ///     configured input (often PipeWire/PulseAudio via their ALSA
        ///     plugin); `"null"` is the always-present discard device, which
        ///     captures digital silence and needs no hardware — useful for
        ///     headless testing.
        /// - Throws: `ALSA.Error` if the device can't be opened or configured.
        public init(
            preferredSampleRate: UInt32 = 48_000,
            preferredChannels: UInt32 = 1,
            device: String = "default"
        ) throws {
            var handle: OpaquePointer?
            let openResult = snd_pcm_open(&handle, device, SND_PCM_STREAM_CAPTURE, 0)
            guard openResult == 0, let handle else {
                throw Error(openResult)
            }

            do {
                (self.format, self.periodFrames) = try Self.configure(
                    handle,
                    preferredSampleRate: preferredSampleRate,
                    preferredChannels: preferredChannels
                )
            } catch {
                snd_pcm_close(handle)
                throw error
            }
            self.pcm = handle
        }

        deinit {
            snd_pcm_close(pcm)
        }

        /// Negotiate hardware + software parameters on an open capture handle
        /// and report back what the device settled on.
        private static func configure(
            _ pcm: OpaquePointer,
            preferredSampleRate: UInt32,
            preferredChannels: UInt32
        ) throws -> (Format, Int) {
            var hw: OpaquePointer?
            try check(snd_pcm_hw_params_malloc(&hw))
            guard let hw else { throw Error(-ENOMEM) }
            defer { snd_pcm_hw_params_free(hw) }

            // Start from everything the device can do, then narrow.
            try check(snd_pcm_hw_params_any(pcm, hw))
            // Soft resampling on, exactly as the player enables it — it lets a
            // device with no native 48 kHz still answer 48 kHz.
            try check(snd_pcm_hw_params_set_rate_resample(pcm, hw, 1))
            try check(snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED))
            try check(snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_FLOAT_LE))

            // `_near`, not the exact setters: a device that can't do what we
            // asked answers with what it can, instead of failing the open.
            var channels = preferredChannels
            try check(snd_pcm_hw_params_set_channels_near(pcm, hw, &channels))
            var rate = preferredSampleRate
            try check(snd_pcm_hw_params_set_rate_near(pcm, hw, &rate, nil))

            // A 20 ms period is exactly one Opus frame at 48 kHz (960 samples),
            // so a read lines up with an encode; the 100 ms ring is five of
            // them, which is the slack a reader gets before it overruns.
            var bufferTimeUs: UInt32 = 100_000
            try check(snd_pcm_hw_params_set_buffer_time_near(pcm, hw, &bufferTimeUs, nil))
            var periodTimeUs: UInt32 = 20_000
            try check(snd_pcm_hw_params_set_period_time_near(pcm, hw, &periodTimeUs, nil))

            try check(snd_pcm_hw_params(pcm, hw))

            // Read the committed values back off the params object rather than
            // trusting the `_near` out-params: `snd_pcm_hw_params` is what the
            // device actually accepted.
            var actualRate: UInt32 = 0
            try check(snd_pcm_hw_params_get_rate(hw, &actualRate, nil))
            var actualChannels: UInt32 = 0
            try check(snd_pcm_hw_params_get_channels(hw, &actualChannels))
            var period: snd_pcm_uframes_t = 0
            try check(snd_pcm_hw_params_get_period_size(hw, &period, nil))

            // Software params: start the stream on the first frame requested,
            // and wake the reader once a period is available. alsa-lib's
            // defaults happen to match, but a capture stream that never starts
            // is a silent hang with nothing to see in a log, so it's stated.
            var sw: OpaquePointer?
            try check(snd_pcm_sw_params_malloc(&sw))
            guard let sw else { throw Error(-ENOMEM) }
            defer { snd_pcm_sw_params_free(sw) }
            try check(snd_pcm_sw_params_current(pcm, sw))
            try check(snd_pcm_sw_params_set_start_threshold(pcm, sw, 1))
            try check(snd_pcm_sw_params_set_avail_min(pcm, sw, period))
            try check(snd_pcm_sw_params(pcm, sw))

            try check(snd_pcm_prepare(pcm))

            return (Format(sampleRate: actualRate, channels: actualChannels), Int(period))
        }

        private static func check(_ code: Int32) throws {
            guard code >= 0 else { throw Error(code) }
        }

        /// Read up to `frames` frames, blocking until the device has them, and
        /// return them folded to mono.
        ///
        /// On an overrun (`-EPIPE` — the ring filled because nobody read it in
        /// time, capture's mirror image of the player's underrun) the stream is
        /// recovered with `snd_pcm_recover` and the read is retried once. Any
        /// other negative return, or a second overrun, surfaces as `ALSA.Error`.
        ///
        /// The result can be **shorter** than `frames` (a signal can cut a read
        /// short, and a recovered stream restarts empty), so a caller that needs
        /// fixed 20 ms frames should reframe — `SystemAudioFramer` in
        /// TailscreenKit already does exactly that.
        ///
        /// - Returns: mono Float32 samples in `[-1, 1]`, one per captured frame.
        public func read(frames: Int) throws -> [Float] {
            guard frames > 0 else { return [] }
            let channels = Int(format.channels)
            var interleaved = [Float](repeating: 0, count: frames * channels)

            func attempt() -> Int {
                interleaved.withUnsafeMutableBufferPointer { buffer in
                    Int(snd_pcm_readi(pcm, buffer.baseAddress, snd_pcm_uframes_t(frames)))
                }
            }

            var captured = attempt()
            if captured == alsakit_EPIPE() {
                // Overrun: prepare/reset the stream, then retry once. The
                // `start_threshold` set at configure time is what restarts
                // capture — `snd_pcm_recover` only re-prepares it.
                let recovered = snd_pcm_recover(pcm, Int32(captured), 1)
                if recovered < 0 { throw Error(recovered) }
                captured = attempt()
            }
            guard captured >= 0 else { throw Error(Int32(captured)) }

            if captured < frames {
                interleaved.removeLast((frames - captured) * channels)
            }
            return Self.downmixToMono(interleaved, channels: channels)
        }

        /// Stop capturing and discard whatever the device has buffered
        /// (`snd_pcm_drop`) — the capture counterpart of the player's `drain`,
        /// which is its opposite by design: trailing *output* must be heard,
        /// trailing *input* recorded after the user stopped talking must not be
        /// sent. The stream is re-prepared, so a later `read` resumes.
        public func stop() throws {
            let dropped = snd_pcm_drop(pcm)
            guard dropped == 0 else { throw Error(dropped) }
            // The re-prepare is not tidiness: `snd_pcm_drop` leaves the handle
            // in SETUP, and every later read fails -EBADFD.
            let prepared = snd_pcm_prepare(pcm)
            guard prepared == 0 else { throw Error(prepared) }
        }

        /// Average `channels` interleaved samples per frame down to one.
        ///
        /// Averaging, not summing: two correlated channels summed hit twice
        /// full scale, and the clipping that follows is heard as distortion
        /// rather than reported as an error by anything in the pipeline.
        ///
        /// A trailing partial frame (a sample count that isn't a whole number
        /// of frames) is dropped rather than read past — the same defensive
        /// rule the RTP depacketizers use, for the same reason.
        static func downmixToMono(_ interleaved: [Float], channels: Int) -> [Float] {
            guard channels > 0 else { return [] }
            guard channels > 1 else { return interleaved }

            let frames = interleaved.count / channels
            var mono = [Float]()
            mono.reserveCapacity(frames)
            let scale = 1 / Float(channels)
            for frame in 0..<frames {
                let base = frame * channels
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += interleaved[base + channel]
                }
                mono.append(sum * scale)
            }
            return mono
        }
    }
}
