import Foundation

// Codec-level wire types + encoder tuning constants, in their own file (not
// VideoEncoder.swift) because they are part of the platform-portable
// TailscreenProtocol set — see TailscreenKit/README.md. Nothing
// here may import an Apple framework.

/// Codec used on the wire. The sharer picks at startup (preferring HEVC
/// when the host's VideoToolbox HW encoder accepts it); the viewer learns
/// it from the RTP payload type. Distinct payload types (96/97) let the
/// receiver demux without negotiation.
public enum VideoCodec: String, Codable, Sendable {
    case h264
    case hevc
}

/// Parameter sets needed to build a `CMFormatDescription` for the negotiated
/// codec. H.264 carries SPS+PPS; HEVC additionally carries VPS.
public enum CodecParameterSets: Sendable, Equatable {
    case h264(sps: Data, pps: Data)
    case hevc(vps: Data, sps: Data, pps: Data)
}

/// Internal encoder rate-control tuning, centralized (like
/// `TransportTuning`) so the constants are documented in one place and
/// pinned by `QualitySettingsTests`. Deliberately not user-facing — the
/// user-visible knobs (fps cap, codec preference, bandwidth ceiling) live
/// in `QualitySettings`.
public enum EncoderTuning {
    /// Perceptual-quality target for `kVTCompressionPropertyKey_Quality`.
    /// Rate control runs primarily off this; `DataRateLimits` is only the
    /// ceiling (see `VideoEncoder.createSession` / `applyBitrate`).
    public static let quality = 0.7

    /// Max frames handed to VT that haven't come back through the output
    /// callback yet (see `VideoEncoder.inFlight`).
    public static let maxInFlight = 2

    /// Safety-net keyframe interval, in multiples of fps. IDRs are
    /// triggered on demand; this is a backstop, not a cadence.
    public static let keyframeIntervalMultiplier: Int32 = 10

    /// `DataRateLimits`: burst allowance over the window, as a multiple of
    /// the per-second budget. Generous enough for a single IDR burst,
    /// tight enough to prevent burst tail latency.
    public static let dataRateBurstFactor = 1.75

    /// `DataRateLimits`: window length in seconds.
    public static let dataRateWindowSeconds = 0.5
}
