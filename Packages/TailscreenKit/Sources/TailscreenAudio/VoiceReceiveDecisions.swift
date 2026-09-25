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
    /// Decoded system-audio buffers with at least one out-of-[-1, 1] sample.
    /// Counted apart from `clampedBuffers` since the two clip for different
    /// reasons — this tells "sharer sent hot audio" from "voice path clipped".
    public var systemAudioClampedBuffers = 0
    /// RFC 3550 smoothed inter-arrival jitter of the worst SSRC, in ms.
    public var smoothedJitterMs = 0.0

    public init() {}

    /// True when any counter differs from `other`. `smoothedJitterMs` is
    /// excluded — it moves constantly and would defeat the "only log when
    /// something happened" guard.
    public func countersDiffer(from other: VoiceStats) -> Bool {
        var normalizedSelf = self
        var normalizedOther = other
        normalizedSelf.smoothedJitterMs = 0
        normalizedOther.smoothedJitterMs = 0
        return normalizedSelf != normalizedOther
    }
}

/// The pure decision layer of the voice *receive* path — loss-resilience
/// rules extracted from macOS's `VoiceChannel` inbound pipeline, portable so
/// Linux/Windows (`VoiceDownlink`) share them and CI can pin them. A
/// namespace of pure `static func`s; callers thread their own per-SSRC state
/// and timestamps through.
public enum VoiceReceiveDecisions {
    /// One Opus frame's worth of samples at 48 kHz = 20 ms.
    public static let samplesPerFrame = OpusVoiceEncoder.frameSamples
    /// Samples faded at a concealment boundary to mask the MDCT
    /// overlap-add discontinuity click.
    public static let fadeSampleCount = 64
    /// Startup playback queue depth, in `samplesPerFrame` buffers.
    public static let initialJitterTargetDepth = 3
    /// Headroom above the adaptive target depth before a playback side drops
    /// an incoming buffer instead of scheduling it (clock-drift backstop).
    /// Lives here so this and `concealmentEmitCount` can't drift apart.
    public static let playbackSlackBuffers = 3
    /// Idle time after which a peer's receive state is evicted (10 s) — a
    /// departed peer's frozen `smoothedJitterMs` would otherwise pin the
    /// jitter target high.
    public static let receiveStateIdleNs: UInt64 = 10_000_000_000
    /// `decoderGateAction`'s cooldown/permanent defaults, named so the gate
    /// and failure logging agree on when we've given up.
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

    /// Pure retry-with-cooldown gate decision. `nil` record → allow. After
    /// `permanentAfter` consecutive init failures → drop for the session;
    /// otherwise drop until `cooldownNs` has elapsed, then allow one retry.
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

    /// Pure wrap-aware sequence-gap decision via `UInt16` two's-complement
    /// delta. 0 → in order; behind half-space → drop stale; forward gap of
    /// `1...maxConcealFrames` → conceal then decode; larger → discontinuity.
    /// First packet per SSRC always decodes.
    public static func gapAction(lastSeq: UInt16?, newSeq: UInt16, maxConcealFrames: Int = 5) -> GapAction {
        guard let lastSeq else { return .decode }
        let delta = newSeq &- (lastSeq &+ 1)
        if delta == 0 { return .decode }
        if delta > 0x8000 { return .dropStale }
        if Int(delta) <= maxConcealFrames { return .concealThenDecode(missing: Int(delta)) }
        return .discontinuity
    }

    /// One frame's playout duration in nanoseconds — 20 ms at 48 kHz.
    public static let frameDurationNs = UInt64(samplesPerFrame) * 1_000_000_000 / 48_000

    /// How deep the playback queue would have had to be to keep every frame
    /// the network actually delivered.
    ///
    /// Exists because smoothed jitter cannot answer that question. RFC 3550
    /// jitter is a smoothed *mean* deviation, so it barely moves on the one
    /// arrival pattern that overflows a queue — a stall followed by a burst,
    /// where the burst's negative deviations cancel the stall's positive one.
    /// A 0.10.0-rc.16 bundle is the worked example: smoothed jitter sat
    /// between 32 and 39 ms for two minutes, which asks for a target of 3
    /// buffers and is exactly where the target stayed, while the path's round
    /// trip ranged from 1 ms to 756 ms and the receiver dropped 550 frames it
    /// had already been handed — 9 % of everything that arrived — and starved
    /// 327 times. Every counter that could have sized the buffer was calm; the
    /// queue was thrashing.
    ///
    /// So this measures the quantity directly, by modelling the same queue
    /// with no cap on it: playout consumes one frame per frame-duration while
    /// there is anything to consume, an arrival adds one, and the peak depth
    /// that model reaches is the room the burst actually needed. Feed it where
    /// frames are handed to the playback queue — *after* the mixer, since the
    /// mixer collapses one slot's several speakers into the single frame the
    /// queue receives, and counting raw arrivals would read two people talking
    /// as a burst.
    ///
    /// One honest limitation: this does not distinguish a burst from a sender
    /// whose clock simply runs fast. Both back the queue up, and the right
    /// answer differs — a burst wants a deeper buffer, drift wants the cap to
    /// bound the latency and drop the excess, which is what the cap was always
    /// for. Sizing on backlog lets the buffer follow drift up to `maxDepth`
    /// before dropping starts, so a persistently fast sender reaches more
    /// mouth-to-ear latency than it used to. Bounded either way, and slow at
    /// the rates that actually occur: at a realistic 0.1 % the climb to
    /// `maxDepth` takes minutes.
    public struct PlayoutBacklog: Equatable, Sendable {
        /// Ceiling on the modelled depth. Far above `jitterBufferTarget`'s
        /// own `maxDepth`, so it never truncates an answer that matters, but
        /// finite so a pathological clock cannot make the drain loop long.
        public static let depthCeiling = 64

        private var depth = 0
        private var peak = 0
        /// When the next frame is due out; nil before the first arrival and
        /// whenever the model has drained.
        private var playoutDueNs: UInt64?

        public init() {}

        /// The deepest the modelled queue has been since the last
        /// ``drainPeak()``.
        public var peakDepth: Int { peak }

        /// Record one frame handed to the playback queue.
        public mutating func noteFrameQueued(nowNs: UInt64) {
            if let due = playoutDueNs, depth > 0, nowNs >= due {
                // Consume whole frames' worth of elapsed playout. Bounded by
                // `depth`, which is bounded by `depthCeiling`.
                var next = due
                while depth > 0, next <= nowNs {
                    depth -= 1
                    next &+= VoiceReceiveDecisions.frameDurationNs
                }
                playoutDueNs = next
            }
            if depth == 0 {
                // Nothing to play means playout is not running: the clock
                // restarts from this frame rather than charging the silence
                // as consumption it never made. (This is the underrun, seen
                // from the model's side.)
                playoutDueNs = nowNs &+ VoiceReceiveDecisions.frameDurationNs
            }
            depth = min(depth + 1, Self.depthCeiling)
            peak = max(peak, depth)
        }

        /// Take the peak for the window that just closed and open the next.
        ///
        /// The new window starts at the depth still outstanding rather than
        /// at zero: a burst that is still draining when the window closes is
        /// a demand the next window inherits, and resetting to zero would
        /// under-report it exactly when it matters.
        public mutating func drainPeak() -> Int {
            let closing = peak
            peak = depth
            return closing
        }

        /// Forget everything — a new session, or a sharer switch.
        public mutating func reset() { self = PlayoutBacklog() }
    }

    /// Pure jitter-buffer sizing: target queue depth in 20 ms buffers.
    ///
    /// The target is the deeper of two readings. One buffer of slack per
    /// frame-duration of smoothed jitter (+1 base) is the steady-state
    /// answer; `burstDepth` — see ``PlayoutBacklog`` — is what the last
    /// window's worst burst actually demanded, and on a stalling path it is
    /// the larger of the two by a wide margin.
    ///
    /// **Growth is immediate, shrink is one step per call.** They are
    /// asymmetric on purpose. Climbing one step at a time from 3 to 12 takes
    /// nine calls, and on a ~1 Hz sweep that is nine more seconds of dropping
    /// audio already in hand — the cost of being too shallow is paid every
    /// frame, while the cost of being too deep is latency the next shrink
    /// gives back. Decay stays gradual so a single quiet window cannot
    /// collapse a buffer the path still needs, which is what would turn this
    /// into an oscillation.
    public static func jitterBufferTarget(
        smoothedJitterMs: Double,
        burstDepth: Int = 0,
        currentTarget: Int,
        minDepth: Int = 2,
        maxDepth: Int = 12
    ) -> Int {
        let frameMs = Double(VoiceReceiveDecisions.samplesPerFrame) / 48.0
        let slack = Int((max(0, smoothedJitterMs) / frameMs).rounded(.up))
        let wanted = max(1 + slack, burstDepth)
        let ideal = min(max(wanted, minDepth), maxDepth)
        if ideal > currentTarget { return ideal }
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
    /// sample was out of range. Opus's `int16ToFloat` output is already
    /// within range but for the lone -32768 → -1.00003 case; kept as cheap
    /// defense-in-depth.
    public static func clampToUnitRange(_ samples: inout [Float]) -> Bool {
        var clamped = false
        for i in samples.indices where samples[i] < -1.0 || samples[i] > 1.0 {
            samples[i] = max(-1.0, min(1.0, samples[i]))
            clamped = true
        }
        return clamped
    }

    /// Pure eviction decision: SSRCs whose last packet arrived more than
    /// `idleNs` ago, so a returning peer starts fresh rather than inheriting
    /// a frozen jitter target. Arrivals ahead of `nowNs` (clock skew) are
    /// never stale. Sorted for determinism.
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
    /// frames per gap, reserving one slot of playback slack so silence fill
    /// alone can never push the gap's next real frame into an overrun drop.
    public static func concealmentEmitCount(
        missing: Int, slackBuffers: Int = VoiceReceiveDecisions.playbackSlackBuffers
    ) -> Int {
        min(max(missing, 0), max(slackBuffers - 1, 0))
    }

    /// Pure first-concealment-frame synthesis: a linear ramp from the last
    /// emitted sample down to zero across `fadeSamples`, then silence —
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
    /// when new audio arrives within `resumeWindowNs` of it. A drain
    /// followed by long silence (mute, end of stream) doesn't count.
    /// `drainedAtNs == 0` means no drain is pending.
    public static func isStarveResume(
        drainedAtNs: UInt64, nowNs: UInt64, resumeWindowNs: UInt64 = 1_000_000_000
    ) -> Bool {
        drainedAtNs != 0 && nowNs &- drainedAtNs < resumeWindowNs
    }

    /// Pure pause detector for the jitter estimator. A send-side mute stops
    /// packets without breaking sequence numbers, so the resume packet's
    /// arrival-vs-RTP deviation spans the whole pause — folding that into
    /// RFC 3550's jitter formula would pin the target at max. Deviations past
    /// `thresholdMs` skip the fold and resync the baseline instead.
    public static func isPauseDeviation(deviationMs: Double, thresholdMs: Double = 500) -> Bool {
        deviationMs > thresholdMs
    }
}
