import AVFoundation
import CoreAudio
import Foundation
import TailscaleKit
import os

// `VoiceStats` and the pure decision layer (`audioRoute`/`decoderGateAction`/
// `gapAction`/`jitterBufferTarget`/etc.) live in the portable
// `VoiceReceiveDecisions` namespace in TailscreenAudio, shared with the
// Linux/Windows receive path (`VoiceDownlink`). This pipeline composes the
// same decisions; the aliases below keep the queue-confined code reading naturally.

/// PCM in -> Opus enc -> RTP out, and RTP in -> Opus dec (per SSRC) ->
/// `VoiceMixer` (per 20ms slot) -> mixed PCM out. Hardware glue is `MicCapture`.
///
/// The mix is real summation: `MicCapture` schedules everything `onMixedPCM`
/// delivers onto ONE `AVAudioPlayerNode`, so emitting per SSRC with two
/// remote voices would time-multiplex them instead of mixing (and double the
/// queue depth against the overrun cap). `VoiceMixer` sums frames landing in
/// the same slot; decoding, concealment, jitter and fades stay per SSRC.
///
/// Thread-safe via an internal serial queue: capture and network callbacks
/// dispatch onto it; state only mutates there.
///
/// `@unchecked Sendable`: stored mutable state is touched only from `queue`.
/// `statsLock`/`jitterTargetDepth` are lock-published for `MicCapture`'s
/// MainActor reads/writes. `onMixedPCM` is the exception — set once before
/// any `receive(_:)`.
final class VoiceChannel: @unchecked Sendable {
    let localSSRC: UInt32
    var isMuted: Bool {
        get { queue.sync { _isMuted } }
        set { queue.sync { _isMuted = newValue } }
    }

    private let onSend: (Data) -> Void

    /// One frame of PCM per 20ms playout slot, summed by `VoiceMixer`. Set
    /// once before the first `receive(_:)` call; the queue reads it without
    /// synchronization.
    var onMixedPCM: (([Float]) -> Void)?

    /// Kept separate from `onMixedPCM` so `MicCapture` schedules it into a
    /// dedicated `AVAudioPlayerNode` — one node would time-multiplex the two
    /// 50Hz streams instead of mixing. Set once before the first `receive(_:)` call.
    var onSystemAudioPCM: (([Float]) -> Void)?

    private let queue = DispatchQueue(label: "VoiceChannel")
    private var _isMuted: Bool = true
    private let encoder: OpusVoiceEncoder
    private let packetizer: AudioRTPPacketizer
    private let depacketizer = AudioRTPDepacketizer()
    private var decoders: [UInt32: OpusVoiceDecoder] = [:]
    private var decoderFailures: [UInt32: DecoderFailureRecord] = [:]
    private var receiveStates: [UInt32: ReceiveState] = [:]
    private var mixer = VoiceMixer()
    private var lastTargetRefreshNs: UInt64 = 0
    private var lastStatsLogNs: UInt64 = 0
    private var lastLoggedStats = VoiceStats()
    /// Same five-second window the transport rows use, so an audio row lines
    /// up with the transport row beside it.
    private var audioSummarySampler = DiagnosticsTransportSampler()
    /// Counters as of the previous `audio.summary`, so each row carries
    /// deltas rather than running totals.
    private var lastSummaryStats = VoiceStats()
    /// "Delivered in this window", not "has a decoder" — a stream that stops
    /// reads as 0 instead of holding its last count forever.
    private var voiceSSRCsThisWindow: Set<UInt32> = []
    private var systemAudioThisWindow = false
    private let statsLock = OSAllocatedUnfairLock<VoiceStats>(initialState: VoiceStats())
    private let jitterTargetDepth = OSAllocatedUnfairLock<Int>(
        initialState: VoiceChannel.initialJitterTargetDepth)
    private let outputDeviceName = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let logger = TSLogger()

    // Portable constants, forwarded so `MicCapture` and the mac tests keep
    // their `VoiceChannel.` spelling.
    static let samplesPerFrame = VoiceReceiveDecisions.samplesPerFrame
    static let fadeSampleCount = VoiceReceiveDecisions.fadeSampleCount
    static let initialJitterTargetDepth = VoiceReceiveDecisions.initialJitterTargetDepth
    /// Headroom before `MicCapture` drops an incoming buffer instead of
    /// scheduling it — the clock-drift backstop.
    static let playbackSlackBuffers = VoiceReceiveDecisions.playbackSlackBuffers
    static let receiveStateIdleNs = VoiceReceiveDecisions.receiveStateIdleNs
    static let decoderInitRetryCooldownNs = VoiceReceiveDecisions.decoderInitRetryCooldownNs
    static let decoderInitFailureLimit = VoiceReceiveDecisions.decoderInitFailureLimit

    typealias DecoderFailureRecord = VoiceReceiveDecisions.DecoderFailureRecord

    /// `GapAction` narrowed for `trackArrival`: `.dropStale` returns before
    /// arrival tracking runs, so this type has no case for it.
    private enum ArrivalKind: Equatable {
        case inOrder
        case concealed
        case discontinuity
    }

    private typealias ReceiveState = VoiceReceiveDecisions.ReceiveState

    init(localSSRC: UInt32, onSend: @escaping (Data) -> Void) throws {
        self.localSSRC = localSSRC
        self.onSend = onSend
        self.encoder = try OpusVoiceEncoder()
        self.packetizer = AudioRTPPacketizer(ssrc: localSSRC)
    }

    /// No-op when muted.
    func processOutboundFrame(_ pcm: [Float]) {
        queue.async {
            guard !self._isMuted else { return }
            // Also the summary's clock while transmitting, so a session
            // whose inbound voice stopped keeps reporting it.
            self.maybeRecordAudioSummary(nowNs: DispatchTime.now().uptimeNanoseconds)
            do {
                guard let au = try self.encoder.encode(pcm: pcm) else { return }
                let packet = self.packetizer.packetize(au: au)
                self.onSend(packet)
            } catch {
                self.logger.log("VoiceChannel: encode failed: \(error)")
            }
        }
    }

    func receive(_ packet: Data) {
        queue.async {
            self.processInbound(packet)
        }
    }

    /// Called when the share session ends so a future session starts fresh.
    func reset() {
        queue.async {
            self.decoders.removeAll()
            self.decoderFailures.removeAll()
            self.receiveStates.removeAll()
            self.mixer.reset()
            self.lastTargetRefreshNs = 0
            self.lastStatsLogNs = 0
            self.lastLoggedStats = VoiceStats()
            self.audioSummarySampler.reset()
            self.lastSummaryStats = VoiceStats()
            self.voiceSSRCsThisWindow.removeAll()
            self.systemAudioThisWindow = false
            self.jitterTargetDepth.withLock { $0 = Self.initialJitterTargetDepth }
            self.statsLock.withLock { $0 = VoiceStats() }
        }
    }

    // MARK: - Cross-thread published values

    /// Read by `MicCapture.scheduleSamples` on the MainActor; refreshed on
    /// `queue` — hence the lock.
    var currentJitterTargetDepth: Int {
        jitterTargetDepth.withLock { $0 }
    }

    var currentStats: VoiceStats {
        statsLock.withLock { $0 }
    }

    /// Pushed in by the host: Core Audio device state lives on the
    /// MainActor, so it's lock-published here (like `jitterTargetDepth` the
    /// other way), keeping each row self-contained.
    func setOutputDeviceName(_ name: String?) {
        outputDeviceName.withLock { $0 = name }
    }

    /// Called from the MainActor (`MicCapture`).
    func noteOverrunDrop() {
        statsLock.withLock { $0.overrunDrops += 1 }
    }

    /// Called from the MainActor (`MicCapture`).
    func noteUnderrun() {
        statsLock.withLock { $0.underruns += 1 }
    }

    // MARK: - Inbound pipeline (queue-confined)

    private func processInbound(_ packet: Data) {
        guard let parsed = depacketizer.unpack(packet) else { return }
        maybeRecordAudioSummary(nowNs: DispatchTime.now().uptimeNanoseconds)
        switch VoiceReceiveDecisions.audioRoute(payloadType: parsed.payloadType) {
        case .drop:
            return
        case .systemAudio:
            systemAudioThisWindow = true
            processSystemAudioInbound(parsed)
            return
        case .voice:
            break
        }
        guard parsed.ssrc != localSSRC else { return }  // drop our own loopback
        voiceSSRCsThisWindow.insert(parsed.ssrc)
        let now = DispatchTime.now().uptimeNanoseconds
        // Single dictionary fetch per packet (50Hz hot path); each exit path
        // writes it back once.
        var state = receiveStates[parsed.ssrc]
        guard
            case .allow = VoiceReceiveDecisions.decoderGateAction(
                record: decoderFailures[parsed.ssrc], nowNs: now)
        else {
            // Gate-dropped packets still advance the baseline, or the first
            // packet after cooldown reads as a spurious gap.
            Self.advanceBaseline(&state, parsed: parsed, arrivalNs: now)
            receiveStates[parsed.ssrc] = state
            return
        }

        let action = VoiceReceiveDecisions.gapAction(
            lastSeq: state?.lastSequence, newSeq: parsed.sequenceNumber)
        let kind: ArrivalKind
        switch action {
        case .dropStale:
            // Decoding it now would play those 20ms twice.
            return
        case .decode:
            kind = .inOrder
        case .concealThenDecode(let missing):
            emitConcealment(
                for: parsed.ssrc,
                frames: VoiceReceiveDecisions.concealmentEmitCount(missing: missing),
                lastSample: state?.lastEmittedSample ?? 0,
                nowNs: now)
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

    /// Reuses the per-SSRC decoder + failure-cooldown machinery but skips the
    /// voice jitter/concealment pipeline — playback is queue-paced in
    /// `MicCapture`, and the system-audio SSRC never collides with a voice SSRC.
    private func processSystemAudioInbound(_ parsed: AudioRTPDepacketizer.Parsed) {
        guard let emit = onSystemAudioPCM else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard
            case .allow = VoiceReceiveDecisions.decoderGateAction(
                record: decoderFailures[parsed.ssrc], nowNs: now)
        else {
            return
        }
        do {
            let decoder = try ensureDecoder(for: parsed.ssrc)
            var samples = try decoder.decode(au: parsed.au)
            decoderFailures.removeValue(forKey: parsed.ssrc)
            guard !samples.isEmpty else { return }
            if VoiceReceiveDecisions.clampToUnitRange(&samples) {
                statsLock.withLock { $0.systemAudioClampedBuffers += 1 }
            }
            emit(samples)
        } catch {
            recordDecodeFailure(for: parsed.ssrc, error: error, nowNs: now)
        }
    }

    /// RFC 3550 smoothed inter-arrival jitter: `J += (|D| - J) / 16`. Skipped
    /// on a discontinuity (a resync's timestamp jump isn't jitter) and on a
    /// pause-shaped deviation (send-side mute), which just resyncs the baseline.
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
        let stale = VoiceReceiveDecisions.staleSSRCs(
            lastArrivalsNs: receiveStates.mapValues(\.lastArrivalNs), nowNs: nowNs)
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
            depth = VoiceReceiveDecisions.jitterBufferTarget(
                smoothedJitterMs: worstJitterMs, currentTarget: old)
            return (old, depth)
        }
        guard next != previous else { return }
        logger.log(
            "VoiceChannel: jitter buffer target \(previous) → \(next) buffers "
                + "(smoothed jitter \(String(format: "%.1f", worstJitterMs)) ms)")
    }

    /// Emit `frames` frames of silence to cover a sequence gap, ramping
    /// the last emitted sample down to zero at the leading edge so the
    /// codec-restart discontinuity doesn't land as a hard click. We conceal
    /// with faded silence rather than driving Opus's built-in PLC
    /// (`decode(nil)`): the silence path is codec-agnostic and already the
    /// well-tested behavior. (A future refinement could feed the decoder
    /// `nil` for true Opus packet-loss concealment.) `frames`
    /// arrives pre-capped by `concealmentEmitCount`, so this fill can
    /// never occupy the playback-queue headroom the gap's next real frame
    /// needs. `concealedFrames` counts only what is actually emitted.
    ///
    /// The fill enters the mix under the gap's SSRC: the mixer keeps one
    /// SSRC's frames sequential, so a burst of several fill frames plays in
    /// order, while another voice's frame in the same slot is summed in.
    private func emitConcealment(for ssrc: UInt32, frames: Int, lastSample: Float, nowNs: UInt64) {
        guard frames > 0, onMixedPCM != nil else { return }
        statsLock.withLock { $0.concealedFrames += frames }
        for frameIndex in 0..<frames {
            let fill: [Float]
            if frameIndex == 0 {
                fill = VoiceReceiveDecisions.concealmentFadeOut(from: lastSample)
            } else {
                fill = [Float](repeating: 0, count: Self.samplesPerFrame)
            }
            emitMixed(ssrc: ssrc, samples: fill, nowNs: nowNs)
        }
    }

    /// The one exit of the voice path: run a per-SSRC frame through the
    /// per-slot mixer and hand whatever it releases to `onMixedPCM`, in order.
    private func emitMixed(ssrc: UInt32, samples: [Float], nowNs: UInt64) {
        guard let emit = onMixedPCM else { return }
        for frame in mixer.add(ssrc: ssrc, samples: samples, nowNs: nowNs) {
            emit(frame)
        }
    }

    private func decodeAndEmit(
        _ parsed: AudioRTPDepacketizer.Parsed, state: inout ReceiveState?, nowNs: UInt64
    ) {
        do {
            let decoder = try ensureDecoder(for: parsed.ssrc)
            let raw = try decoder.decode(au: parsed.au)
            decoderFailures.removeValue(forKey: parsed.ssrc)
            guard !raw.isEmpty else { return }
            var samples = raw
            if VoiceReceiveDecisions.clampToUnitRange(&samples) {
                let count = statsLock.withLock { stats -> Int in
                    stats.clampedBuffers += 1
                    return stats.clampedBuffers
                }
                if VoiceReceiveDecisions.shouldLogClamp(count: count) {
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
            emitMixed(ssrc: parsed.ssrc, samples: samples, nowNs: nowNs)
        } catch {
            recordDecodeFailure(for: parsed.ssrc, error: error, nowNs: nowNs)
        }
    }

    /// Init failures (no decoder cached yet) upsert the cooldown record;
    /// decode (not init) failures keep the decoder, since transient
    /// corruption is normal.
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

    /// Unlike `maybeLogStats`, fires on the window regardless of whether a
    /// counter moved — a call that sounds bad while counters sit still must
    /// not read the same as a call with no voice in it.
    private func maybeRecordAudioSummary(nowNs: UInt64) {
        guard let windowNs = audioSummarySampler.windowClosed(nowNs: nowNs) else { return }
        let streams = voiceSSRCsThisWindow.count
        let systemAudio = systemAudioThisWindow
        voiceSSRCsThisWindow.removeAll(keepingCapacity: true)
        systemAudioThisWindow = false

        let context = VoiceStats.PlaybackContext(
            voiceStreams: streams,
            systemAudioPlaying: systemAudio,
            microphoneOn: !_isMuted,
            jitterTargetDepth: jitterTargetDepth.withLock { $0 },
            outputDevice: outputDeviceName.withLock { $0 },
            playbackQueueTracked: true)
        // Window bookkeeping above still advanced — a suppressed window
        // must not fold into the next.
        guard VoiceStats.shouldRecordSummary(context: context) else { return }

        let snapshot = statsLock.withLock { $0 }
        let previous = lastSummaryStats
        lastSummaryStats = snapshot
        DiagnosticsCenter.shared.recorder?.record(
            .audioSummary,
            fields: snapshot.audioSummaryFields(
                since: previous, windowNs: windowNs, context: context))
    }

    private func ensureDecoder(for ssrc: UInt32) throws -> OpusVoiceDecoder {
        if let existing = decoders[ssrc] { return existing }
        let new = try OpusVoiceDecoder()
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
    /// be exercised without forcing a real `OpusVoiceDecoder` init failure.
    internal func injectDecoderFailureForTesting(ssrc: UInt32, record: DecoderFailureRecord) {
        queue.sync { decoderFailures[ssrc] = record }
    }
    #endif
}

/// Drains the AVAudioEngine input tap on the audio render thread and feeds
/// 960-sample frames into the VoiceChannel. Lives outside `@MainActor`:
/// installTap fires on AVAudioEngine's serialized real-time queue, and
/// hopping every callback to MainActor would introduce unacceptable latency
/// at 50Hz.
///
/// All state is touched only from the tap callback, which AVAudioEngine
/// serializes.
private final class TapBuffer: @unchecked Sendable {
    private let channel: VoiceChannel
    private var framer = PCMFramer(frameSamples: VoiceChannel.samplesPerFrame)
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

    /// `AVAudioInputNode.outputFormat(forBus:)` lies on macOS+VPIO until the
    /// first buffer renders, so the real format is only known once buffers
    /// arrive. Always extracts channel 0 to mono first: with VPIO the input
    /// bus presents multi-channel `[mic, ref_L, ref_R]`, and
    /// AVAudioConverter's default downmix sums all channels (clipping).
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

        // No AVAudioConverter needed if the mono-extracted format already
        // matches 48kHz mono Float32.
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

        guard let srcCd = buffer.floatChannelData?[0] else { return }
        let frameLen = Int(buffer.frameLength)
        guard frameLen > 0 else { return }

        // Fast path: already 48kHz Float32.
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
                // `.noDataNow`, not `.endOfStream`: the latter latches and
                // permanently refuses further input.
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
        for frame in framer.push(samples) {
            channel.processOutboundFrame(frame)
        }
    }
}

@MainActor
final class MicCapture {
    private let channel: VoiceChannel
    private let engine = AVAudioEngine()
    private var playerNodes: [AVAudioPlayerNode] = []
    /// Load-bearing: two concurrent 50Hz PCM streams serialized into one
    /// node would time-multiplex instead of mixing.
    private var systemAudioPlayer: AVAudioPlayerNode?
    /// AVAudioPlayerNode exposes no queue depth; reset by
    /// `resetPlaybackQueues` at every point the node's queue is known empty.
    private var voiceQueue = PlaybackQueueAccounting()
    private var systemAudioQueue = PlaybackQueueAccounting()
    private let mixer: AVAudioMixerNode
    private let outputFormat: AVAudioFormat
    private var tapBuffer: TapBuffer?
    private var isPlaying = false
    private(set) var isCapturing = false
    private var configChangeObserver: NSObjectProtocol?

    /// AVAudioEngine only renders an input node when something downstream
    /// pulls from it; installing a tap alone is not enough on macOS. Without
    /// this, the engine pulls input once at start-up then idles, surfacing
    /// as "one tap buffer, then silence". `outputVolume = 0` keeps the user
    /// from hearing their own voice.
    private let inputSinkMixer = AVAudioMixerNode()
    private var inputSinkConnected = false

    /// Isolates codec/transport/playback bugs from AEC/feedback issues when
    /// running two instances on one Mac.
    private var testToneTimer: DispatchSourceTimer?
    private static var isTestToneEnabled: Bool {
        ProcessInfo.processInfo.environment["TAILSCREEN_VOICE_TEST_TONE"] == "1"
    }

    /// `nil` means "follow the system default". Applied at engine start
    /// time, so changes take effect after the next stop()/start() cycle.
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
    /// was running so the new device takes effect. The players' queues
    /// do not survive the restart, so their bookkeeping is reset with
    /// them; the jitter-buffer kick in `scheduleSamples` primes and
    /// restarts playback on the next arrivals.
    func setOutputDevice(_ deviceID: AudioDeviceID?) {
        outputDeviceID = deviceID
        guard isPlaying else { return }
        resetPlaybackQueues(reason: "output device change")
        engine.stop()
        applyOutputDevice()
        do {
            try engine.start()
        } catch {
            logger.log("MicCapture: failed to restart engine after output device change: \(error)")
        }
    }

    /// Empty both player queues and their bookkeeping. Called at every
    /// point where the queues are *known* to be empty: before we stop the
    /// engine ourselves (enabling voice processing, an output-device
    /// change, teardown) and after the engine stopped itself for a
    /// configuration change.
    ///
    /// This is what keeps the pending counts self-healing. A count only
    /// ever comes down from a scheduleBuffer completion, and an engine
    /// stop or I/O-unit swap can discard the queued buffers without
    /// invoking one; a count left pinned at the cap makes every later
    /// arrival an overrun drop — inbound voice silent for the rest of the
    /// session, `overruns=` climbing in the stats line. That is the shape
    /// 0.10.0-rc.14 had: each machine went deaf the moment its own mic
    /// came on, because `enableCapture`'s VPIO restart went through the
    /// engine and the players with no reset (the only one ran once, in
    /// `startPlayback`).
    ///
    /// Order matters: the accounting is reset (opening a new generation)
    /// *before* the nodes are stopped, because `AVAudioPlayerNode.stop()`
    /// invokes the completion of every buffer it discards — synchronously,
    /// on AVFAudio's queue — and those completions must land as orphans of
    /// the old generation, not as decrements of the fresh count.
    private func resetPlaybackQueues(reason: String) {
        let healed = voiceQueue.reset() + systemAudioQueue.reset()
        for node in playerNodes { node.stop() }
        systemAudioPlayer?.stop()
        if healed > 0 {
            logger.log("MicCapture: playback queues reset (\(reason)); \(healed) queued buffer(s) discarded.")
        }
    }

    /// Done at `startPlayback` and again after voice processing/config
    /// changes, since those aren't relied on to preserve the graph.
    private func connectPlayers() {
        for player in playerNodes {
            engine.connect(player, to: mixer, format: outputFormat)
        }
        if let sysPlayer = systemAudioPlayer {
            engine.connect(sysPlayer, to: mixer, format: outputFormat)
        }
    }

    /// Engine must be stopped at the call site —
    /// `kAudioOutputUnitProperty_CurrentDevice` is only honored when the
    /// unit isn't running.
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

        channel.onMixedPCM = { [weak self] samples in
            Task { @MainActor [weak self] in self?.scheduleSamples(samples) }
        }

        // Its own player node so it mixes with, rather than time-multiplexes
        // against, voice.
        channel.onSystemAudioPCM = { [weak self] samples in
            Task { @MainActor [weak self] in self?.scheduleSystemAudioSamples(samples) }
        }

        // A reconfigure tears down node connections, so an installed input
        // tap stops firing ("exactly one packet, then silence").
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleConfigurationChange() }
        }
    }

    /// Starts the engine without touching the input node, so listening
    /// works without prompting for microphone permission.
    func startPlayback() throws {
        guard !isPlaying else { return }
        // Orphans any scheduleBuffer completion still in flight from a
        // previous session, or a stale completion could drive the count negative.
        voiceQueue.reset()
        systemAudioQueue.reset()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        playerNodes.append(player)
        // Dedicated system-audio node, summed by mainMixerNode.
        let sysPlayer = AVAudioPlayerNode()
        engine.attach(sysPlayer)
        systemAudioPlayer = sysPlayer
        connectPlayers()
        applyOutputDevice()
        try engine.start()
        // Don't call player.play() yet — scheduleSamples kicks off playback
        // once the jitter target depth is queued, so it doesn't underrun on
        // the first arrival hiccup.
        isPlaying = true
        logger.log("MicCapture: playback engine started (output-only, no mic, awaiting jitter buffer).")
    }

    /// Throws if permission is denied or the engine reconfigure fails.
    func enableCapture() async throws {
        guard !isCapturing else { return }

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

        // setVoiceProcessingEnabled requires the engine to be stopped, which
        // empties the players' queues; bookkeeping resets with them, and
        // playback re-primes via the jitter-buffer kick once the engine is back.
        if isPlaying {
            resetPlaybackQueues(reason: "enabling voice processing")
            engine.stop()
        }
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            try engine.outputNode.setVoiceProcessingEnabled(true)
        } catch {
            // Don't swallow: without VPIO, AEC is off and the tap often
            // fires once before the engine renegotiates.
            logger.log("MicCapture: VPIO not engaged: \(error). Continuing without AEC.")
        }
        // Voice processing swaps the I/O unit under the output node, so the
        // player -> mixer edges are re-established rather than trusted to survive.
        if isPlaying { connectPlayers() }

        // The name, not just ID: reveals a virtual loopback sitting where
        // the user assumes the built-in mic is.
        let defaultInput = AudioDevices.defaultInputID().flatMap { AudioDevices.name(of: $0) }
        logger.log("MicCapture: default input device = \(defaultInput ?? "<unknown>")")

        guard let buffer = TapBuffer(channel: channel) else {
            throw NSError(
                domain: "Tailscreen.VoiceChannel",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate TapBuffer target format"]
            )
        }
        self.tapBuffer = buffer

        // See `inputSinkMixer` doc-comment.
        if !inputSinkConnected {
            engine.attach(inputSinkMixer)
            inputSinkMixer.outputVolume = 0
            engine.connect(engine.inputNode, to: inputSinkMixer, format: nil)
            engine.connect(inputSinkMixer, to: mixer, format: outputFormat)
            inputSinkConnected = true
        }

        // `format: nil`: pre-start `outputFormat(forBus:)` lies (returns the
        // output device's format), so the real format is discovered lazily
        // inside TapBuffer.
        Self.installTap(on: engine.inputNode, buffer: buffer)

        applyInputDevice()
        applyOutputDevice()
        try engine.start()
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
            resetPlaybackQueues(reason: "stop")
            engine.stop()
            for node in playerNodes { engine.detach(node) }
            if let sysPlayer = systemAudioPlayer { engine.detach(sysPlayer) }
            systemAudioPlayer = nil
            playerNodes.removeAll()
            isPlaying = false
        }
    }

    /// Three things need putting back after AVAudioEngine stops itself and
    /// uninitializes on a hardware format/route change:
    /// - Player queues went with the engine, so bookkeeping resets and
    ///   re-primes via the jitter-buffer kick.
    /// - The input tap stops firing and the input format may have changed;
    ///   rebuild the converter and reinstall the tap while capturing.
    /// - The engine must restart even for a listening-only viewer, not just
    ///   while capturing.
    private func handleConfigurationChange() {
        guard isPlaying || isCapturing else { return }
        if isPlaying {
            resetPlaybackQueues(reason: "configuration change")
        }
        if isCapturing {
            engine.inputNode.removeTap(onBus: 0)
            guard let buffer = TapBuffer(channel: channel) else {
                logger.log("MicCapture: configuration change — TapBuffer alloc failed; capture stalled.")
                return
            }
            self.tapBuffer = buffer
            Self.installTap(on: engine.inputNode, buffer: buffer)
        }
        if !engine.isRunning {
            if isPlaying { connectPlayers() }
            do {
                try engine.start()
            } catch {
                logger.log("MicCapture: configuration change — engine restart failed: \(error)")
                return
            }
        }
        logger.log(
            "MicCapture: engine reconfigured after configuration change "
                + "(playing=\(isPlaying) capturing=\(isCapturing) running=\(engine.isRunning)).")
    }

    /// Lives outside `@MainActor` so the timer queue can mutate `phase`
    /// without hopping; sound since only that queue touches it.
    private final class TestToneState: @unchecked Sendable {
        var phase: Float = 0
    }

    private func startTestTone() {
        // Nonisolated context, or the closure inherits MainActor isolation
        // and trips Swift 6's executor check when the timer queue dispatches it.
        testToneTimer = Self.makeTestToneTimer(channel: channel)
    }

    nonisolated private static func makeTestToneTimer(channel: VoiceChannel) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "MicCapture.testTone"))
        let intervalNs = UInt64(
            Double(VoiceChannel.samplesPerFrame) / 48_000.0 * 1_000_000_000)
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
        let frameSize = VoiceChannel.samplesPerFrame
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

    /// Nonisolated so the retained closure doesn't inherit `@MainActor`
    /// isolation, which would trip Swift 6's executor check on the audio
    /// render thread.
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

    /// Every arrival of decoded voice PCM lands here on the MainActor.
    /// The decisions — drop at the cap, prime then kick, underrun verdict
    /// — are `PlaybackQueueAccounting`'s; this method owns the AVFAudio
    /// calls around them.
    ///
    /// The cap: the sender's timer drifts a hair faster than the receiver's
    /// audio clock, so without one the queue grows unbounded (audible
    /// latency after muting). Dropping at `targetDepth + playbackSlackBuffers`
    /// eats one ~20ms frame at most and bounds end-to-end latency.
    private func scheduleSamples(_ samples: [Float]) {
        guard isPlaying, let player = playerNodes.first else { return }
        // Counts as an underrun only if audio resumes shortly after
        // (starve-then-resume); a drain followed by silence was a benign
        // stop (mute/end of stream).
        if voiceQueue.takeStarveVerdict(nowNs: DispatchTime.now().uptimeNanoseconds) {
            channel.noteUnderrun()
        }
        let targetDepth = channel.currentJitterTargetDepth
        guard let buffer = Self.makeBuffer(samples, format: outputFormat) else { return }
        let verdict = voiceQueue.schedule(
            targetDepth: targetDepth,
            slack: VoiceChannel.playbackSlackBuffers,
            playerIsPlaying: player.isPlaying
        )
        guard case .schedule(let kickPlayback) = verdict else {
            channel.noteOverrunDrop()
            return
        }
        let generation = voiceQueue.generation
        // AVFAudio runs this on its own queue, sometimes synchronously from
        // `stop()`'s command destructor. `@Sendable` avoids the inferred
        // MainActor isolation that would trap under Swift 6's executor
        // check — same fix as `installTap`.
        let onBufferConsumed: @Sendable () -> Void = { [weak self] in
            // Captured generation lets accounting orphan a completion for a
            // buffer a reset already discarded.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.voiceQueue.consumed(
                    generation: generation,
                    playerIsPlaying: self.playerNodes.first?.isPlaying == true,
                    nowNs: DispatchTime.now().uptimeNanoseconds
                )
            }
        }
        player.scheduleBuffer(buffer, completionHandler: onBufferConsumed)
        if kickPlayback { player.play() }
    }

    /// A twin of `scheduleSamples` but simpler: fixed jitter target, no
    /// underrun bookkeeping (voice players already drive the jitter estimate).
    private func scheduleSystemAudioSamples(_ samples: [Float]) {
        guard isPlaying, let player = systemAudioPlayer else { return }
        guard let buffer = Self.makeBuffer(samples, format: outputFormat) else { return }
        let verdict = systemAudioQueue.schedule(
            targetDepth: VoiceChannel.initialJitterTargetDepth,
            slack: VoiceChannel.playbackSlackBuffers,
            playerIsPlaying: player.isPlaying
        )
        guard case .schedule(let kickPlayback) = verdict else {
            channel.noteOverrunDrop()
            return
        }
        let generation = systemAudioQueue.generation
        let onBufferConsumed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.systemAudioQueue.consumed(
                    generation: generation,
                    playerIsPlaying: self.systemAudioPlayer?.isPlaying == true,
                    nowNs: DispatchTime.now().uptimeNanoseconds
                )
            }
        }
        player.scheduleBuffer(buffer, completionHandler: onBufferConsumed)
        if kickPlayback { player.play() }
    }

    /// One decoded block as a player-node buffer in the codec format.
    private static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let dst = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, sample) in samples.enumerated() {
            dst[i] = sample
        }
        return buffer
    }

    // `nonisolated` is load-bearing: TCC fires the callback off-main, and an
    // inferred MainActor closure would trap under Swift 6's executor check.
    nonisolated private static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }
}

// MARK: - Logger

/// Teed into the diagnostics bundle exactly as the viewer client's sink is.
private struct TSLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[Voice] \(message)")
        DiagnosticsCenter.shared.captureLog(source: "Voice", message: message)
    }
}
