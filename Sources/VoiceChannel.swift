import AVFoundation
import CoreAudio
import Foundation
import TailscaleKit
import os

/// Cumulative voice-path resilience counters. Published under a lock so the
/// MainActor playback side (`MicCapture`) and the VoiceChannel queue can both
/// write, and any thread can snapshot via `VoiceChannel.currentStats`.
struct VoiceStats: Equatable, Sendable {
    /// Inbound buffers dropped because the playback queue was at its cap.
    var overrunDrops = 0
    /// Times the playback queue drained to zero while the player was
    /// running — the audible starve.
    var underruns = 0
    /// Silence frames emitted to cover sequence gaps.
    var concealedFrames = 0
    /// Gaps too large to conceal; we resync instead of filling.
    var discontinuities = 0
    /// Decoded buffers that contained at least one out-of-[-1, 1] sample.
    var clampedBuffers = 0
    /// RFC 3550 smoothed inter-arrival jitter of the worst SSRC, in ms.
    var smoothedJitterMs = 0.0

    /// True when any *counter* differs from `other`. `smoothedJitterMs` is
    /// excluded — it moves constantly and would defeat the "only log when
    /// something happened" guard. Compares via `Equatable` with the
    /// non-counter field normalized, so a future counter can't be
    /// forgotten here.
    func countersDiffer(from other: VoiceStats) -> Bool {
        var normalizedSelf = self
        var normalizedOther = other
        normalizedSelf.smoothedJitterMs = 0
        normalizedOther.smoothedJitterMs = 0
        return normalizedSelf != normalizedOther
    }
}

/// Process-side voice pipeline: PCM in → AAC enc → RTP out, and RTP in →
/// AAC dec (per SSRC) → mixed PCM out. Hardware capture/playback glue is
/// in `MicCapture` (added in Task 7) which feeds this class.
///
/// Thread-safe via an internal serial queue: capture callbacks (audio
/// thread) and network callbacks (TailscaleKit reader task) call into
/// public methods which dispatch onto the queue. State only mutates on
/// the queue.
///
/// Marked `@unchecked Sendable`: all stored mutable state (`_isMuted`,
/// `decoders`, `decoderFailures`, `receiveStates`, `lastTargetRefreshNs`,
/// `lastStatsLogNs`, `lastLoggedStats`) is touched only from `queue`.
/// `statsLock` and `jitterTargetDepth` are the cross-thread values —
/// lock-published because `MicCapture` reads/writes them from the
/// MainActor. `onMixedPCM` is the documented exception — set it once
/// before any `receive(_:)`.
final class VoiceChannel: @unchecked Sendable {
    let localSSRC: UInt32
    var isMuted: Bool {
        get { queue.sync { _isMuted } }
        set { queue.sync { _isMuted = newValue } }
    }

    /// Invoked on the internal queue every time the encoder produces an
    /// RTP packet. Caller should pass it to the network layer.
    private let onSend: (Data) -> Void

    /// Invoked on the internal queue when the decoder produces a block of
    /// PCM samples for one inbound RTP audio packet. One call per packet
    /// per remote SSRC — mixing across peers is the caller's job (the
    /// audio engine in `MicCapture` schedules them into a shared player).
    ///
    /// Set this once before the first `receive(_:)` call. Mutating it
    /// concurrently with packet ingestion is unsafe; the queue reads it
    /// without synchronization.
    var onMixedPCM: (([Float]) -> Void)?

    private let queue = DispatchQueue(label: "VoiceChannel")
    private var _isMuted: Bool = true
    private let encoder: AACEncoder
    private let packetizer: AudioRTPPacketizer
    private let depacketizer = AudioRTPDepacketizer()
    private var decoders: [UInt32: AACDecoder] = [:]
    private var decoderFailures: [UInt32: DecoderFailureRecord] = [:]
    private var receiveStates: [UInt32: ReceiveState] = [:]
    private var lastTargetRefreshNs: UInt64 = 0
    private var lastStatsLogNs: UInt64 = 0
    private var lastLoggedStats = VoiceStats()
    private let statsLock = OSAllocatedUnfairLock<VoiceStats>(initialState: VoiceStats())
    private let jitterTargetDepth = OSAllocatedUnfairLock<Int>(
        initialState: VoiceChannel.initialJitterTargetDepth)
    private let logger = TSLogger()

    /// One AAC AU's worth of samples at 48 kHz ≈ 21.33 ms.
    static let samplesPerFrame = 1024
    /// Samples faded at a concealment boundary to mask the MDCT
    /// overlap-add discontinuity click.
    static let fadeSampleCount = 64
    /// Startup playback queue depth, in `samplesPerFrame` buffers.
    static let initialJitterTargetDepth = 3
    /// Headroom above the adaptive target depth before `MicCapture` drops
    /// an incoming buffer instead of scheduling it — the clock-drift
    /// backstop (see `MicCapture.scheduleSamples`). Lives here so the
    /// concealment cap (`concealmentEmitCount`) and the playback cap can
    /// never drift apart.
    static let playbackSlackBuffers = 3
    /// Idle time after which a peer's receive state is evicted (10 s).
    /// A departed peer's frozen `smoothedJitterMs` would otherwise pin the
    /// jitter target high for the rest of the session.
    static let receiveStateIdleNs: UInt64 = 10_000_000_000
    /// Live-path values for `decoderGateAction`'s cooldown/permanent knobs —
    /// also the function's defaults; kept as named constants so the gate
    /// and the failure logging agree on when we've given up.
    static let decoderInitRetryCooldownNs: UInt64 = 5_000_000_000
    static let decoderInitFailureLimit = 5

    /// Bookkeeping for one SSRC whose decoder failed to initialize.
    struct DecoderFailureRecord: Equatable, Sendable {
        var consecutiveInitFailures: Int
        var lastFailureNs: UInt64
    }

    /// Verdict of `decoderGateAction(record:nowNs:)` for one inbound packet.
    enum DecoderGateAction: Equatable {
        case allow
        case drop
    }

    /// Verdict of `gapAction(lastSeq:newSeq:maxConcealFrames:)`.
    enum GapAction: Equatable {
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

    /// `GapAction` narrowed for `trackArrival`: `.dropStale` returns from
    /// `processInbound` before arrival tracking runs, so this type has no
    /// case for it — the compiler enforces the invariant.
    private enum ArrivalKind: Equatable {
        /// `GapAction.decode` — in order.
        case inOrder
        /// `GapAction.concealThenDecode` — gap filled, fade in the frame.
        case concealed
        /// `GapAction.discontinuity` — resync, skip the jitter fold.
        case discontinuity
    }

    /// Per-SSRC inbound bookkeeping. Queue-confined like `decoders`.
    private struct ReceiveState {
        var lastSequence: UInt16
        var lastArrivalNs: UInt64
        var lastRTPTimestamp: UInt32
        /// RFC 3550 smoothed inter-arrival jitter, in ms.
        var smoothedJitterMs = 0.0
        /// Very last emitted sample — the leading edge of a concealment
        /// gap ramps from here down to zero so the boundary has no step.
        var lastEmittedSample: Float = 0
        /// Fade in the next decoded frame (set after conceal/resync).
        var needsFadeIn = false
    }

    init(localSSRC: UInt32, onSend: @escaping (Data) -> Void) throws {
        self.localSSRC = localSSRC
        self.onSend = onSend
        self.encoder = try AACEncoder()
        self.packetizer = AudioRTPPacketizer(ssrc: localSSRC)
    }

    /// Push exactly 1024 PCM samples (one AAC AU's worth) for outbound
    /// transmission. No-op when muted.
    func processOutboundFrame(_ pcm: [Float]) {
        queue.async {
            guard !self._isMuted else { return }
            do {
                guard let au = try self.encoder.encode(pcm: pcm) else { return }
                let packet = self.packetizer.packetize(au: au)
                self.onSend(packet)
            } catch {
                self.logger.log("VoiceChannel: encode failed: \(error)")
            }
        }
    }

    /// Ingest one inbound RTP audio packet. Decodes per SSRC and emits
    /// PCM via `onMixedPCM`, concealing small sequence gaps with
    /// fade-masked silence.
    func receive(_ packet: Data) {
        queue.async {
            self.processInbound(packet)
        }
    }

    /// Forget all per-SSRC decoders, failure records, sequence/jitter
    /// state, and counters. Called when the share session ends so a
    /// future session starts fresh.
    func reset() {
        queue.async {
            self.decoders.removeAll()
            self.decoderFailures.removeAll()
            self.receiveStates.removeAll()
            self.lastTargetRefreshNs = 0
            self.lastStatsLogNs = 0
            self.lastLoggedStats = VoiceStats()
            self.jitterTargetDepth.withLock { $0 = Self.initialJitterTargetDepth }
            self.statsLock.withLock { $0 = VoiceStats() }
        }
    }

    // MARK: - Cross-thread published values

    /// Playback queue depth (in 21.33 ms buffers) the jitter estimator
    /// currently recommends. Read by `MicCapture.scheduleSamples` on the
    /// MainActor; refreshed on `queue` — hence the lock.
    var currentJitterTargetDepth: Int {
        jitterTargetDepth.withLock { $0 }
    }

    /// Snapshot of the cumulative resilience counters. Safe from any thread.
    var currentStats: VoiceStats {
        statsLock.withLock { $0 }
    }

    /// Record a playback-side drop of an incoming buffer at the queue cap.
    /// Called from the MainActor (`MicCapture`).
    func noteOverrunDrop() {
        statsLock.withLock { $0.overrunDrops += 1 }
    }

    /// Record an audible playback starve (pending queue hit zero while
    /// the player was running, and audio resumed shortly after — see
    /// `isStarveResume`). Called from the MainActor (`MicCapture`).
    func noteUnderrun() {
        statsLock.withLock { $0.underruns += 1 }
    }

    // MARK: - Pure decision functions (CI-able test seams)

    /// Pure retry-with-cooldown gate decision. `nil` record → allow.
    /// After `permanentAfter` consecutive init failures → drop for the
    /// session (matches the old permanent-block behavior after ~25 s of
    /// trying). Otherwise drop until `cooldownNs` has elapsed since the last
    /// failure, then allow one retry — a failure re-arms the cooldown, so
    /// failure logging stays ≤ 1 line per cooldown window.
    static func decoderGateAction(
        record: DecoderFailureRecord?,
        nowNs: UInt64,
        cooldownNs: UInt64 = VoiceChannel.decoderInitRetryCooldownNs,
        permanentAfter: Int = VoiceChannel.decoderInitFailureLimit
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
    static func gapAction(lastSeq: UInt16?, newSeq: UInt16, maxConcealFrames: Int = 5) -> GapAction {
        guard let lastSeq else { return .decode }
        let delta = newSeq &- (lastSeq &+ 1)
        if delta == 0 { return .decode }
        if delta > 0x8000 { return .dropStale }
        if Int(delta) <= maxConcealFrames { return .concealThenDecode(missing: Int(delta)) }
        return .discontinuity
    }

    /// Pure jitter-buffer sizing: target queue depth in 21.33 ms buffers.
    /// One buffer of slack per frame-duration of smoothed jitter, +1 base;
    /// clamped to `[minDepth, maxDepth]`; moves at most one step per call
    /// (bounded growth, no oscillation — equal ideal holds steady).
    static func jitterBufferTarget(
        smoothedJitterMs: Double,
        currentTarget: Int,
        minDepth: Int = 2,
        maxDepth: Int = 12
    ) -> Int {
        let frameMs = 1024.0 / 48.0
        let slack = Int((max(0, smoothedJitterMs) / frameMs).rounded(.up))
        let ideal = min(max(1 + slack, minDepth), maxDepth)
        if ideal > currentTarget { return min(currentTarget + 1, maxDepth) }
        if ideal < currentTarget { return max(currentTarget - 1, minDepth) }
        return currentTarget
    }

    /// Pure clamp-log throttle: log at the first crossing of `threshold`
    /// and then once every `every` clamped buffers, so a persistent
    /// clipping regression stays visible without 50 Hz spam.
    static func shouldLogClamp(count: Int, threshold: Int = 50, every: Int = 1000) -> Bool {
        if count == threshold { return true }
        return count > threshold && count % every == 0
    }

    /// Single-pass clamp of decoded PCM to [-1, 1]. Returns whether any
    /// sample was out of range. The AudioToolbox AAC decoder occasionally
    /// emits out-of-range Float32 (peaks ~6.0 observed) on priming-adjacent
    /// frames or after a network glitch; anything beyond [-1, 1] would clip
    /// the speakers into painful clicks. Internal (not private) — test seam.
    static func clampToUnitRange(_ samples: inout [Float]) -> Bool {
        var clamped = false
        for i in samples.indices where samples[i] < -1.0 || samples[i] > 1.0 {
            samples[i] = max(-1.0, min(1.0, samples[i]))
            clamped = true
        }
        return clamped
    }

    /// Pure eviction decision: SSRCs whose last packet arrived more than
    /// `idleNs` ago (strictly). `refreshJitterTarget` evicts these so a
    /// departed peer's frozen `smoothedJitterMs` can't pin the jitter
    /// target high for the rest of the session; a returning peer starts
    /// fresh. Arrivals stamped ahead of `nowNs` (clock skew) are never
    /// stale. Sorted for determinism.
    static func staleSSRCs(
        lastArrivalsNs: [UInt32: UInt64],
        nowNs: UInt64,
        idleNs: UInt64 = VoiceChannel.receiveStateIdleNs
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
    /// channel queue — `pendingBuffers` is MainActor-confined in
    /// `MicCapture` — so this is the conservative static form.)
    static func concealmentEmitCount(
        missing: Int, slackBuffers: Int = VoiceChannel.playbackSlackBuffers
    ) -> Int {
        min(max(missing, 0), max(slackBuffers - 1, 0))
    }

    /// Pure first-concealment-frame synthesis: a linear ramp from the last
    /// emitted sample down to zero across `fadeSamples`, then silence.
    /// Ramping from the actual last sample — not a replay of the previous
    /// frame's tail, which would be an audible 63-samples-back step —
    /// keeps the gap boundary click-free.
    static func concealmentFadeOut(
        from lastSample: Float,
        frameSamples: Int = VoiceChannel.samplesPerFrame,
        fadeSamples: Int = VoiceChannel.fadeSampleCount
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
    static func isStarveResume(
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
    static func isPauseDeviation(deviationMs: Double, thresholdMs: Double = 500) -> Bool {
        deviationMs > thresholdMs
    }

    // MARK: - Inbound pipeline (queue-confined)

    private func processInbound(_ packet: Data) {
        guard let parsed = depacketizer.unpack(packet) else { return }
        // Drop our own loopback if the network somehow returned it.
        guard parsed.ssrc != localSSRC else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        // Single dictionary fetch per packet (50 Hz hot path): the helpers
        // thread `state` through and each exit path writes it back once.
        var state = receiveStates[parsed.ssrc]
        guard case .allow = Self.decoderGateAction(record: decoderFailures[parsed.ssrc], nowNs: now) else {
            // Gate-dropped packets still advance the sequence/timestamp
            // baseline (no jitter fold, no concealment, no decode) so the
            // first packet after the cooldown doesn't read as a spurious
            // gap — a needless discontinuity count and fade-in.
            Self.advanceBaseline(&state, parsed: parsed, arrivalNs: now)
            receiveStates[parsed.ssrc] = state
            return
        }

        let action = Self.gapAction(lastSeq: state?.lastSequence, newSeq: parsed.sequenceNumber)
        let kind: ArrivalKind
        switch action {
        case .dropStale:
            // Late arrival of a packet whose gap was already concealed —
            // decoding it now would play those 21 ms twice. State is
            // untouched, so nothing needs writing back.
            return
        case .decode:
            kind = .inOrder
        case .concealThenDecode(let missing):
            emitConcealment(
                frames: Self.concealmentEmitCount(missing: missing),
                lastSample: state?.lastEmittedSample ?? 0)
            kind = .concealed
        case .discontinuity:
            statsLock.withLock { $0.discontinuities += 1 }
            kind = .discontinuity
        }
        Self.trackArrival(&state, parsed: parsed, arrivalNs: now, kind: kind)
        decodeAndEmit(parsed, state: &state, nowNs: now)
        receiveStates[parsed.ssrc] = state
        refreshJitterTarget(nowNs: now)
        maybeLogStats(nowNs: now)
    }

    /// Advance the per-SSRC sequence/timestamp clocks and fold this
    /// packet into the RFC 3550 smoothed inter-arrival jitter:
    /// `J += (|D| - J) / 16`, where `D` compares the arrival-time delta
    /// against the RTP-timestamp delta (48 kHz units → ms). The fold is
    /// skipped on a discontinuity — a resync's huge timestamp jump isn't
    /// jitter — and on a pause-shaped deviation (send-side mute), which
    /// just resyncs the baseline instead of poisoning the estimator.
    private static func trackArrival(
        _ state: inout ReceiveState?,
        parsed: AudioRTPDepacketizer.Parsed,
        arrivalNs: UInt64,
        kind: ArrivalKind
    ) {
        guard var updated = state else {
            state = ReceiveState(
                lastSequence: parsed.sequenceNumber,
                lastArrivalNs: arrivalNs,
                lastRTPTimestamp: parsed.timestamp
            )
            return
        }
        switch kind {
        case .discontinuity:
            updated.needsFadeIn = true
        case .inOrder, .concealed:
            if kind == .concealed { updated.needsFadeIn = true }
            let rtpDeltaMs = Double(parsed.timestamp &- updated.lastRTPTimestamp) / 48.0
            let arrivalDeltaMs = Double(arrivalNs &- updated.lastArrivalNs) / 1_000_000.0
            let deviation = abs(arrivalDeltaMs - rtpDeltaMs)
            if !isPauseDeviation(deviationMs: deviation) {
                updated.smoothedJitterMs += (deviation - updated.smoothedJitterMs) / 16.0
            }
        }
        updated.lastSequence = parsed.sequenceNumber
        updated.lastRTPTimestamp = parsed.timestamp
        updated.lastArrivalNs = arrivalNs
        state = updated
    }

    /// Gate-drop path: advance the sequence/timestamp/arrival baseline
    /// without folding jitter, concealing, or decoding.
    private static func advanceBaseline(
        _ state: inout ReceiveState?,
        parsed: AudioRTPDepacketizer.Parsed,
        arrivalNs: UInt64
    ) {
        guard var updated = state else {
            state = ReceiveState(
                lastSequence: parsed.sequenceNumber,
                lastArrivalNs: arrivalNs,
                lastRTPTimestamp: parsed.timestamp
            )
            return
        }
        updated.lastSequence = parsed.sequenceNumber
        updated.lastRTPTimestamp = parsed.timestamp
        updated.lastArrivalNs = arrivalNs
        state = updated
    }

    /// Once a second, evict receive state for SSRCs that have gone idle
    /// (a departed peer's frozen jitter must not pin the target), then
    /// re-derive the target playback depth from the worst remaining
    /// per-SSRC smoothed jitter and publish it for `MicCapture`.
    private func refreshJitterTarget(nowNs: UInt64) {
        if lastTargetRefreshNs == 0 {
            lastTargetRefreshNs = nowNs
            return
        }
        guard nowNs &- lastTargetRefreshNs >= 1_000_000_000 else { return }
        lastTargetRefreshNs = nowNs
        let stale = Self.staleSSRCs(lastArrivalsNs: receiveStates.mapValues(\.lastArrivalNs), nowNs: nowNs)
        for ssrc in stale {
            receiveStates.removeValue(forKey: ssrc)
            decoders.removeValue(forKey: ssrc)
            decoderFailures.removeValue(forKey: ssrc)
            logger.log("VoiceChannel: evicted idle ssrc=\(ssrc) (no packets for 10 s); returning peers start fresh")
        }
        let worstJitterMs = receiveStates.values.map(\.smoothedJitterMs).max() ?? 0
        statsLock.withLock { $0.smoothedJitterMs = worstJitterMs }
        let (previous, next) = jitterTargetDepth.withLock { depth -> (Int, Int) in
            let old = depth
            depth = Self.jitterBufferTarget(smoothedJitterMs: worstJitterMs, currentTarget: old)
            return (old, depth)
        }
        guard next != previous else { return }
        logger.log(
            "VoiceChannel: jitter buffer target \(previous) → \(next) buffers "
                + "(smoothed jitter \(String(format: "%.1f", worstJitterMs)) ms)")
    }

    /// Emit `frames` frames of silence to cover a sequence gap, ramping
    /// the last emitted sample down to zero at the leading edge so the
    /// MDCT discontinuity doesn't land as a hard click. AudioToolbox
    /// exposes no codec-level concealment input, so the decoder is never
    /// fed anything for the lost AUs — only its next real one. `frames`
    /// arrives pre-capped by `concealmentEmitCount`, so this fill can
    /// never occupy the playback-queue headroom the gap's next real frame
    /// needs. `concealedFrames` counts only what is actually emitted.
    private func emitConcealment(frames: Int, lastSample: Float) {
        guard frames > 0, let emit = onMixedPCM else { return }
        statsLock.withLock { $0.concealedFrames += frames }
        for frameIndex in 0..<frames {
            if frameIndex == 0 {
                emit(Self.concealmentFadeOut(from: lastSample))
            } else {
                emit([Float](repeating: 0, count: Self.samplesPerFrame))
            }
        }
    }

    private func decodeAndEmit(
        _ parsed: AudioRTPDepacketizer.Parsed, state: inout ReceiveState?, nowNs: UInt64
    ) {
        do {
            let decoder = try ensureDecoder(for: parsed.ssrc)
            let raw = try decoder.decode(au: parsed.au)
            // Successful init + non-throwing decode: the SSRC is healthy,
            // forget any failure history.
            decoderFailures.removeValue(forKey: parsed.ssrc)
            guard !raw.isEmpty else { return }
            var samples = raw
            if Self.clampToUnitRange(&samples) {
                let count = statsLock.withLock { stats -> Int in
                    stats.clampedBuffers += 1
                    return stats.clampedBuffers
                }
                if Self.shouldLogClamp(count: count) {
                    logger.log(
                        "VoiceChannel: clamped \(count) out-of-range PCM buffers so far "
                            + "(latest ssrc=\(parsed.ssrc)) — possible codec regression")
                }
            }
            if var updated = state {
                if updated.needsFadeIn {
                    Self.applyFadeIn(&samples)
                    updated.needsFadeIn = false
                }
                if let last = samples.last { updated.lastEmittedSample = last }
                state = updated
            }
            onMixedPCM?(samples)
        } catch {
            recordDecodeFailure(for: parsed.ssrc, error: error, nowNs: nowNs)
        }
    }

    /// Failure bookkeeping. Init failures (no decoder cached yet) upsert
    /// the cooldown record — the gate then swallows packets until
    /// the cooldown elapses, so this logs at most once per window. Decode
    /// (not init) failures keep the decoder; transient corruption is normal.
    private func recordDecodeFailure(for ssrc: UInt32, error: Error, nowNs: UInt64) {
        guard decoders[ssrc] == nil else {
            logger.log("VoiceChannel: decode failed for ssrc=\(ssrc): \(error)")
            return
        }
        var record =
            decoderFailures[ssrc]
            ?? DecoderFailureRecord(consecutiveInitFailures: 0, lastFailureNs: 0)
        record.consecutiveInitFailures += 1
        record.lastFailureNs = nowNs
        decoderFailures[ssrc] = record
        if record.consecutiveInitFailures >= Self.decoderInitFailureLimit {
            logger.log(
                "VoiceChannel: decoder init failed for ssrc=\(ssrc) "
                    + "(attempt \(record.consecutiveInitFailures)): \(error). "
                    + "Giving up on this SSRC for the session.")
        } else {
            logger.log(
                "VoiceChannel: decoder init failed for ssrc=\(ssrc) "
                    + "(attempt \(record.consecutiveInitFailures)): \(error). "
                    + "Will retry after cooldown.")
        }
    }

    /// Ramp the first `fadeSampleCount` samples up from zero to mask the
    /// decode restart after a concealment gap or resync.
    private static func applyFadeIn(_ samples: inout [Float]) {
        let span = min(fadeSampleCount, samples.count)
        guard span > 0 else { return }
        for i in 0..<span {
            samples[i] *= Float(i + 1) / Float(span)
        }
    }

    /// Log the counters at most once a minute, and only when something
    /// actually moved since the previous line.
    private func maybeLogStats(nowNs: UInt64) {
        if lastStatsLogNs == 0 {
            lastStatsLogNs = nowNs
            return
        }
        guard nowNs &- lastStatsLogNs >= 60_000_000_000 else { return }
        lastStatsLogNs = nowNs
        let snapshot = statsLock.withLock { $0 }
        guard snapshot.countersDiffer(from: lastLoggedStats) else { return }
        lastLoggedStats = snapshot
        logger.log(
            "VoiceChannel: stats concealed=\(snapshot.concealedFrames) "
                + "discontinuities=\(snapshot.discontinuities) overruns=\(snapshot.overrunDrops) "
                + "underruns=\(snapshot.underruns) clamped=\(snapshot.clampedBuffers) "
                + "jitter=\(String(format: "%.1f", snapshot.smoothedJitterMs))ms")
    }

    private func ensureDecoder(for ssrc: UInt32) throws -> AACDecoder {
        if let existing = decoders[ssrc] { return existing }
        let new = try AACDecoder()
        decoders[ssrc] = new
        return new
    }

    #if DEBUG
    /// Drain the internal queue so test assertions can run synchronously
    /// after enqueuing outbound/inbound work.
    internal func flushForTesting() {
        queue.sync {}
    }

    /// Test-only: snapshot the per-SSRC decoder-failure records.
    internal var decoderFailuresForTesting: [UInt32: DecoderFailureRecord] {
        queue.sync { decoderFailures }
    }

    /// Test-only: inject a failure record so the cooldown/clear paths can
    /// be exercised without forcing a real `AACDecoder` init failure.
    internal func injectDecoderFailureForTesting(ssrc: UInt32, record: DecoderFailureRecord) {
        queue.sync { decoderFailures[ssrc] = record }
    }
    #endif
}

/// AVAudioEngine glue: input from VoiceProcessingIO mic (with built-in
/// AEC), output through the same VPIO unit (so AEC has the right
/// reference signal). Feeds inbound PCM frames into the VoiceChannel
/// and renders outbound PCM blocks the channel decoded from RTP.
/// Drains the AVAudioEngine input tap on the audio render thread and feeds
/// 1024-sample frames into the VoiceChannel. Lives outside `@MainActor`
/// because installTap fires on AVAudioEngine's serialized real-time queue;
/// hopping every callback to `@MainActor` (a) drops Swift 6 isolation
/// assertions, and (b) introduces unacceptable latency at 50 Hz.
///
/// All state is touched only from the tap callback, which AVAudioEngine
/// serializes — `@unchecked Sendable` is sound under that contract.
private final class TapBuffer: @unchecked Sendable {
    private let channel: VoiceChannel
    private var accumulator: [Float] = []
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private var sourceSampleRate: Double = 0
    private var lastSourceFormat: AVAudioFormat?
    private let logger = TSLogger()

    var usesConverter: Bool { converter != nil }

    init?(channel: VoiceChannel) {
        self.channel = channel
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        else { return nil }
        self.targetFormat = target
    }

    /// Lazily (re)build the converter when the buffer's actual format
    /// differs from what we last saw. Required because
    /// `AVAudioInputNode.outputFormat(forBus:)` lies on macOS+VPIO until
    /// the first buffer renders — we install the tap with `format: nil`
    /// and discover the real format only when buffers start arriving.
    ///
    /// We always pre-extract channel 0 to mono before any sample-rate
    /// conversion. With VPIO, the input bus presents `[mic, ref_L,
    /// ref_R]`-style multi-channel layouts; AVAudioConverter's default
    /// 3ch→1ch downmix sums all channels (peak hits ~6.0 = clipped).
    /// Picking channel 0 explicitly gives clean mic audio.
    private func ensureConverter(for sourceFormat: AVAudioFormat) -> Bool {
        if let last = lastSourceFormat,
            last.sampleRate == sourceFormat.sampleRate,
            last.channelCount == sourceFormat.channelCount,
            last.commonFormat == sourceFormat.commonFormat
        {
            return true
        }
        lastSourceFormat = sourceFormat
        sourceSampleRate = sourceFormat.sampleRate

        // After mono extraction the pre-converter format is 1-channel
        // at the source's sample rate. If that already matches the
        // target (48 kHz mono Float32), no AVAudioConverter is needed.
        if sourceFormat.sampleRate == 48_000
            && sourceFormat.commonFormat == .pcmFormatFloat32
        {
            converter = nil
            logger.log("MicCapture: tap delivering \(sourceFormat) — using channel 0, no resample needed.")
            return true
        }
        guard
            let monoSource = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceFormat.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let conv = AVAudioConverter(from: monoSource, to: targetFormat)
        else {
            logger.log("MicCapture: AVAudioConverter init failed for \(sourceFormat.sampleRate) → 48 kHz mono")
            converter = nil
            return false
        }
        converter = conv
        logger.log(
            "MicCapture: tap delivering \(sourceFormat) — picking channel 0, resampling \(sourceFormat.sampleRate) → 48 kHz."
        )
        return true
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard ensureConverter(for: buffer.format) else { return }

        // Always extract just channel 0 (mic with VPIO; for raw input
        // it's the only channel that matters anyway). Build a fresh
        // mono PCMBuffer so AVAudioConverter sees a 1-channel stream
        // and never has to decide how to downmix.
        guard let srcCd = buffer.floatChannelData?[0] else { return }
        let frameLen = Int(buffer.frameLength)
        guard frameLen > 0 else { return }

        // Fast path: input already 48 kHz Float32 — channel 0 is the
        // final mono audio, no conversion needed.
        if converter == nil {
            let samples = Array(UnsafeBufferPointer(start: srcCd, count: frameLen))
            appendAndDrain(samples)
            return
        }

        guard let converter = converter,
            let monoFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.format.sampleRate,
                channels: 1,
                interleaved: false
            ),
            let monoBuf = AVAudioPCMBuffer(
                pcmFormat: monoFmt,
                frameCapacity: AVAudioFrameCount(frameLen)
            ),
            let monoCd = monoBuf.floatChannelData?[0]
        else { return }
        monoBuf.frameLength = AVAudioFrameCount(frameLen)
        memcpy(monoCd, srcCd, frameLen * MemoryLayout<Float>.size)

        // Output capacity: input frames scaled by sample-rate ratio + slack
        // for converter buffering.
        let ratio = 48_000.0 / sourceSampleRate
        let outCap = AVAudioFrameCount(Double(frameLen) * ratio + 64)
        guard outCap > 0,
            let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap)
        else { return }

        final class OneShot: @unchecked Sendable {
            var done = false
            var buffer: AVAudioPCMBuffer?
        }
        let flag = OneShot()
        flag.buffer = monoBuf
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { [flag] _, statusOut in
            if flag.done {
                // `.noDataNow`, NOT `.endOfStream`. AVAudioConverter
                // latches endOfStream and permanently refuses input
                // after seeing it once — making this a one-shot
                // converter when we want a streaming one.
                statusOut.pointee = .noDataNow
                return nil
            }
            flag.done = true
            statusOut.pointee = .haveData
            return flag.buffer
        }
        let status = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
        if status == .error {
            logger.log("MicCapture: AVAudioConverter convert failed: \(error?.localizedDescription ?? "unknown")")
            return
        }
        guard let cd = outBuf.floatChannelData?[0] else { return }
        let frameCount = Int(outBuf.frameLength)
        guard frameCount > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: cd, count: frameCount))
        appendAndDrain(samples)
    }

    private func appendAndDrain(_ samples: [Float]) {
        accumulator.append(contentsOf: samples)
        while accumulator.count >= 1024 {
            let frame = Array(accumulator.prefix(1024))
            accumulator.removeFirst(1024)
            channel.processOutboundFrame(frame)
        }
    }
}

@MainActor
final class MicCapture {
    private let channel: VoiceChannel
    private let engine = AVAudioEngine()
    private var playerNodes: [AVAudioPlayerNode] = []
    private let mixer: AVAudioMixerNode
    private let outputFormat: AVAudioFormat
    private var tapBuffer: TapBuffer?
    private var isPlaying = false
    private(set) var isCapturing = false
    private var configChangeObserver: NSObjectProtocol?

    /// Silent sink that pulls the input node continuously. AVAudioEngine
    /// only renders an input node when something downstream is pulling
    /// from it (the output device, ultimately) — installing a tap alone
    /// is *not* enough on macOS, the tap is a passive observer. Without
    /// this connection, the engine pulls input exactly once during
    /// start-up and then idles, which surfaces as "exactly one tap
    /// buffer, then silence". `outputVolume = 0` keeps the user from
    /// hearing their own voice through the speakers.
    private let inputSinkMixer = AVAudioMixerNode()
    private var inputSinkConnected = false

    /// When `TAILSCREEN_VOICE_TEST_TONE=1`, capture skips the mic
    /// entirely and feeds a generated 440 Hz sine into the encoder.
    /// Lets us isolate codec/transport/playback bugs from
    /// AEC/feedback issues when running two instances on one Mac.
    private var testToneTimer: DispatchSourceTimer?
    private static var isTestToneEnabled: Bool {
        ProcessInfo.processInfo.environment["TAILSCREEN_VOICE_TEST_TONE"] == "1"
    }

    /// Optional per-engine device override. `nil` means "follow the
    /// system default" — AVAudioEngine's default behavior. Set via
    /// `setInputDevice` / `setOutputDevice`; applied at engine start
    /// time, so changes only take effect after the next
    /// engine.stop()/start() cycle (handled by the toggle paths and
    /// the `setDevice` methods themselves).
    private var inputDeviceID: AudioDeviceID?
    private var outputDeviceID: AudioDeviceID?

    private let logger = TSLogger()

    /// Apply a new input device. If capture is currently running, we
    /// tear it down and restart so the new device takes effect (the
    /// underlying I/O unit only honors the device override at start
    /// time). Pass `nil` to revert to the system default.
    func setInputDevice(_ deviceID: AudioDeviceID?) async {
        inputDeviceID = deviceID
        if isCapturing {
            disableCapture()
            try? await enableCapture()
        }
    }

    /// Apply a new output device. Restarts the playback engine if it
    /// was running so the new device takes effect.
    func setOutputDevice(_ deviceID: AudioDeviceID?) {
        outputDeviceID = deviceID
        guard isPlaying else { return }
        engine.stop()
        for player in playerNodes { player.stop() }
        applyOutputDevice()
        do {
            try engine.start()
        } catch {
            logger.log("MicCapture: failed to restart engine after output device change: \(error)")
        }
    }

    /// Push the configured device IDs down to the AudioUnits sitting
    /// underneath `engine.inputNode` / `engine.outputNode`. Called
    /// every time we (re)start the engine. Engine must be stopped at
    /// the call site — `kAudioOutputUnitProperty_CurrentDevice` is
    /// only honored when the unit isn't running.
    private func applyInputDevice() {
        guard let id = inputDeviceID else { return }
        if let unit = engine.inputNode.audioUnit {
            let status = AudioDevices.bind(deviceID: id, to: unit)
            if status != noErr {
                logger.log("MicCapture: failed to bind input device \(id): OSStatus=\(status)")
            }
        }
    }

    private func applyOutputDevice() {
        guard let id = outputDeviceID else { return }
        if let unit = engine.outputNode.audioUnit {
            let status = AudioDevices.bind(deviceID: id, to: unit)
            if status != noErr {
                logger.log("MicCapture: failed to bind output device \(id): OSStatus=\(status)")
            }
        }
    }

    init(channel: VoiceChannel) {
        self.channel = channel
        self.mixer = engine.mainMixerNode
        // 48 kHz mono Float32 — matches the codec format.
        guard
            let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        else {
            preconditionFailure("AVAudioFormat init failed for 48kHz mono Float32")
        }
        self.outputFormat = fmt

        // Pipe decoded PCM (per-SSRC mix already done by VoiceChannel)
        // into a player node so the user hears it.
        channel.onMixedPCM = { [weak self] samples in
            Task { @MainActor [weak self] in self?.scheduleSamples(samples) }
        }

        // AVAudioEngine reconfigures itself on route/format change (mic
        // hot-plug, sample-rate negotiation when VPIO engages, default-
        // device flip). Reconfigure tears down node connections, so an
        // installed input tap stops firing — observed as "exactly one
        // packet, then silence". Reinstall the tap whenever this fires.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reinstallTapAfterConfigChange() }
        }
    }

    /// Start the playback half of the engine. Builds the player → mixer →
    /// output graph and starts the engine without touching the input node,
    /// so listening works without prompting for microphone permission.
    func startPlayback() throws {
        guard !isPlaying else { return }
        // New playback session: the warmup counter and pending count are
        // per-session ("since last startPlayback()"), and bumping the
        // generation orphans any scheduleBuffer completion still in
        // flight from a previous session — a stale completion must not
        // drive `pendingBuffers` negative or record a bogus drain.
        playbackGeneration += 1
        scheduledCount = 0
        pendingBuffers = 0
        drainedAtNs = 0
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: mixer, format: outputFormat)
        playerNodes.append(player)
        applyOutputDevice()
        try engine.start()
        // Don't call player.play() yet. scheduleSamples kicks
        // playback off only after the channel's adaptive target
        // depth is queued, so the player has runway and doesn't
        // underrun on the first arrival hiccup.
        isPlaying = true
        logger.log("MicCapture: playback engine started (output-only, no mic, awaiting jitter buffer).")
    }

    /// Enable microphone capture. Requests permission, restarts the engine
    /// with VoiceProcessingIO enabled (for hardware AEC), and installs the
    /// input tap. Throws if permission is denied or the engine reconfigure
    /// fails.
    func enableCapture() async throws {
        guard !isCapturing else { return }

        // Test-tone bypass: skip the mic entirely, feed a 440 Hz
        // sine wave into VoiceChannel at the AAC frame cadence
        // (1024 samples / 48 kHz ≈ 21.33 ms). Useful for testing
        // codec + transport + playback in isolation without AEC
        // contention from running two instances on one Mac.
        if Self.isTestToneEnabled {
            startTestTone()
            isCapturing = true
            logger.log("MicCapture: capture started in TEST-TONE mode (440 Hz sine, no mic).")
            return
        }

        let granted = await Self.requestMicPermission()
        guard granted else {
            throw NSError(
                domain: "Tailscreen.VoiceChannel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]
            )
        }

        // setVoiceProcessingEnabled requires the engine to be stopped.
        if isPlaying { engine.stop() }
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
        } catch {
            // Don't swallow: without VPIO the input is whatever raw
            // hardware format AVAudioEngine picks (e.g. 5ch 44.1kHz from
            // an aggregate device), AEC is off, and the resulting tap
            // often fires once before the engine renegotiates.
            logger.log("MicCapture: VPIO not engaged: \(error). Continuing without AEC.")
        }

        logger.log("MicCapture: default input device = \(Self.defaultInputDeviceName() ?? "<unknown>")")

        guard let buffer = TapBuffer(channel: channel) else {
            throw NSError(
                domain: "Tailscreen.VoiceChannel",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate TapBuffer target format"]
            )
        }
        self.tapBuffer = buffer

        // Wire the input node into the active processing graph so the
        // engine pulls it every render cycle. See `inputSinkMixer`
        // doc-comment — the tap alone doesn't drive rendering on macOS.
        if !inputSinkConnected {
            engine.attach(inputSinkMixer)
            inputSinkMixer.outputVolume = 0
            engine.connect(engine.inputNode, to: inputSinkMixer, format: nil)
            engine.connect(inputSinkMixer, to: mixer, format: outputFormat)
            inputSinkConnected = true
        }

        // Install the tap BEFORE `engine.start()`, with `format: nil`.
        // `format: nil` lets AVAudioEngine deliver whatever format the
        // input actually produces; pre-start `outputFormat(forBus:)`
        // lies (returns the *output* device's stream description), so
        // we discover the real format lazily inside TapBuffer on the
        // first buffer.
        Self.installTap(on: engine.inputNode, buffer: buffer)

        applyInputDevice()
        applyOutputDevice()
        try engine.start()
        for player in playerNodes { player.play() }
        logger.log("MicCapture: capture started (engineRunning=\(engine.isRunning)).")

        isCapturing = true
    }

    /// Disable microphone capture. Removes the tap; engine stays running
    /// for playback.
    func disableCapture() {
        guard isCapturing else { return }
        if let t = testToneTimer {
            t.cancel()
            testToneTimer = nil
            isCapturing = false
            logger.log("MicCapture: test-tone capture disabled.")
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        tapBuffer = nil
        isCapturing = false
        logger.log("MicCapture: capture disabled.")
    }

    func stop() {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        if isCapturing {
            engine.inputNode.removeTap(onBus: 0)
            tapBuffer = nil
            isCapturing = false
        }
        if isPlaying {
            // Orphan in-flight scheduleBuffer completions (see
            // `playbackGeneration`) before tearing the players down.
            playbackGeneration += 1
            drainedAtNs = 0
            for node in playerNodes { node.stop() }
            engine.stop()
            playerNodes.removeAll()
            isPlaying = false
        }
    }

    /// Called from the AVAudioEngineConfigurationChange notification.
    /// Reconfigure tears down node connections, including the input tap,
    /// so capture goes dead after one buffer. Re-derive the input format
    /// (it may have changed — e.g. VPIO renegotiated to mono 24 kHz),
    /// rebuild the converter, reinstall the tap, and restart the engine.
    private func reinstallTapAfterConfigChange() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        guard let buffer = TapBuffer(channel: channel) else {
            logger.log("MicCapture: configuration change — TapBuffer alloc failed; capture stalled.")
            return
        }
        self.tapBuffer = buffer
        Self.installTap(on: engine.inputNode, buffer: buffer)
        if !engine.isRunning {
            do {
                try engine.start()
                for player in playerNodes { player.play() }
            } catch {
                logger.log("MicCapture: configuration change — engine restart failed: \(error)")
                return
            }
        }
        logger.log("MicCapture: tap reinstalled after configuration change.")
    }

    /// Mutable state for the test-tone timer. Lives outside
    /// `@MainActor` so the timer queue can mutate phase without
    /// hopping. `@unchecked Sendable` is sound because only the
    /// timer queue touches `phase`.
    private final class TestToneState: @unchecked Sendable {
        var phase: Float = 0
    }

    /// Generate a 440 Hz sine wave and push it into `channel` as
    /// 1024-sample frames at the AAC frame cadence. Each frame is
    /// `1024 / 48000` ≈ 21.33 ms; we run a serial DispatchSource
    /// timer at that interval. Phase accumulates across frames so
    /// the sine stays continuous (no clicks at frame boundaries).
    private func startTestTone() {
        // Build the timer in a nonisolated context. Otherwise the
        // closure passed to setEventHandler implicitly inherits
        // MicCapture's @MainActor isolation, and Swift 6's runtime
        // executor check trips `dispatch_assert_queue_fail` when the
        // timer queue dispatches a MainActor-isolated closure.
        testToneTimer = Self.makeTestToneTimer(channel: channel)
    }

    nonisolated private static func makeTestToneTimer(channel: VoiceChannel) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MicCapture.testTone"))
        let intervalNs = UInt64(1024.0 / 48_000.0 * 1_000_000_000)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNs)))
        let state = TestToneState()
        let handler: @Sendable () -> Void = {
            fillTestTone(state: state, channel: channel)
        }
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    nonisolated private static func fillTestTone(state: TestToneState, channel: VoiceChannel) {
        let twoPi = Float(2.0 * .pi)
        let freq: Float = 440
        let sampleRate: Float = 48_000
        let frameSize = 1024
        let amplitude: Float = 0.3
        var samples = [Float](repeating: 0, count: frameSize)
        var phase = state.phase
        let increment = twoPi * freq / sampleRate
        for i in 0..<frameSize {
            samples[i] = amplitude * sinf(phase)
            phase += increment
            if phase >= twoPi { phase -= twoPi }
        }
        state.phase = phase
        channel.processOutboundFrame(samples)
    }

    /// Look up the human-readable name of the system default input device
    /// via CoreAudio. Used purely for diagnostic logging — when capture
    /// goes one-and-done, the name often reveals a virtual loopback
    /// (BlackHole, Loopback, an aggregate) sitting where the user assumes
    /// the built-in mic is.
    nonisolated private static func defaultInputDeviceName() -> String? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }

        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = AudioObjectGetPropertyData(
            deviceID, &nameAddr, 0, nil, &nameSize, &name
        )
        guard nameStatus == noErr, let cfName = name?.takeRetainedValue() else { return nil }
        return cfName as String
    }

    /// Install the input tap from a nonisolated context so the closure
    /// AVAudioEngine retains does not inherit `@MainActor` isolation from
    /// `start()`. Without this, the audio render thread invoking the tap
    /// trips Swift 6's `dispatch_assert_queue` check (SIGTRAP) on the very
    /// first buffer.
    nonisolated private static func installTap(
        on inputNode: AVAudioInputNode,
        buffer: TapBuffer
    ) {
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil
        ) { avBuffer, _ in
            buffer.process(avBuffer)
        }
    }

    /// Counts scheduled buffers since last `startPlayback()`. Used by the
    /// jitter-buffer kick: we don't call `player.play()` until at least
    /// the channel's adaptive target depth has been queued ahead.
    private var scheduledCount: Int = 0

    /// Pending-buffer counter. AVAudioPlayerNode doesn't expose its
    /// queue depth, so we increment on schedule and decrement in the
    /// completion handler. Touched only on @MainActor.
    ///
    /// The headroom above the adaptive target depth before we drop the
    /// incoming buffer instead of scheduling it is
    /// `VoiceChannel.playbackSlackBuffers`. The sender's
    /// `DispatchSourceTimer` drifts a hair faster than the receiver's
    /// audio clock, so without a cap the queue grows unbounded → seconds
    /// of playback latency that you hear when muting (queue keeps
    /// draining after the sender stops). Dropping at the cap eats one
    /// frame (~21 ms) at most and keeps end-to-end latency bounded near
    /// `(targetDepth + slack) * 21 ms` — the clock-drift backstop.
    private var pendingBuffers: Int = 0

    /// Playback-session marker, bumped by `startPlayback()` and `stop()`.
    /// Every scheduleBuffer completion captures it and bails if a new
    /// session has started, so a completion Task racing a stop/start
    /// cycle can't corrupt `pendingBuffers` or `drainedAtNs`.
    private var playbackGeneration = 0

    /// Uptime when the pending queue last drained to zero while the
    /// player was running; 0 = no drain pending. Whether that drain was
    /// an audible underrun is decided on the next arrival — see
    /// `VoiceChannel.isStarveResume`.
    private var drainedAtNs: UInt64 = 0

    private func scheduleSamples(_ samples: [Float]) {
        guard isPlaying, let player = playerNodes.first else { return }
        // A past drain-to-zero counts as an underrun only if audio
        // resumes shortly after (starve-then-resume). A drain followed by
        // this long a silence was a benign stop (mute / end of stream).
        if drainedAtNs != 0 {
            let now = DispatchTime.now().uptimeNanoseconds
            if VoiceChannel.isStarveResume(drainedAtNs: drainedAtNs, nowNs: now) {
                channel.noteUnderrun()
            }
            drainedAtNs = 0
        }
        // Adaptive jitter-buffer depth: 21.33 ms buffers, sized by the
        // channel from RFC 3550 inter-arrival jitter (initially 3 ≈ 64 ms,
        // bounded at 12 ≈ 256 ms of added latency).
        let targetDepth = channel.currentJitterTargetDepth
        if pendingBuffers >= targetDepth + VoiceChannel.playbackSlackBuffers {
            channel.noteOverrunDrop()
            return
        }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = buffer.floatChannelData?[0] else { return }
        for (i, sample) in samples.enumerated() {
            dst[i] = sample
        }
        scheduledCount += 1
        pendingBuffers += 1
        let generation = playbackGeneration
        player.scheduleBuffer(buffer) { [weak self] in
            // Completion fires on AVAudioPlayer's render thread.
            // Hop to MainActor before mutating @MainActor state.
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.pendingBuffers -= 1
                // Queue drained while the player is still running —
                // possibly the audible starve; the next arrival decides.
                // Re-read the player from self rather than capturing the
                // non-Sendable node in this closure.
                if self.pendingBuffers == 0, self.playerNodes.first?.isPlaying == true {
                    self.drainedAtNs = DispatchTime.now().uptimeNanoseconds
                }
            }
        }
        // Defer the first play() until we have a small queue ahead.
        if !player.isPlaying && scheduledCount >= targetDepth {
            player.play()
        }
    }

    // `nonisolated` is load-bearing: `MicCapture` is `@MainActor`, so without
    // it the `requestAccess` completion closure inherits MainActor isolation.
    // TCC fires the callback on `com.apple.root.default-qos` and Swift 6's
    // executor assertion (`swift_task_isCurrentExecutorWithFlagsImpl`) trips
    // a `brk 1`. The body touches no MainActor state, so isolation is
    // unnecessary anyway.
    nonisolated private static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }
}

// MARK: - Logger

private struct TSLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[Voice] \(message)")
    }
}
