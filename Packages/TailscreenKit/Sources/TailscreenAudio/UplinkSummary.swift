// The voice SEND path's `audio.uplink.summary` row, as a pure function on
// `UplinkStats` — the same shape as `VoiceStats.audioSummaryFields`, pinned
// the same way with no microphone behind it. `audio.summary` describes only
// what a machine HEARS, so "you sounded wrong to me" had nothing behind it.
// See `.claude/rules/diagnostics.md`.

import Foundation
import TailscreenProtocol

/// Counters for one window of outbound voice. Deltas against the previous
/// snapshot, like every other summary here.
public struct UplinkStats: Equatable, Sendable {
    /// 20 ms frames handed to the encoder and encoded without error.
    public var framesEncoded = 0
    /// Bytes of Opus produced — with `framesEncoded` this gives the bitrate
    /// actually achieved, which is the only way to see the encoder collapsing
    /// away from what it was asked for.
    public var bytesEncoded = 0
    public var encodeFailures = 0
    /// Captured buffers holding a sample outside [-1, 1]: the microphone or the
    /// host's input gain is clipping before anything of ours runs.
    public var clippedBuffers = 0
    /// Packets dropped for want of an assigned SSRC. A viewer that never got
    /// one is inaudible with nothing else to show for it.
    public var packetsWithheld = 0

    public init() {}
}

extension UplinkStats {

    /// What the capture chain was doing while the counters were measured. The
    /// format half cannot be derived after the fact, and is what a
    /// muffled-voice report needs.
    public struct CaptureContext: Equatable, Sendable {
        /// Whether capture is running. False records no row — a closed
        /// microphone is already stated by `mic.detached`.
        public var capturing: Bool
        /// Muted at the source. A muted window is still worth a row: it is the
        /// difference between "they cannot hear me" and "I was muted".
        public var muted: Bool
        /// Sample rate the device delivers, before any conversion of ours.
        /// Zero until the first buffer arrives — a host cannot know it earlier
        /// (on macOS `outputFormat(forBus:)` reports the output device's format
        /// until a buffer renders).
        public var captureSampleRate: Double
        /// Channels the device delivers. Above one with voice processing
        /// engaged this is typically `[mic, reference…]`, and which channel is
        /// taken decides whether speech or an echo reference is encoded.
        public var captureChannels: Int
        /// Whether the host's voice processing is engaged.
        public var voiceProcessing: Bool
        /// Loudest absolute sample this window, 0…1+. Near 1 says the signal
        /// is clipping at capture; near 0 with `mic_on` says a live microphone
        /// delivering nothing.
        public var peakLevel: Float
        /// Mean square root over the window — level as heard, where `peakLevel`
        /// is a single worst sample.
        public var rmsLevel: Double
        /// Bitrate the encoder was configured for, to read against the one
        /// `framesEncoded`/`bytesEncoded` actually achieved.
        public var encoderBitrate: Int

        public init(
            capturing: Bool = false,
            muted: Bool = false,
            captureSampleRate: Double = 0,
            captureChannels: Int = 0,
            voiceProcessing: Bool = false,
            peakLevel: Float = 0,
            rmsLevel: Double = 0,
            encoderBitrate: Int = 0
        ) {
            self.capturing = capturing
            self.muted = muted
            self.captureSampleRate = captureSampleRate
            self.captureChannels = captureChannels
            self.voiceProcessing = voiceProcessing
            self.peakLevel = peakLevel
            self.rmsLevel = rmsLevel
            self.encoderBitrate = encoderBitrate
        }

        /// Whether a sample-rate conversion stands between the device and Opus.
        /// Derived rather than passed so it cannot disagree with the rate
        /// beside it.
        public var resampling: Bool {
            captureSampleRate > 0 && captureSampleRate != Double(AudioInputFormat.wire.sampleRate)
        }
    }

    /// True while capture runs, muted or not. Deliberately not "only when a
    /// counter moved" — that hides the steady-state case this is for.
    public static func shouldRecordUplinkSummary(context: CaptureContext) -> Bool {
        context.capturing
    }

    /// Deltas for every counter, gauges as they stand. `bitrate_kbps` is what
    /// the window achieved against the `encoder_kbps` asked for; the two apart
    /// means the encoder is not delivering its configuration.
    public func uplinkSummaryFields(
        since previous: UplinkStats, windowNs: UInt64, context: CaptureContext
    ) -> [String: DiagnosticValue] {
        let frames = framesEncoded - previous.framesEncoded
        let bytes = bytesEncoded - previous.bytesEncoded
        let windowMs = windowNs / 1_000_000
        var fields: [String: DiagnosticValue] = [
            "window_ms": DiagnosticValue(windowMs),
            "frames_encoded": DiagnosticValue(frames),
            "bytes_encoded": DiagnosticValue(bytes),
            "encode_failures": DiagnosticValue(encodeFailures - previous.encodeFailures),
            "clipped": DiagnosticValue(clippedBuffers - previous.clippedBuffers),
            "withheld": DiagnosticValue(packetsWithheld - previous.packetsWithheld),
            "muted": .bool(context.muted),
            "voice_processing": .bool(context.voiceProcessing),
            "resampled": .bool(context.resampling),
            "peak_level": .double((Double(context.peakLevel) * 1000).rounded() / 1000),
            "rms_level": .double((context.rmsLevel * 1000).rounded() / 1000),
            "encoder_kbps": DiagnosticValue(context.encoderBitrate / 1000)
        ]
        if windowMs > 0 {
            fields["bitrate_kbps"] = DiagnosticValue(bytes * 8 / Int(windowMs))
        }
        // Absent rather than a zero that would read as "0 Hz, one channel".
        if context.captureSampleRate > 0 {
            fields["capture_hz"] = DiagnosticValue(Int(context.captureSampleRate.rounded()))
            fields["capture_channels"] = DiagnosticValue(context.captureChannels)
        }
        return fields
    }
}
