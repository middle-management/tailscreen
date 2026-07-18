import Foundation

// Re-export OpusKit: `OpusVoiceEncoder.init` exposes `Opus.Application` in its
// signature, so consumers of TailscreenAudio need that type visible without a
// second import.
@_exported import OpusKit

/// Tailscreen's 48 kHz mono voice/audio codec, wrapping OpusKit (libopus).
///
/// This replaced the former AudioToolbox AAC-LC path. Opus is royalty-free,
/// software-only (no hardware/OS codec), and portable to Linux and Windows —
/// where AudioToolbox doesn't exist — which is why the Opus-only decision
/// (see `docs/porting-plan.md`) exists. The public interface is deliberately
/// the `[Float]` PCM one the old `AACEncoder` / `AACDecoder` had, so the
/// `VoiceChannel` / `SystemAudioTap` call sites are unchanged; the
/// Float32↔Int16 conversion libopus needs is confined here.
///
/// This is the portable audio tier of `TailscreenKit`: it depends
/// only on Foundation + OpusKit (both build on Linux/Windows), so a future
/// non-macOS client reuses the exact codec while supplying its own platform
/// audio I/O. It is kept out of the `TailscreenProtocol` target so that tier
/// stays dependency-free (Foundation/Synchronization only).
///
/// One Opus frame at 48 kHz mono is 20 ms = 960 samples. (AAC used
/// 1024-sample AUs; 960 is the nearest valid Opus frame, and the whole audio
/// pipeline — framing, RTP timestamp step, concealment — moved to it.)

/// Float32 [-1, 1] ↔ Int16 PCM. libopus's mono `opus_encode` / `opus_decode`
/// take/produce interleaved 16-bit samples; the rest of Tailscreen's audio
/// path (mixing, concealment, AVAudioEngine playback) is Float32.
public enum OpusPCM {
    /// Convert [-1, 1] Float32 to 16-bit PCM, clamping out-of-range input so
    /// a stray peak can't wrap around to the opposite sign.
    public static func floatToInt16(_ pcm: [Float]) -> [Int16] {
        pcm.map { sample in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16((clamped * 32767.0).rounded())
        }
    }

    /// Convert 16-bit PCM back to [-1, 1] Float32.
    public static func int16ToFloat(_ pcm: [Int16]) -> [Float] {
        pcm.map { Float($0) / 32767.0 }
    }
}

/// Encodes 48 kHz mono Float32 PCM into Opus packets, one packet per 960-sample
/// (20 ms) frame. Drop-in replacement for the former `AACEncoder`.
public final class OpusVoiceEncoder {
    /// One Opus frame at 48 kHz mono: 20 ms = 960 samples. Callers pass
    /// exactly this many Float32 samples per `encode`.
    public static let frameSamples = Int(Opus.FrameSize.ms20.rawValue)

    private let encoder: Opus.Encoder

    /// - Parameters:
    ///   - application: `.voip` for speech (default), `.audio` for the
    ///     system-audio (music/computer) path.
    ///   - bitrate: target bits/second. 64 kbps matches the old AAC voice
    ///     rate; Opus reaches equal quality with far less, but parity keeps
    ///     the wire footprint predictable and it's still tiny (< 8 KB/s).
    public init(application: Opus.Application = .voip, bitrate: Int32 = 64_000) throws {
        encoder = try Opus.Encoder(application: application)
        try encoder.setBitrate(bitrate)
    }

    /// Encode exactly `frameSamples` (960) Float32 samples ([-1, 1]) into one
    /// Opus packet. Returns nil only on an empty result — kept optional for
    /// source compatibility with the old buffered AAC encoder; Opus emits one
    /// packet per frame with no priming latency. Throws if `pcm.count != 960`.
    public func encode(pcm: [Float]) throws -> Data? {
        let packet = try encoder.encode(OpusPCM.floatToInt16(pcm), frameSize: .ms20)
        return packet.isEmpty ? nil : packet
    }
}

/// Decodes Opus packets back into 48 kHz mono Float32 PCM, 960 samples per
/// 20 ms frame. Drop-in replacement for the former `AACDecoder` — and, unlike
/// AAC via AudioToolbox, it needs no magic-cookie / AudioSpecificConfig priming.
public final class OpusVoiceDecoder {
    private let decoder: Opus.Decoder

    public init() throws {
        decoder = try Opus.Decoder(maxFrameSize: .ms60)
    }

    /// Decode one Opus packet into PCM samples (960 for a 20 ms frame).
    public func decode(au: Data) throws -> [Float] {
        OpusPCM.int16ToFloat(try decoder.decode(au))
    }
}
