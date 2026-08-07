import Foundation
import TailscreenProtocol

/// Cumulative voice-path resilience counters. The macOS app publishes these
/// under a lock so its MainActor playback side (`MicCapture`) and the
/// VoiceChannel queue can both write; the struct itself is a plain portable
/// value any host can snapshot.
public struct VoiceStats: Equatable, Sendable {
    /// Inbound buffers dropped because the playback queue was at its cap.
    public var overrunDrops = 0
    /// Times the playback queue drained to zero while the player was
    /// running — the audible starve.
    public var underruns = 0
    /// Silence frames emitted to cover sequence gaps.
    public var concealedFrames = 0
    /// Gaps too large to conceal; we resync instead of filling.
    public var discontinuities = 0
    /// Decoded buffers that contained at least one out-of-[-1, 1] sample.
    public var clampedBuffers = 0
    /// RFC 3550 smoothed inter-arrival jitter of the worst SSRC, in ms.
    public var smoothedJitterMs = 0.0

    public init() {}

    /// True when any *counter* differs from `other`. `smoothedJitterMs` is
    /// excluded — it moves constantly and would defeat the "only log when
    /// something happened" guard. Compares via `Equatable` with the
    /// non-counter field normalized, so a future counter can't be
    /// forgotten here.
    public func countersDiffer(from other: VoiceStats) -> Bool {
        var normalizedSelf = self
        var normalizedOther = other
        normalizedSelf.smoothedJitterMs = 0
        normalizedOther.smoothedJitterMs = 0
        return normalizedSelf != normalizedOther
    }
}

/// The pure decision layer of the voice *receive* path — the loss-resilience
/// rules extracted from the macOS app's `VoiceChannel` inbound pipeline, made
/// portable so the Linux and Windows voice paths (`VoiceDownlink`) can share
/// them and so Linux CI can pin them.
///
/// A namespace of pure `static func`s plus the Foundation-only value types
/// they decide over. Nothing here owns state, a clock, or a device: callers
/// (the mac `VoiceChannel` queue, the portable `VoiceDownlink`) thread their
/// own per-SSRC state and timestamps through.
public enum VoiceReceiveDecisions {
    /// One Opus frame's worth of samples at 48 kHz = 20 ms.
    public static let samplesPerFrame = OpusVoiceEncoder.frameSamples
    /// Samples faded at a concealment boundary to mask the MDCT
    /// overlap-add discontinuity click.
    public static let fadeSampleCount = 64
    /// Startup playback queue depth, in `samplesPerFrame` buffers.
    public static let initialJitterTargetDepth = 3
    /// Headroom above the adaptive target depth before a playback side drops
    /// an incoming buffer instead of scheduling it — the clock-drift
    /// backstop (see the macOS `MicCapture.scheduleSamples`). Lives here so
    /// the concealment cap (`concealmentEmitCount`) and the playback cap can
    /// never drift apart.
    public static let playbackSlackBuffers = 3
    /// Idle time after which a peer's receive state is evicted (10 s).
    /// A departed peer's frozen `smoothedJitterMs` would otherwise pin the
    /// jitter target high for the rest of the session.
    public static let receiveStateIdleNs: UInt64 = 10_000_000_000
    /// Live-path values for `decoderGateAction`'s cooldown/permanent knobs —
    /// also the function's defaults; kept as named constants so the gate
    /// and the failure logging agree on when we've given up.
    public static let decoderInitRetryCooldownNs: UInt64 = 5_000_000_000
    public static let decoderInitFailureLimit = 5

    /// Bookkeeping for one SSRC whose decoder failed to initialize.
    public struct DecoderFailureRecord: Equatable, Sendable {
        public var consecutiveInitFailures: Int
        public var lastFailureNs: UInt64

        public init(consecutiveInitFailures: Int, lastFailureNs: UInt64) {
            self.consecutiveInitFailures = consecutiveInitFailures
            self.lastFailureNs = lastFailureNs
        }
    }

    /// Verdict of `decoderGateAction(record:nowNs:)` for one inbound packet.
    public enum DecoderGateAction: Equatable {
        case allow
        case drop
    }

    /// Verdict of `gapAction(lastSeq:newSeq:maxConcealFrames:)`.
    public enum GapAction: Equatable {
        /// In order — decode normally.
        case decode
        /// Duplicate or reordered-late packet — do not decode (the gap it
        /// once left has already been concealed or resynced past).
        case dropStale
        /// Small forward gap — emit `missing` silence frames, then decode.
        case concealThenDecode(missing: Int)
        /// Gap too large to fill — resync the sequence clock, count it,
        /// and decode without concealment.
        case discontinuity
    }

    /// Per-SSRC inbound bookkeeping. Confinement is the caller's job (the mac
    /// `VoiceChannel` keeps these on its queue; `VoiceDownlink` on its host's
    /// serial receive loop).
    public struct ReceiveState {
        public var lastSequence: UInt16
        public var lastArrivalNs: UInt64
        public var lastRTPTimestamp: UInt32
        /// RFC 3550 smoothed inter-arrival jitter, in ms.
        public var smoothedJitterMs = 0.0
        /// Very last emitted sample — the leading edge of a concealment
        /// gap ramps from here down to zero so the boundary has no step.
        public var lastEmittedSample: Float = 0
        /// Fade in the next decoded frame (set after conceal/resync).
        public var needsFadeIn = false

        public init(lastSequence: UInt16, lastArrivalNs: UInt64, lastRTPTimestamp: UInt32) {
            self.lastSequence = lastSequence
            self.lastArrivalNs = lastArrivalNs
            self.lastRTPTimestamp = lastRTPTimestamp
        }
    }

    /// Where an inbound audio packet's payload type routes.
    public enum AudioRoute: Equatable {
        /// PT 98 — voice; the full jitter/concealment pipeline + the mixed
        /// voice output.
        case voice
        /// PT 99 — shared system audio; decode-and-emit via the dedicated
        /// system-audio output.
        case systemAudio
        /// Anything else (e.g. a stray video PT) — ignore.
        case drop
    }

    /// Pure payload-type → route decision. Extracted so CI can pin the demux
    /// without building packets.
    public static func audioRoute(payloadType: UInt8) -> AudioRoute {
        switch payloadType {
        case RTPHeader.voicePayloadType: return .voice
        case RTPHeader.systemAudioPayloadType: return .systemAudio
        default: return .drop
        }
    }

    /// Pure retry-with-cooldown gate decision. `nil` record → allow.
    /// After `permanentAfter` consecutive init failures → drop for the
    /// session (matches the old permanent-block behavior after ~25 s of
    /// trying). Otherwise drop until `cooldownNs` has elapsed since the last
    /// failure, then allow one retry — a failure re-arms the cooldown, so
    /// failure logging stays ≤ 1 line per cooldown window.
    public static func decoderGateAction(
        record: DecoderFailureRecord?,
        nowNs: UInt64,
        cooldownNs: UInt64 = VoiceReceiveDecisions.decoderInitRetryCooldownNs,
        permanentAfter: Int = VoiceReceiveDecisions.decoderInitFailureLimit
    ) -> DecoderGateAction {
        guard let record else { return .allow }
        guard record.consecutiveInitFailures < permanentAfter else { return .drop }
        return nowNs &- record.lastFailureNs > cooldownNs ? .allow : .drop
    }

    /// Pure wrap-aware sequence-gap decision, via `UInt16` two's-complement
    /// delta against the expected next sequence number. Delta 0 → in order;
    /// behind half-space (duplicate or reordered-late) → drop stale; a
    /// forward gap of `1...maxConcealFrames` → conceal then decode; larger →
    /// discontinuity (resync, no fill). First packet per SSRC (`lastSeq ==
    /// nil`) always decodes — priming's short/empty decoder output never
    /// enters the gap math because gaps are keyed on sequence numbers.
    public static func gapAction(lastSeq: UInt16?, newSeq: UInt16, maxConcealFrames: Int = 5) -> GapAction {
        guard let lastSeq else { return .decode }
        let delta = newSeq &- (lastSeq &+ 1)
        if delta == 0 { return .decode }
        if delta > 0x8000 { return .dropStale }
        if Int(delta) <= maxConcealFrames { return .concealThenDecode(missing: Int(delta)) }
        return .discontinuity
    }

    /// Pure jitter-buffer sizing: target queue depth in 20 ms buffers.
    /// One buffer of slack per frame-duration of smoothed jitter, +1 base;
    /// clamped to `[minDepth, maxDepth]`; moves at most one step per call
    /// (bounded growth, no oscillation — equal ideal holds steady).
    public static func jitterBufferTarget(
        smoothedJitterMs: Double,
        currentTarget: Int,
        minDepth: Int = 2,
        maxDepth: Int = 12
    ) -> Int {
        let frameMs = Double(VoiceReceiveDecisions.samplesPerFrame) / 48.0
        let slack = Int((max(0, smoothedJitterMs) / frameMs).rounded(.up))
        let ideal = min(max(1 + slack, minDepth), maxDepth)
        if ideal > currentTarget { return min(currentTarget + 1, maxDepth) }
        if ideal < currentTarget { return max(currentTarget - 1, minDepth) }
        return currentTarget
    }

    /// Pure clamp-log throttle: log at the first crossing of `threshold`
    /// and then once every `every` clamped buffers, so a persistent
    /// clipping regression stays visible without 50 Hz spam.
    public static func shouldLogClamp(count: Int, threshold: Int = 50, every: Int = 1000) -> Bool {
        if count == threshold { return true }
        return count > threshold && count % every == 0
    }

    /// Single-pass clamp of decoded PCM to [-1, 1]. Returns whether any
    /// sample was out of range. Opus decodes to Int16, so `int16ToFloat`
    /// output is already within [-1, 1] but for the lone -32768 → -1.00003
    /// case; the clamp stays as cheap defense-in-depth (it was load-bearing
    /// under the old AudioToolbox AAC decoder, which emitted peaks ~6.0), so
    /// nothing beyond [-1, 1] can ever clip the speakers into painful clicks.
    public static func clampToUnitRange(_ samples: inout [Float]) -> Bool {
        var clamped = false
        for i in samples.indices where samples[i] < -1.0 || samples[i] > 1.0 {
            samples[i] = max(-1.0, min(1.0, samples[i]))
            clamped = true
        }
        return clamped
    }

    /// Pure eviction decision: SSRCs whose last packet arrived more than
    /// `idleNs` ago (strictly). The receive side evicts these so a
    /// departed peer's frozen `smoothedJitterMs` can't pin the jitter
    /// target high for the rest of the session; a returning peer starts
    /// fresh. Arrivals stamped ahead of `nowNs` (clock skew) are never
    /// stale. Sorted for determinism.
    public static func staleSSRCs(
        lastArrivalsNs: [UInt32: UInt64],
        nowNs: UInt64,
        idleNs: UInt64 = VoiceReceiveDecisions.receiveStateIdleNs
    ) -> [UInt32] {
        lastArrivalsNs
            .compactMap { ssrc, lastNs in nowNs > lastNs && nowNs - lastNs > idleNs ? ssrc : nil }
            .sorted()
    }

    /// Pure concealment-emission cap: at most `slackBuffers - 1` silence
    /// frames per gap. The playback queue caps at `targetDepth +
    /// playbackSlackBuffers`; reserving one slot of that slack guarantees
    /// the silence fill alone can never push the gap's next *real* decoded
    /// frame into an overrun drop. (Live headroom isn't readable from the
    /// receive side — the pending count lives with the playback backend —
    /// so this is the conservative static form.)
    public static func concealmentEmitCount(
        missing: Int, slackBuffers: Int = VoiceReceiveDecisions.playbackSlackBuffers
    ) -> Int {
        min(max(missing, 0), max(slackBuffers - 1, 0))
    }

    /// Pure first-concealment-frame synthesis: a linear ramp from the last
    /// emitted sample down to zero across `fadeSamples`, then silence.
    /// Ramping from the actual last sample — not a replay of the previous
    /// frame's tail, which would be an audible 63-samples-back step —
    /// keeps the gap boundary click-free.
    public static func concealmentFadeOut(
        from lastSample: Float,
        frameSamples: Int = VoiceReceiveDecisions.samplesPerFrame,
        fadeSamples: Int = VoiceReceiveDecisions.fadeSampleCount
    ) -> [Float] {
        var frame = [Float](repeating: 0, count: frameSamples)
        let span = min(fadeSamples, frameSamples)
        guard lastSample != 0, span > 0 else { return frame }
        for i in 0..<span {
            frame[i] = lastSample * (1.0 - Float(i + 1) / Float(span))
        }
        return frame
    }

    /// Pure underrun verdict: a drain-to-zero is an audible underrun only
    /// when new audio arrives within `resumeWindowNs` of it — the
    /// starve-then-resume pattern. A drain followed by a long silence is
    /// benign (mute, end of stream, teardown) and must not count.
    /// `drainedAtNs == 0` means no drain is pending.
    public static func isStarveResume(
        drainedAtNs: UInt64, nowNs: UInt64, resumeWindowNs: UInt64 = 1_000_000_000
    ) -> Bool {
        drainedAtNs != 0 && nowNs &- drainedAtNs < resumeWindowNs
    }

    /// Pure pause detector for the jitter estimator. A send-side mute
    /// keeps sequence numbers contiguous but stops the packets, so the
    /// resume packet shows an arrival-vs-RTP deviation of the whole pause
    /// length; folding that into RFC 3550's `J += (|D| - J) / 16` would
    /// pin the jitter target at max for the better part of a minute.
    /// Deviations past `thresholdMs` skip the fold and just resync the
    /// arrival/RTP baseline.
    public static func isPauseDeviation(deviationMs: Double, thresholdMs: Double = 500) -> Bool {
        deviationMs > thresholdMs
    }
}
