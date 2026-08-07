import Foundation
import TailscreenProtocol

/// The receiving half of the voice path: RTP in, 48 kHz mono PCM out, one
/// independent Opus decoder per SSRC.
///
/// The inverse of `VoiceUplink` and, like it, one type for both endpoints. A
/// viewer decodes the sharer's voice (SSRC 0), the shared system audio
/// (SSRC 1) and every other viewer's relayed voice; a sharer decodes its
/// viewers'. Same demux, same per-stream state, so the sharer hosts on Linux
/// and Windows get it by construction rather than by growing a second copy —
/// which is what `ViewerSession` had inline before this, and why a sharer on
/// those platforms could be heard but could not hear.
///
/// Loss-resilient, composing the same `VoiceReceiveDecisions` the macOS
/// `VoiceChannel` pipeline does, so a lossy link degrades the same way on
/// every platform:
///
/// - **Sequence gaps are concealed** (voice only): a small forward gap emits
///   up to `concealmentEmitCount` frames of Opus's native packet-loss
///   concealment (`OpusVoiceDecoder.conceal()` — the decoder extrapolates
///   from its own history, far closer to the lost speech than silence). A
///   gap the cap cannot cover fades its last concealment frame to silence
///   and fades the next real frame back in, so neither boundary clicks. A
///   duplicate or reordered-late packet is dropped rather than played twice;
///   a gap too large to fill resyncs the sequence clock instead.
/// - **Decoder failures cool down**: an SSRC whose decoder cannot be built
///   is gated for `decoderInitRetryCooldownNs` per attempt (permanently
///   after `decoderInitFailureLimit`), and gate-dropped packets still
///   advance the sequence baseline so the first packet after the cooldown
///   is not misread as a gap.
/// - **The jitter estimate adapts**: per-SSRC RFC 3550 smoothed
///   inter-arrival jitter (pause-shaped deviations excluded) feeds
///   `jitterBufferTarget`, published as `currentJitterTargetDepth` for a
///   host's playback queue to consult.
/// - **Idle SSRCs are evicted** after `receiveStateIdleNs`, so a departed
///   peer's frozen jitter cannot pin the target high for the session.
///
/// System audio (PT 99) deliberately skips the gap/jitter machinery — same
/// as the macOS pipeline: playback of it is queue-paced by the host, and the
/// concealment tuning is voice-shaped. It still gets the decode path and the
/// failure cooldown.
///
/// Emits PCM tagged with its SSRC rather than mixing: who is speaking is
/// information the host needs (to route system audio to a different node than
/// voice, to show a speaking indicator) and mixing throws it away irreversibly.
///
/// Timing: every decision that needs a clock reads the `nowNs` handed to
/// `ingest`. Hosts that already thread a monotonic clock (`ViewerSession`
/// passes its `tick` clock through) get deterministic behavior; hosts that
/// do not (the sharer receive threads) omit it and the downlink reads the
/// monotonic uptime clock itself.
///
/// **Thread-safe by lock**, not by contract. Ingest runs on the host's receive
/// loop, which is serial — but `reset()` does not: both sharer hosts call
/// `SharerVoice.stop()` from the thread that tore the share down while the
/// server is still delivering inbound audio (`onAudioReceived` is documented
/// as "assign before `start()`, leave alone until after `stop()` returns", so
/// there is no detach that could drain it first). Dropping every decoder and
/// every per-SSRC map out from under an in-flight `ingest` is a genuine data
/// race, so all mutable state below is guarded — see `lock`.
public final class VoiceDownlink: @unchecked Sendable {
    /// Concurrent voices to keep decoders for.
    ///
    /// A bound, not a capacity guess. Each SSRC allocates an Opus decoder, and
    /// the SSRC is a field in a datagram from the network — so an unbounded map
    /// is a remote allocation primitive. 32 is far above any real call and far
    /// below anything that matters for memory.
    public static let maxConcurrentVoices = 32

    /// Decoded 48 kHz mono PCM, tagged with the SSRC it came from. Concealment
    /// frames are emitted through the same hook, under the gap's SSRC.
    public var onPCM: ((UInt32, [Float]) -> Void)? {
        get { lock.withLock { pcmSink } }
        set { lock.withLock { pcmSink = newValue } }
    }

    /// One buffer of decoded (or concealed) PCM, on its way out.
    ///
    /// Emissions are collected inside the critical section and delivered after
    /// it: `onPCM` reaches a host's playback device (ALSA, WASAPI, a MainActor
    /// hop), and holding a lock across that would park a share teardown behind
    /// an audio device. Buffering keeps the order the decode produced, which
    /// is what makes concealment-then-decode still arrive in that order.
    private typealias Emission = (ssrc: UInt32, samples: [Float])

    /// Guards every mutable field below — the decoder pool, the per-SSRC
    /// sequence/jitter state, the failure records, the counters and `pcmSink`.
    ///
    /// The two contenders are the host's receive thread (`ingest`) and
    /// whichever thread stopped the share (`reset`). Nothing is emitted while
    /// it is held; see `Emission`.
    private let lock = NSLock()
    private var pcmSink: ((UInt32, [Float]) -> Void)?

    private let depacketizer = AudioRTPDepacketizer()
    private var decoders: [UInt32: OpusVoiceDecoder] = [:]
    /// Ingest ordinal of each SSRC's last packet, for capacity eviction. A
    /// counter rather than a clock so the bound's behaviour is deterministic
    /// even for hosts that pass no `nowNs`.
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

    // Resilience counters. Internal on purpose: they exist so the package
    // tests can see what was concealed/resynced/clamped without asserting on
    // audio; a host wanting a stats line would promote them deliberately.
    private var concealed = 0
    private var discontinuities = 0
    private var clampedBuffers = 0

    var concealedFrameCount: Int { lock.withLock { concealed } }
    var discontinuityCount: Int { lock.withLock { discontinuities } }
    var clampedBufferCount: Int { lock.withLock { clampedBuffers } }

    public init() {}

    /// Playback queue depth (in 20 ms buffers) the jitter estimator currently
    /// recommends — `VoiceReceiveDecisions.jitterBufferTarget` over the worst
    /// live stream, moved one step per sweep. A host with a pacing playback
    /// queue can consult it; ignoring it is also fine.
    public var currentJitterTargetDepth: Int { lock.withLock { jitterTarget } }

    /// Feed one audio RTP datagram (PT 98 or 99). Anything else decodes to nil
    /// and is dropped.
    ///
    /// - Parameter nowNs: monotonic clock reading for this packet's arrival.
    ///   Pass the host's clock where one is already threaded (deterministic,
    ///   testable); nil reads the process's monotonic uptime clock.
    public func ingest(_ packet: Data, nowNs: UInt64? = nil) {
        let now = nowNs ?? Self.monotonicNowNs()
        let (sink, emissions) = lock.withLock {
            () -> (((UInt32, [Float]) -> Void)?, [Emission]) in
            guard let parsed = depacketizer.unpack(packet) else { return (nil, []) }
            ingestCount &+= 1
            lastSeen[parsed.ssrc] = ingestCount

            var out: [Emission] = []
            switch VoiceReceiveDecisions.audioRoute(payloadType: parsed.payloadType) {
            case .drop:
                return (nil, [])  // Unreachable — `unpack` admits only PT 98/99 — but total.
            case .systemAudio:
                ingestSystemAudio(parsed, nowNs: now, into: &out)
            case .voice:
                ingestVoice(parsed, nowNs: now, into: &out)
            }
            sweepIfDue(nowNs: now)
            return (pcmSink, out)
        }
        guard let sink else { return }
        for emission in emissions { sink(emission.ssrc, emission.samples) }
    }

    /// Drop every decoder and all resilience state — a new session, or a
    /// sharer switch.
    ///
    /// Safe against a concurrent `ingest`: it takes the same lock, so this
    /// either runs before that packet's whole decode or after it, never
    /// through the middle of one.
    public func reset() {
        lock.withLock {
            decoders.removeAll()
            lastSeen.removeAll()
            ingestCount = 0
            receiveStates.removeAll()
            decoderFailures.removeAll()
            jitterTarget = VoiceReceiveDecisions.initialJitterTargetDepth
            lastSweepNs = 0
            concealed = 0
            discontinuities = 0
            clampedBuffers = 0
        }
    }

    /// Live decoders. Exposed so a test can see the bound hold, which is the
    /// only way to observe it.
    public var voiceCount: Int { lock.withLock { decoders.count } }

    /// Whether this SSRC currently holds a decoder.
    ///
    /// The only way to see *which* stream eviction took. Without it a test can
    /// assert the map stayed bounded while the policy evicts precisely the
    /// wrong stream, which is a green check over a call where whoever is
    /// talking is the one being cut off.
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
            // Late arrival of a packet whose gap was already concealed —
            // decoding it now would play those 20 ms twice. State is
            // untouched, so nothing needs writing back.
            return
        case .decode:
            break
        case .concealThenDecode(let missing):
            let emitted = emitConcealment(for: parsed.ssrc, missing: missing, into: &out)
            // A gap the cap did not fully cover leaves real silence before
            // this packet — fade it back in so the boundary has no step. A
            // fully covered gap is continuous through Opus PLC and needs
            // neither fade.
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

    /// Decode one system-audio packet (PT 99, reserved SSRC 1) and emit. The
    /// decoder + failure-cooldown machinery apply; the voice jitter and
    /// concealment machinery deliberately do not (playback is queue-paced by
    /// the host, and the SSRC spaces are disjoint so the maps never collide).
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
            if VoiceReceiveDecisions.clampToUnitRange(&samples) { clampedBuffers += 1 }
            out.append((parsed.ssrc, samples))
        } catch {
            recordDecodeFailure(for: parsed.ssrc, nowNs: nowNs)
        }
    }

    /// Emit up to the capped number of concealment frames for a gap, via
    /// Opus's native PLC, fading the last one to silence when the cap left
    /// part of the gap uncovered. Returns how many frames were emitted.
    /// Counts only what is actually emitted (no sink, no history → nothing).
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
            // Successful init + non-throwing decode: the SSRC is healthy,
            // forget any failure history.
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

    /// Failure bookkeeping, mirroring the macOS pipeline: init failures (no
    /// decoder cached yet) upsert the cooldown record so the gate swallows
    /// packets until the cooldown elapses; decode (not init) failures keep
    /// the decoder — transient corruption is normal on a lossy link.
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
    /// into the RFC 3550 smoothed inter-arrival jitter, `J += (|D| - J) / 16`.
    /// The fold is skipped on a discontinuity — a resync's huge timestamp
    /// jump isn't jitter — and on a pause-shaped deviation (send-side mute),
    /// which just resyncs the baseline instead of poisoning the estimator.
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

    /// Once a second (on the ingest clock), evict receive state for SSRCs that
    /// have gone idle — a departed peer's frozen jitter must not pin the
    /// target — then re-derive the recommended playback depth from the worst
    /// remaining per-SSRC smoothed jitter.
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
        let worstJitterMs = receiveStates.values.map(\.smoothedJitterMs).max() ?? 0
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

    /// Make room by dropping the stream that has gone longest without a packet.
    ///
    /// Eviction rather than refusal: refusing the newcomer would silence a real
    /// participant permanently the moment the map filled, and the map fills
    /// with *stale* entries — people who left, or a peer cycling SSRCs. The
    /// quietest stream is the right one to forget, and if it speaks again it
    /// simply gets a fresh decoder and fresh gap/jitter state (one lost frame
    /// while Opus re-converges).
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

    /// Linear whole-frame ramp to silence, ending at exactly zero. Applied to
    /// the last concealment frame of a gap the cap could not fully cover, so
    /// the uncovered remainder starts from silence instead of a step.
    /// Internal (not private) — test seam.
    static func fadeToSilence(_ samples: inout [Float]) {
        let count = samples.count
        guard count > 0 else { return }
        for i in samples.indices {
            samples[i] *= 1.0 - Float(i + 1) / Float(count)
        }
    }

    /// Ramp the first `fadeSampleCount` samples up from zero — the same shape
    /// the macOS pipeline applies after a concealment/resync boundary.
    /// Internal (not private) — test seam.
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
