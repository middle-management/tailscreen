import Foundation
import TailscreenProtocol

/// The receiving half of the voice path: RTP in, 48 kHz mono PCM out, one
/// independent Opus decoder per SSRC.
///
/// The inverse of `VoiceUplink`, one type for both endpoints (a viewer
/// decodes the sharer's voice, system audio, and other viewers' relayed
/// voice; a sharer decodes its viewers'), so Linux/Windows sharers get the
/// same demux by construction instead of a second, drifting copy.
///
/// Loss-resilient, composing the same `VoiceReceiveDecisions` macOS's
/// `VoiceChannel` does:
///
/// - **Sequence gaps are concealed** (voice only): a small forward gap emits
///   up to `concealmentEmitCount` frames of Opus's native PLC, fading the
///   boundary so it doesn't click. Duplicates/reordered-late are dropped; a
///   gap too large to fill resyncs the sequence clock instead.
/// - **Decoder failures cool down** per `decoderInitRetryCooldownNs`
///   (permanently after `decoderInitFailureLimit`); gate-dropped packets
///   still advance the sequence baseline.
/// - **The jitter estimate adapts** via RFC 3550 smoothed inter-arrival
///   jitter, published as `currentJitterTargetDepth`.
/// - **Idle SSRCs are evicted** after `receiveStateIdleNs`.
///
/// System audio (PT 99) skips the gap/jitter machinery (queue-paced by the
/// host) but still gets decode + failure cooldown.
///
/// Emits **one mixed frame per 20 ms playout slot**, not one per SSRC — a
/// single playback queue plays frames in the order given, so per-SSRC
/// emission with two remote voices would interleave rather than sum them.
/// `VoiceMixer` sums same-slot frames; decoding/concealment/jitter/fades stay
/// per SSRC, only the emit is mixed.
///
/// Timing: every clock-needing decision reads the `nowNs` handed to `ingest`
/// — hosts with no threaded clock get the monotonic uptime clock instead.
///
/// **Thread-safe by lock**, not by contract: `ingest` runs on the host's
/// serial receive loop, but `reset()` runs from whatever thread tore the
/// share down while the server may still be delivering — a genuine data race
/// without the lock guarding all mutable state below.
public final class VoiceDownlink: @unchecked Sendable {
    /// Concurrent voices to keep decoders for — a bound, not a capacity
    /// guess: each SSRC allocates an Opus decoder and the SSRC is
    /// network-controlled, so an unbounded map is a remote allocation primitive.
    public static let maxConcurrentVoices = 32

    /// Decoded 48 kHz mono PCM, one frame per 20 ms playout slot, summed and
    /// clamped by `VoiceMixer`. A host queues each frame onto its one output as is.
    public var onMixedPCM: (([Float]) -> Void)? {
        get { lock.withLock { pcmSink } }
        set { lock.withLock { pcmSink = newValue } }
    }

    /// One buffer of decoded (or concealed) PCM, on its way to the mixer.
    /// Collected inside the critical section, delivered after it: holding the
    /// lock across `onMixedPCM` would park a share teardown behind an audio device.
    private typealias Emission = (ssrc: UInt32, samples: [Float])

    /// Guards every mutable field below (decoder pool, per-SSRC state,
    /// failure records, mixer, counters, `pcmSink`) against the host's
    /// receive thread and whichever thread runs `reset()`.
    private let lock = NSLock()
    private var pcmSink: (([Float]) -> Void)?

    private let depacketizer = AudioRTPDepacketizer()
    /// The per-slot sum every emission passes through on its way out.
    private var mixer = VoiceMixer()
    private var decoders: [UInt32: OpusVoiceDecoder] = [:]
    /// Ingest ordinal of each SSRC's last packet, for capacity eviction — a
    /// counter, not a clock, so eviction is deterministic even with no `nowNs`.
    private var lastSeen: [UInt32: UInt64] = [:]
    private var ingestCount: UInt64 = 0
    /// Per-SSRC sequence/jitter bookkeeping — voice streams only (system
    /// audio skips the gap machinery, exactly like the macOS pipeline).
    private var receiveStates: [UInt32: VoiceReceiveDecisions.ReceiveState] = [:]
    /// Per-SSRC decoder-init failure records, for the cooldown gate.
    private var decoderFailures: [UInt32: VoiceReceiveDecisions.DecoderFailureRecord] = [:]
    /// Adaptive playback-depth recommendation, refreshed by the ~1 Hz sweep.
    private var jitterTarget = VoiceReceiveDecisions.initialJitterTargetDepth
    /// Clock reading of the last stale-SSRC/jitter sweep (0 = no baseline yet).
    private var lastSweepNs: UInt64 = 0

    // Resilience counters. Internal so tests can see what was
    // concealed/resynced/clamped without asserting on audio.
    private var concealed = 0
    private var discontinuities = 0
    private var clampedBuffers = 0
    private var systemAudioClamped = 0
    /// Worst live stream's smoothed jitter as of the last sweep, in ms.
    private var worstJitterMs = 0.0

    var concealedFrameCount: Int { lock.withLock { concealed } }
    var discontinuityCount: Int { lock.withLock { discontinuities } }
    var clampedBufferCount: Int { lock.withLock { clampedBuffers } }

    // MARK: - `audio.summary`

    /// Cadence gate in front of `audio.summary` — the same window the
    /// transport rows use, so rows line up.
    private var summarySampler = DiagnosticsTransportSampler()
    /// Counters as of the previous row, so each carries deltas.
    private var lastSummaryStats = VoiceStats()
    /// Streams that actually delivered inside the open window — "delivered",
    /// not "has a decoder", so a stopped stream reads as 0 immediately.
    private var voiceSSRCsThisWindow: Set<UInt32> = []
    private var systemAudioThisWindow = false

    /// The counters this type owns. `overrunDrops`/`underruns` stay zero and
    /// are omitted — they belong to the playback queue, which this type
    /// doesn't own. See `VoiceStats.PlaybackContext.playbackQueueTracked`.
    private var statsSnapshot: VoiceStats {
        var stats = VoiceStats()
        stats.concealedFrames = concealed
        stats.discontinuities = discontinuities
        stats.clampedBuffers = clampedBuffers
        stats.systemAudioClampedBuffers = systemAudioClamped
        stats.smoothedJitterMs = worstJitterMs
        return stats
    }

    /// Close the window if due and return the row to record — empty when
    /// there is none (`audioSummaryFields` never produces empty). Called
    /// with the lock held; the caller records outside it.
    private func audioSummaryRowLocked(nowNs: UInt64) -> [String: DiagnosticValue] {
        guard let windowNs = summarySampler.windowClosed(nowNs: nowNs) else { return [:] }
        let context = VoiceStats.PlaybackContext(
            voiceStreams: voiceSSRCsThisWindow.count,
            systemAudioPlaying: systemAudioThisWindow,
            microphoneOn: false,
            jitterTargetDepth: jitterTarget,
            outputDevice: nil,
            playbackQueueTracked: false)
        voiceSSRCsThisWindow.removeAll(keepingCapacity: true)
        systemAudioThisWindow = false
        guard VoiceStats.shouldRecordSummary(context: context) else { return [:] }
        let snapshot = statsSnapshot
        let previous = lastSummaryStats
        lastSummaryStats = snapshot
        return snapshot.audioSummaryFields(
            since: previous, windowNs: windowNs, context: context)
    }

    public init() {}

    /// Playback queue depth (in 20 ms buffers) the jitter estimator currently
    /// recommends, moved one step per sweep. A host may ignore it.
    public var currentJitterTargetDepth: Int { lock.withLock { jitterTarget } }

    /// Feed one audio RTP datagram (PT 98 or 99). Anything else decodes to nil
    /// and is dropped.
    ///
    /// - Parameter nowNs: monotonic clock for this packet's arrival. Nil reads
    ///   the process's monotonic uptime clock.
    public func ingest(_ packet: Data, nowNs: UInt64? = nil) {
        let now = nowNs ?? Self.monotonicNowNs()
        let (sink, frames, summary) = lock.withLock {
            () -> ((([Float]) -> Void)?, [[Float]], [String: DiagnosticValue]) in
            guard let parsed = depacketizer.unpack(packet) else {
                return (nil, [], audioSummaryRowLocked(nowNs: now))
            }
            ingestCount &+= 1
            lastSeen[parsed.ssrc] = ingestCount

            var out: [Emission] = []
            switch VoiceReceiveDecisions.audioRoute(payloadType: parsed.payloadType) {
            case .drop:
                return (nil, [], [:])  // Unreachable — `unpack` admits only PT 98/99 — but total.
            case .systemAudio:
                systemAudioThisWindow = true
                ingestSystemAudio(parsed, nowNs: now, into: &out)
            case .voice:
                voiceSSRCsThisWindow.insert(parsed.ssrc)
                ingestVoice(parsed, nowNs: now, into: &out)
            }
            sweepIfDue(nowNs: now)
            // Per-SSRC output becomes per-slot output here, in decode order.
            let mixed = out.flatMap { mixer.add(ssrc: $0.ssrc, samples: $0.samples, nowNs: now) }
            // Taken under the lock, recorded outside it — the recorder takes
            // its own lock, and nesting the two is how a deadlock gets built.
            return (pcmSink, mixed, audioSummaryRowLocked(nowNs: now))
        }
        if !summary.isEmpty {
            DiagnosticsCenter.shared.recorder?.record(.audioSummary, fields: summary)
        }
        guard let sink else { return }
        for frame in frames { sink(frame) }
    }

    /// Drop every decoder and all resilience state — a new session, or a
    /// sharer switch. Safe against a concurrent `ingest`, which takes the
    /// same lock.
    public func reset() {
        lock.withLock {
            decoders.removeAll()
            lastSeen.removeAll()
            ingestCount = 0
            receiveStates.removeAll()
            decoderFailures.removeAll()
            mixer.reset()
            jitterTarget = VoiceReceiveDecisions.initialJitterTargetDepth
            lastSweepNs = 0
            concealed = 0
            discontinuities = 0
            clampedBuffers = 0
            systemAudioClamped = 0
            worstJitterMs = 0
            summarySampler.reset()
            lastSummaryStats = VoiceStats()
            voiceSSRCsThisWindow.removeAll()
            systemAudioThisWindow = false
        }
    }

    /// Live decoders. Exposed so a test can see the bound hold.
    public var voiceCount: Int { lock.withLock { decoders.count } }

    /// Whether this SSRC currently holds a decoder — lets a test see *which*
    /// stream eviction took, not just that the map stayed bounded.
    func hasVoice(_ ssrc: UInt32) -> Bool { lock.withLock { decoders[ssrc] != nil } }

    // MARK: - Voice path (gap concealment + jitter tracking)
    //
    // Everything from here to the sweep runs with `lock` HELD, and appends
    // what it wants played to the caller's `out` buffer rather than calling
    // `pcmSink` — see `Emission`. Nothing below may take the lock again:
    // `NSLock` is not recursive.

    private func ingestVoice(
        _ parsed: AudioRTPDepacketizer.Parsed, nowNs: UInt64, into out: inout [Emission]
    ) {
        // Single dictionary fetch per packet (50 Hz hot path), same shape as
        // the macOS pipeline: helpers thread `state` through and each exit
        // path writes it back once.
        var state = receiveStates[parsed.ssrc]
        guard
            case .allow = VoiceReceiveDecisions.decoderGateAction(
                record: decoderFailures[parsed.ssrc], nowNs: nowNs)
        else {
            // Gate-dropped packets still advance the sequence/timestamp
            // baseline (no jitter fold, no concealment, no decode) so the
            // first packet after the cooldown doesn't read as a spurious gap.
            Self.advanceBaseline(&state, parsed: parsed, arrivalNs: nowNs)
            receiveStates[parsed.ssrc] = state
            return
        }

        let action = VoiceReceiveDecisions.gapAction(
            lastSeq: state?.lastSequence, newSeq: parsed.sequenceNumber)
        var concealedShort = false
        var discontinuity = false
        switch action {
        case .dropStale:
            // Already-concealed gap; decoding now would play those 20 ms twice.
            return
        case .decode:
            break
        case .concealThenDecode(let missing):
            let emitted = emitConcealment(for: parsed.ssrc, missing: missing, into: &out)
            // A gap the cap didn't fully cover needs a fade back in; a fully covered one needs neither.
            concealedShort = emitted < missing
        case .discontinuity:
            discontinuities += 1
            discontinuity = true
        }
        Self.trackArrival(
            &state, parsed: parsed, arrivalNs: nowNs,
            needsFadeIn: concealedShort || discontinuity,
            skipJitterFold: discontinuity)
        decodeAndEmit(parsed, state: &state, nowNs: nowNs, into: &out)
        receiveStates[parsed.ssrc] = state
    }

    /// Decode one system-audio packet (PT 99, reserved SSRC 1) and emit — the
    /// decoder + failure-cooldown apply, but not voice jitter/concealment
    /// (playback is queue-paced by the host).
    private func ingestSystemAudio(
        _ parsed: AudioRTPDepacketizer.Parsed, nowNs: UInt64, into out: inout [Emission]
    ) {
        guard
            case .allow = VoiceReceiveDecisions.decoderGateAction(
                record: decoderFailures[parsed.ssrc], nowNs: nowNs)
        else { return }
        do {
            let decoder = try ensureDecoder(for: parsed.ssrc)
            var samples = try decoder.decode(au: parsed.au)
            decoderFailures.removeValue(forKey: parsed.ssrc)
            guard !samples.isEmpty else { return }
            if VoiceReceiveDecisions.clampToUnitRange(&samples) { systemAudioClamped += 1 }
            out.append((parsed.ssrc, samples))
        } catch {
            recordDecodeFailure(for: parsed.ssrc, nowNs: nowNs)
        }
    }

    /// Emit up to the capped number of concealment frames for a gap via
    /// Opus's native PLC, fading the last one to silence if the cap left part
    /// of the gap uncovered. Returns how many frames were emitted.
    private func emitConcealment(
        for ssrc: UInt32, missing: Int, into out: inout [Emission]
    ) -> Int {
        let frames = VoiceReceiveDecisions.concealmentEmitCount(missing: missing)
        guard frames > 0, pcmSink != nil, let decoder = decoders[ssrc] else { return 0 }
        var emitted = 0
        for index in 0..<frames {
            guard var frame = try? decoder.conceal(), !frame.isEmpty else { break }
            if index == frames - 1 && frames < missing {
                Self.fadeToSilence(&frame)
            }
            _ = VoiceReceiveDecisions.clampToUnitRange(&frame)
            concealed += 1
            emitted += 1
            out.append((ssrc, frame))
        }
        return emitted
    }

    private func decodeAndEmit(
        _ parsed: AudioRTPDepacketizer.Parsed,
        state: inout VoiceReceiveDecisions.ReceiveState?,
        nowNs: UInt64,
        into out: inout [Emission]
    ) {
        do {
            let decoder = try ensureDecoder(for: parsed.ssrc)
            var samples = try decoder.decode(au: parsed.au)
            // Healthy decode: forget any failure history.
            decoderFailures.removeValue(forKey: parsed.ssrc)
            guard !samples.isEmpty else { return }
            if VoiceReceiveDecisions.clampToUnitRange(&samples) { clampedBuffers += 1 }
            if var updated = state, updated.needsFadeIn {
                Self.applyFadeIn(&samples)
                updated.needsFadeIn = false
                state = updated
            }
            out.append((parsed.ssrc, samples))
        } catch {
            recordDecodeFailure(for: parsed.ssrc, nowNs: nowNs)
        }
    }

    /// Failure bookkeeping: init failures (no cached decoder) upsert the
    /// cooldown record; decode (not init) failures keep the decoder, since
    /// transient corruption is normal on a lossy link.
    private func recordDecodeFailure(for ssrc: UInt32, nowNs: UInt64) {
        guard decoders[ssrc] == nil else { return }
        var record =
            decoderFailures[ssrc]
            ?? VoiceReceiveDecisions.DecoderFailureRecord(
                consecutiveInitFailures: 0, lastFailureNs: 0)
        record.consecutiveInitFailures += 1
        record.lastFailureNs = nowNs
        decoderFailures[ssrc] = record
    }

    // MARK: - Arrival tracking (jitter fold)

    /// Advance the per-SSRC sequence/timestamp clocks and fold this packet
    /// into the RFC 3550 smoothed inter-arrival jitter. The fold is skipped
    /// on a discontinuity or pause-shaped deviation (send-side mute), which
    /// resync the baseline instead of poisoning the estimator.
    private static func trackArrival(
        _ state: inout VoiceReceiveDecisions.ReceiveState?,
        parsed: AudioRTPDepacketizer.Parsed,
        arrivalNs: UInt64,
        needsFadeIn: Bool,
        skipJitterFold: Bool
    ) {
        guard var updated = state else {
            state = VoiceReceiveDecisions.ReceiveState(
                lastSequence: parsed.sequenceNumber,
                lastArrivalNs: arrivalNs,
                lastRTPTimestamp: parsed.timestamp
            )
            return
        }
        if needsFadeIn { updated.needsFadeIn = true }
        if !skipJitterFold {
            let rtpDeltaMs = Double(parsed.timestamp &- updated.lastRTPTimestamp) / 48.0
            let arrivalDeltaMs = Double(arrivalNs &- updated.lastArrivalNs) / 1_000_000.0
            let deviation = abs(arrivalDeltaMs - rtpDeltaMs)
            if !VoiceReceiveDecisions.isPauseDeviation(deviationMs: deviation) {
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
        _ state: inout VoiceReceiveDecisions.ReceiveState?,
        parsed: AudioRTPDepacketizer.Parsed,
        arrivalNs: UInt64
    ) {
        guard var updated = state else {
            state = VoiceReceiveDecisions.ReceiveState(
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

    // MARK: - Sweep (stale eviction + jitter target)

    /// Once a second, evict receive state for idle SSRCs, then re-derive the
    /// recommended playback depth from the worst remaining jitter.
    private func sweepIfDue(nowNs: UInt64) {
        if lastSweepNs == 0 {
            lastSweepNs = nowNs
            return
        }
        guard nowNs &- lastSweepNs >= 1_000_000_000 else { return }
        lastSweepNs = nowNs
        let stale = VoiceReceiveDecisions.staleSSRCs(
            lastArrivalsNs: receiveStates.mapValues(\.lastArrivalNs), nowNs: nowNs)
        for ssrc in stale {
            receiveStates.removeValue(forKey: ssrc)
            decoders.removeValue(forKey: ssrc)
            decoderFailures.removeValue(forKey: ssrc)
            lastSeen.removeValue(forKey: ssrc)
        }
        worstJitterMs = receiveStates.values.map(\.smoothedJitterMs).max() ?? 0
        jitterTarget = VoiceReceiveDecisions.jitterBufferTarget(
            smoothedJitterMs: worstJitterMs, currentTarget: jitterTarget)
    }

    // MARK: - Decoder pool

    private func ensureDecoder(for ssrc: UInt32) throws -> OpusVoiceDecoder {
        if let existing = decoders[ssrc] { return existing }
        evictIfFull()
        let fresh = try OpusVoiceDecoder()
        decoders[ssrc] = fresh
        return fresh
    }

    /// Make room by dropping the stream that has gone longest without a
    /// packet. Eviction, not refusal — the map fills with stale entries
    /// (people who left, SSRC-cycling peers), so silencing the newcomer would
    /// be the wrong call.
    private func evictIfFull() {
        guard decoders.count >= Self.maxConcurrentVoices else { return }
        guard
            let stalest = decoders.keys.min(by: { (lastSeen[$0] ?? 0) < (lastSeen[$1] ?? 0) })
        else { return }
        decoders.removeValue(forKey: stalest)
        lastSeen.removeValue(forKey: stalest)
        receiveStates.removeValue(forKey: stalest)
        decoderFailures.removeValue(forKey: stalest)
    }

    // MARK: - Small pure helpers

    /// Linear whole-frame ramp to silence, ending at exactly zero. Internal
    /// (not private) — test seam.
    static func fadeToSilence(_ samples: inout [Float]) {
        let count = samples.count
        guard count > 0 else { return }
        for i in samples.indices {
            samples[i] *= 1.0 - Float(i + 1) / Float(count)
        }
    }

    /// Ramp the first `fadeSampleCount` samples up from zero, after a
    /// concealment/resync boundary. Internal (not private) — test seam.
    static func applyFadeIn(_ samples: inout [Float]) {
        let span = min(VoiceReceiveDecisions.fadeSampleCount, samples.count)
        guard span > 0 else { return }
        for i in 0..<span {
            samples[i] *= Float(i + 1) / Float(span)
        }
    }

    /// Monotonic uptime in nanoseconds, for hosts that thread no clock.
    private static func monotonicNowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    // MARK: - Test seams

    /// Snapshot the per-SSRC decoder-failure records.
    var decoderFailuresForTesting: [UInt32: VoiceReceiveDecisions.DecoderFailureRecord] {
        lock.withLock { decoderFailures }
    }

    /// Inject a failure record so the cooldown/clear paths can be exercised
    /// without forcing a real `OpusVoiceDecoder` init failure.
    func injectDecoderFailureForTesting(
        ssrc: UInt32, record: VoiceReceiveDecisions.DecoderFailureRecord
    ) {
        lock.withLock { decoderFailures[ssrc] = record }
    }
}
