import COpus
import Foundation

/// Thin Swift wrapper over libopus for Tailscreen's audio path (mono, 48 kHz
/// — the sample rate the whole pipeline already runs at). Foundation-only and
/// cross-platform: the same source builds on macOS, Linux, and Windows
/// against a system libopus.
///
/// Namespaced under `Opus` so `Opus.Encoder` / `Opus.Decoder` don't collide
/// with libopus's own opaque `OpusEncoder` / `OpusDecoder` C types.
public enum Opus {
    /// Audio parameters Tailscreen fixes across the pipeline. Opus supports
    /// others, but the capture/mix path is mono 48 kHz, so we don't expose
    /// the knobs we never turn.
    public static let sampleRate: Int32 = 48_000
    public static let channels: Int32 = 1

    /// A valid Opus frame duration, in samples per channel at 48 kHz. Opus
    /// only accepts these exact frame sizes; 20 ms (960) is the default voice
    /// frame and what the AAC path's ~21 ms AU cadence maps onto most cleanly.
    public enum FrameSize: Int32, Sendable, CaseIterable {
        case ms2_5 = 120
        case ms5 = 240
        case ms10 = 480
        case ms20 = 960
        case ms40 = 1920
        case ms60 = 2880
    }

    /// Opus encoder application mode. A Swift-native mirror of the
    /// `OPUS_APPLICATION_*` C macros so callers never have to import the
    /// underlying `COpus` module to pick one.
    public enum Application: Sendable {
        /// Best for speech (default) — the voice path.
        case voip
        /// Best for music / general audio — the shared system-audio path.
        case audio
        /// Lowest algorithmic delay, disables some prediction.
        case restrictedLowDelay

        var rawValue: Int32 {
            switch self {
            case .voip: return OPUS_APPLICATION_VOIP
            case .audio: return OPUS_APPLICATION_AUDIO
            case .restrictedLowDelay: return OPUS_APPLICATION_RESTRICTED_LOWDELAY
            }
        }
    }

    /// libopus error surfaced to Swift. `code` is the raw `OPUS_*` return
    /// value; `message` is `opus_strerror`.
    public struct CodecError: Error, Equatable {
        public let code: Int32
        public let message: String

        init(_ code: Int32) {
            self.code = code
            self.message = String(cString: opus_strerror(code))
        }
    }

    /// Opus encoder. One instance per stream (the encoder is stateful — it
    /// carries inter-frame prediction), driven from a single thread.
    public final class Encoder: @unchecked Sendable {
        private let encoder: OpaquePointer
        /// Worst-case Opus packet is ~1275 bytes for 20 ms mono; give a
        /// generous fixed ceiling so `encode` never reallocates.
        private var scratch = [UInt8](repeating: 0, count: 4000)

        /// - Parameter application: `.voip` (default, tuned for speech),
        ///   `.audio`, or `.restrictedLowDelay`.
        public init(application: Application = .voip) throws {
            var error: Int32 = 0
            guard let enc = opus_encoder_create(sampleRate, channels, application.rawValue, &error),
                error == OPUS_OK
            else {
                throw CodecError(error)
            }
            encoder = enc
        }

        deinit { opus_encoder_destroy(encoder) }

        /// Set the target bitrate in bits/second (e.g. 24_000 for voice).
        /// `OPUS_AUTO` lets libopus pick from the frame size.
        public func setBitrate(_ bitsPerSecond: Int32) throws {
            let result = opuskit_encoder_set_bitrate(encoder, bitsPerSecond)
            if result != OPUS_OK { throw CodecError(result) }
        }

        /// Encode exactly one frame of interleaved 16-bit PCM. `pcm` must hold
        /// exactly `frameSize.rawValue` samples (mono). Returns the compressed
        /// Opus packet.
        public func encode(_ pcm: [Int16], frameSize: FrameSize = .ms20) throws -> Data {
            guard pcm.count == Int(frameSize.rawValue) else {
                throw CodecError(OPUS_BAD_ARG)
            }
            let written: Int32 = scratch.withUnsafeMutableBufferPointer { out in
                pcm.withUnsafeBufferPointer { input in
                    guard let inBase = input.baseAddress, let outBase = out.baseAddress else {
                        return OPUS_BAD_ARG
                    }
                    return opus_encode(encoder, inBase, frameSize.rawValue, outBase, Int32(out.count))
                }
            }
            guard written > 0 else { throw CodecError(written) }
            return Data(scratch[0..<Int(written)])
        }
    }

    /// Opus decoder. Stateful (packet-loss concealment carries across
    /// packets), one per stream, single-threaded.
    public final class Decoder: @unchecked Sendable {
        private let decoder: OpaquePointer
        private let maxFrame: Int32

        /// - Parameter maxFrameSize: the largest frame this stream will
        ///   decode; sizes the output buffer. Defaults to 60 ms so any frame
        ///   the encoder emits fits.
        public init(maxFrameSize: FrameSize = .ms60) throws {
            var error: Int32 = 0
            guard let dec = opus_decoder_create(sampleRate, channels, &error), error == OPUS_OK else {
                throw CodecError(error)
            }
            decoder = dec
            maxFrame = maxFrameSize.rawValue
        }

        deinit { opus_decoder_destroy(decoder) }

        /// Decode one Opus packet to interleaved 16-bit PCM. Pass `nil` to
        /// invoke packet-loss concealment (Opus synthesizes a plausible frame
        /// for a dropped packet — the viewer's jitter buffer uses this on a
        /// gap). Returns the decoded mono samples.
        public func decode(_ packet: Data?, frameSize: FrameSize? = nil) throws -> [Int16] {
            let sampleCap = frameSize?.rawValue ?? maxFrame
            var pcm = [Int16](repeating: 0, count: Int(sampleCap))
            let decoded: Int32
            if let packet {
                decoded = packet.withUnsafeBytes { raw -> Int32 in
                    pcm.withUnsafeMutableBufferPointer { out -> Int32 in
                        guard let inBase = raw.bindMemory(to: UInt8.self).baseAddress,
                            let outBase = out.baseAddress
                        else { return OPUS_BAD_ARG }
                        return opus_decode(decoder, inBase, Int32(packet.count), outBase, sampleCap, 0)
                    }
                }
            } else {
                // Packet-loss concealment: null input, 0 length, one frame out.
                decoded = pcm.withUnsafeMutableBufferPointer { out -> Int32 in
                    guard let outBase = out.baseAddress else { return OPUS_BAD_ARG }
                    return opus_decode(decoder, nil, 0, outBase, sampleCap, 0)
                }
            }
            guard decoded >= 0 else { throw CodecError(decoded) }
            return Array(pcm[0..<Int(decoded)])
        }
    }
}
