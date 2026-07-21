import Foundation
import TailscreenAudio
import TailscreenProtocol

/// Portable, host-agnostic viewer data-plane core.
///
/// `ViewerSession` is the receive half of a Tailscreen screen share reduced to
/// pure logic: it consumes inbound RTP datagrams and a host-supplied clock, and
/// produces decoded video frames (via `VideoSink`), decoded audio (via
/// `AudioSink`), and outbound feedback control bytes (via `onControlToSend`).
/// It reuses the already-portable pieces of `TailscreenProtocol`
/// (`MultiCodecDepacketizer`, `NACKScheduler`, `RRAccounting`,
/// `FECGroupBuffer` + `FECCodec`, `AudioRTPDepacketizer`,
/// `ScreenShareControlMessage`) and `TailscreenAudio` (`OpusVoiceDecoder`), so
/// nothing here is macOS-specific.
///
/// **It owns no I/O.** No socket, no thread, no timer. The host feeds it bytes
/// (`receiveRTP`) and a monotonic clock (`tick(nowNs:)`), and ships whatever the
/// session hands back through `onControlToSend`. That makes the whole thing
/// deterministic and unit-testable — the same extract-the-decision discipline
/// the rest of `TailscreenProtocol` follows — and lets a Linux/Windows viewer
/// reuse it verbatim behind its own platform socket + decoder + renderer.
///
/// Not `Sendable`: the host must serialize calls (all of `start` / `receiveRTP`
/// / `tick` on one queue), the same contract the mac client already honors for
/// its receive loop.
public final class ViewerSession {
    /// Roughly one receiver report per second (the RR cadence the sharer's
    /// congestion controller expects). Host-driven via `tick`, so this is a
    /// minimum spacing, not a wall-clock timer.
    public static let receiverReportIntervalNs: UInt64 = 1_000_000_000

    // MARK: Collaborators

    /// Capabilities this viewer advertises in its HELLO (NACK / receiver-report
    /// / FEC — the sharer-only bits are never set here).
    public let caps: ScreenShareCaps

    // MARK: Observation hooks (optional; for a host stats overlay)

    /// Called each time the session emits a PLI (keyframe request) — whether
    /// from the loss-recovery scheduler or a decode failure.
    public var onPLISent: (() -> Void)?
    /// Called each time the session emits a NACK (selective-retransmit request).
    public var onNACKSent: (() -> Void)?
    /// Called each time the session recovers a packet via FEC.
    public var onFECRecovered: (() -> Void)?

    private let decoder: VideoDecoding
    private let videoSink: VideoSink
    private let audioSink: AudioSink?
    private let onControlToSend: (Data) -> Void
    /// Optional raw-audio passthrough. When set, inbound audio RTP (PT 98/99)
    /// is handed to the host verbatim and the built-in Opus path is skipped —
    /// so a host with its own richer audio pipeline (macOS's `VoiceChannel`:
    /// per-SSRC jitter buffer, concealment, voice/system demux) owns decode.
    /// nil ⇒ the built-in `audioSink` path runs.
    private let onAudioDatagram: ((Data) -> Void)?

    // MARK: Video path

    private let depacketizer: MultiCodecDepacketizer
    private var nack: NACKScheduler
    private var rr = RRAccounting()

    // MARK: FEC path

    /// Receiver-side FEC state: a bounded ring of recent media packets plus
    /// briefly-buffered parity datagrams, solved into recovered packets. Only
    /// consulted while parity is actually flowing (`fecParityActive`).
    private var fecBuffer = FECGroupBuffer()
    /// True while parity is flowing: armed on the first 0x0D actually received,
    /// disarmed after `TransportTuning.fecParityIdleNs` without one. Bare `.fec`
    /// negotiation must NOT arm anything — the sharer always advertises the cap
    /// and its adaptive gate keeps parity off on clean links, so an
    /// always-armed viewer would pay the relaxed NACK timing for nothing.
    private var fecParityActive = false
    /// Clock reading of the most recent parity datagram, for the disarm timer.
    private var lastParityArrivalNs: UInt64 = 0
    /// Packets recovered via FEC since the last receiver report — carried in
    /// the extended RR's `fecRecovered` field so the sharer's FEC arm sees raw
    /// link loss even when parity is hiding all of it.
    private var fecRecoveredSinceReport = 0

    // MARK: Audio path

    private let audioDepacketizer = AudioRTPDepacketizer()
    /// One Opus decoder per audio SSRC (sharer voice 0, system audio 1, and any
    /// relayed viewer voices). Created lazily; each SSRC's stream is independent.
    private var audioDecoders: [UInt32: OpusVoiceDecoder] = [:]

    // MARK: Session state

    /// SSRC the sharer assigned this viewer in its HELLO_ACK (nil until then).
    private(set) public var assignedSSRC: UInt32?
    /// Capabilities the sharer advertised back in its HELLO_ACK.
    private(set) public var serverCaps: ScreenShareCaps = []
    /// True once the sharer said goodbye (SERVER_BYE / BYE) or declined us.
    private(set) public var isStopped = false
    /// True if the sharer parked us in its approval queue (HELLO_PENDING).
    private(set) public var isPendingApproval = false
    /// True if the sharer declined our request (HELLO_DENY).
    private(set) public var wasDenied = false

    /// Latest clock the host handed us (via `tick`), reused by `receiveRTP` so
    /// the NACK scheduler and reorder buffer age gaps in real time without a
    /// second clock argument on the hot path.
    private var nowNs: UInt64 = 0
    /// `serverUptimeNs` from the most recent PING, echoed in the next RR.
    private var lastPingTs: UInt64 = 0
    /// Clock reading when `lastPingTs` arrived, for the RR's `delaySincePingMs`.
    private var lastPingReceivedNs: UInt64 = 0
    /// Clock reading of the last RR we emitted, for the ~1 Hz cadence gate.
    private var lastReportNs: UInt64 = 0
    /// Whether at least one RR has been sent (so the first one fires promptly
    /// once a baseline exists, rather than waiting a full interval from 0).
    private var sentFirstReport = false

    /// - Parameters:
    ///   - caps: capabilities to advertise (NACK / receiver-report / FEC).
    ///   - decoder: the host's video decoder.
    ///   - videoSink: where decoded frames go.
    ///   - audioSink: where decoded audio goes (nil to drop audio). Ignored
    ///     when `onAudioDatagram` is set (the host owns audio decode then).
    ///   - onControlToSend: the host sends these bytes back to the sharer over
    ///     UDP (HELLO, NACK, PLI, receiver reports).
    ///   - onAudioDatagram: optional raw-audio passthrough. When provided,
    ///     inbound audio RTP (PT 98/99) is forwarded verbatim instead of being
    ///     decoded internally, so a host can plug in its own audio pipeline.
    public init(
        caps: ScreenShareCaps,
        decoder: VideoDecoding,
        videoSink: VideoSink,
        audioSink: AudioSink? = nil,
        onControlToSend: @escaping (Data) -> Void,
        onAudioDatagram: ((Data) -> Void)? = nil
    ) {
        self.caps = caps
        self.decoder = decoder
        self.videoSink = videoSink
        self.audioSink = audioSink
        self.onControlToSend = onControlToSend
        self.onAudioDatagram = onAudioDatagram

        // A deeper reorder window + time-based gap hold in NACK mode: a
        // retransmit lands ~1 RTT later, long after a 16-packet window would
        // have overflowed at video bitrate. Legacy sessions keep the shallow
        // count-based happy path.
        if caps.contains(.nack) {
            self.depacketizer = MultiCodecDepacketizer(
                reorderDepth: TransportTuning.nackReorderDepth,
                gapHoldNs: TransportTuning.reorderGapHoldNs
            )
        } else {
            self.depacketizer = MultiCodecDepacketizer()
        }
        self.nack = NACKScheduler()

        // Route decoded frames straight to the sink, and decode failures to a
        // PLI (keyframe request), regardless of NACK negotiation. Captured
        // directly (not via `self`) so the decoder's callbacks don't retain the
        // session; per `VideoDecoding`'s threading contract these fire on the
        // host's serialization context (synchronously for FFmpeg, after an
        // adapter hop for an async backend like VideoToolbox).
        decoder.onDecodedFrame = { videoSink.present($0) }
        decoder.onDecodeFailure = { [weak self] in
            onControlToSend(ScreenShareControlMessage.encode(.pli))
            self?.onPLISent?()
        }
    }

    // MARK: - Lifecycle

    /// Emit the extended HELLO advertising our capabilities. The host sends the
    /// returned bytes to the sharer; the sharer replies with a HELLO_ACK
    /// (handled in `receiveRTP`).
    public func start() {
        onControlToSend(ScreenShareControlMessage.encodeHello(caps: caps))
    }

    // MARK: - Inbound datagrams

    /// Demux one inbound UDP datagram: a non-RTP control byte, a video RTP
    /// packet, or an audio RTP packet. Safe to call with arbitrary bytes —
    /// malformed input is dropped.
    public func receiveRTP(_ data: Data) {
        guard !data.isEmpty else { return }

        if ScreenShareControlMessage.looksLikeControl(data) {
            handleControl(data)
            return
        }

        guard let (header, _) = RTPHeader.decode(from: data) else { return }
        switch header.payloadType {
        case RTPHeader.h264PayloadType, RTPHeader.hevcPayloadType:
            handleVideo(data, header: header)
        case RTPHeader.voicePayloadType, RTPHeader.systemAudioPayloadType:
            handleAudio(data)
        default:
            break  // Unknown PT — drop (forward compatible).
        }
    }

    // MARK: - Time-driven outputs

    /// Host calls this periodically with a monotonic clock. It advances the
    /// session clock, ages the NACK scheduler's gaps (re-NACK / PLI on cadence),
    /// and emits a receiver report about once a second.
    public func tick(nowNs: UInt64) {
        self.nowNs = nowNs

        if caps.contains(.nack) {
            emit(actions: nack.tick(nowNs: nowNs))
        }

        maybeDisarmFEC()
        maybeSendReceiverReport()
    }

    /// Disarm the FEC machinery once parity stops flowing: the sharer gated
    /// parity off (link recovered), so restore phase-1 NACK timing and drop the
    /// buffered media, and the FEC path costs nothing again until parity
    /// reappears.
    private func maybeDisarmFEC() {
        guard fecParityActive, nowNs &- lastParityArrivalNs > TransportTuning.fecParityIdleNs else {
            return
        }
        fecParityActive = false
        fecBuffer.reset()
        nack.setReorderTolerances(
            toleranceNs: NACKScheduler.defaultReorderToleranceNs,
            packetTolerance: NACKScheduler.defaultReorderPacketTolerance)
    }

    // MARK: - Control handling

    private func handleControl(_ data: Data) {
        guard let kind = ScreenShareControlMessage.decode(data) else { return }
        switch kind {
        case .helloAck:
            if let (ssrc, caps) = ScreenShareControlMessage.decodeHelloAckCaps(data) {
                assignedSSRC = ssrc
                serverCaps = caps
                isPendingApproval = false
            }
        case .helloPending:
            isPendingApproval = true
        case .helloDenied:
            wasDenied = true
            isStopped = true
        case .serverBye, .bye:
            isStopped = true
        case .ping:
            if let uptime = ScreenShareControlMessage.decodePing(data) {
                lastPingTs = uptime
                lastPingReceivedNs = nowNs
            }
        case .fec:
            handleFECParity(data)
        default:
            break  // keepalive / viewer-only bytes — nothing to do here.
        }
    }

    /// Handle one inbound FEC parity datagram (0x0D). Parity rides the control
    /// plane (`looksLikeControl` sees the 0x0D first byte), so it lands here,
    /// not on the video path. Bounds-checked decode (untrusted UDP), arm/refresh
    /// the FEC receive machinery (parity on the wire is the arming evidence),
    /// group solve, and the recovered-packet flow. No-op unless both sides
    /// negotiated `.fec`.
    private func handleFECParity(_ data: Data) {
        guard caps.contains(.fec), serverCaps.contains(.fec) else { return }
        guard let parity = ScreenShareControlMessage.decodeFEC(data) else { return }
        lastParityArrivalNs = nowNs
        if !fecParityActive {
            fecParityActive = true
            // Loosen the scheduler's reorder tolerances IN PLACE (gaps + RTT
            // estimate survive) so a recovery already in flight — up to N−1
            // trailing group members plus the parity away — isn't raced by a
            // NACK; NACK fires only for multi-loss groups FEC can't solve.
            nack.setReorderTolerances(
                toleranceNs: TransportTuning.fecSchedulerToleranceNs,
                packetTolerance: TransportTuning.fecSchedulerPacketTolerance)
        }
        let recovery = fecBuffer.noteParity(
            baseSeq: parity.baseSeq, count: parity.count, body: parity.body, nowNs: nowNs)
        if let recovery {
            processRecoveredPacket(recovery)
        }
    }

    // MARK: - Video handling

    private func handleVideo(_ data: Data, header: RTPHeader) {
        let seq = header.sequenceNumber

        // Feed the loss-recovery bookkeeping first (every received packet
        // counts, before reassembly), then drive NACK/PLI feedback.
        rr.observe(seq: seq)
        if caps.contains(.nack) {
            emit(actions: nack.observe(seq: seq, nowNs: nowNs))
        }

        // FEC: while parity is flowing, retain this packet for parity solves
        // and check whether it completed a group whose parity arrived first
        // (parity can outrun a reordered member). Gated on `fecParityActive`,
        // not bare negotiation, so a session that never sees parity pays zero
        // per-packet buffering cost. The recovered packet (an earlier seq in
        // the group) ingests before this wire packet — the reorder buffer
        // orders both by seq, so the interleave is harmless.
        if fecParityActive, let recovery = fecBuffer.noteMedia(seq: seq, packet: data, nowNs: nowNs) {
            processRecoveredPacket(recovery)
        }

        ingestVideo(data)
    }

    /// Shared tail for wire AND FEC-recovered packets — downstream of here a
    /// recovered packet is indistinguishable from a received one (reassembly,
    /// AU completion, decode).
    private func ingestVideo(_ packet: Data) {
        guard let au = depacketizer.ingest(packet, nowNs: nowNs) else { return }
        submit(au)
        // A gap fill (reorder completion or an FEC recovery) can unblock a run
        // of buffered AUs at once; `ingest` returns only the first and trickles
        // the rest one per later packet. Submit them all now instead — a viewer
        // has no reason to hold a ready frame, and an FEC-recovered tail packet
        // may have no trailing wire packet to trickle out on.
        for extra in depacketizer.drainReady() {
            submit(extra)
        }
    }

    /// Feed one FEC-recovered packet through the SAME path as a received one,
    /// with two accounting deltas: the receiver report counts it as *received*
    /// (recovered ≠ lost — residual loss drives the sharer's bitrate arm) while
    /// `fecRecoveredSinceReport` feeds the extended-RR field (raw loss drives
    /// the FEC arm); and the pending NACK gap is cleared via `noteRecovered`
    /// (not the straggler path, which would inject FEC latency into the RTT
    /// EMA — `noteRecovered` also advances the highest-seen cursor past a
    /// recovered tail-of-batch marker so the next batch opens no phantom gap).
    private func processRecoveredPacket(_ recovery: FECGroupBuffer.Recovery) {
        fecRecoveredSinceReport += 1
        onFECRecovered?()
        if caps.contains(.receiverReport) {
            rr.observe(seq: recovery.seq)
        }
        nack.noteRecovered(seq: recovery.seq, nowNs: nowNs)
        ingestVideo(recovery.packet)
    }

    /// Submit one access unit to the decoder. Decoded frames come back through
    /// `onDecodedFrame` → the sink (wired in `init`); a decode failure comes
    /// back through `onDecodeFailure` → a PLI. For a synchronous decoder both
    /// happen inside this call; for an async one, later.
    private func submit(_ au: VideoAccessUnit) {
        decoder.decode(accessUnit: au.avcc, codec: au.codec, isKeyframe: au.containsIDR)
    }

    // MARK: - Audio handling

    private func handleAudio(_ data: Data) {
        // Host owns audio decode (e.g. macOS's VoiceChannel) — hand it the raw
        // datagram and skip the built-in Opus path entirely. The host demuxes
        // PT 98 (voice) vs 99 (system) itself.
        if let onAudioDatagram {
            onAudioDatagram(data)
            return
        }
        guard let audioSink else { return }
        guard let parsed = audioDepacketizer.unpack(data) else { return }
        let decoder: OpusVoiceDecoder
        if let existing = audioDecoders[parsed.ssrc] {
            decoder = existing
        } else {
            guard let fresh = try? OpusVoiceDecoder() else { return }
            audioDecoders[parsed.ssrc] = fresh
            decoder = fresh
        }
        guard let pcm = try? decoder.decode(au: parsed.au), !pcm.isEmpty else { return }
        audioSink.play(pcm)
    }

    // MARK: - Feedback emission

    /// Translate scheduler actions into wire bytes and hand them to the host.
    private func emit(actions: [NACKAction]) {
        for action in actions {
            switch action {
            case .sendNACK(let seqs):
                let entries = NACKScheduler.packFCI(seqs)
                guard !entries.isEmpty else { continue }
                onControlToSend(ScreenShareControlMessage.encodeNACK(entries))
                onNACKSent?()
            case .sendPLI:
                onControlToSend(ScreenShareControlMessage.encode(.pli))
                onPLISent?()
            }
        }
    }

    /// Build and emit a receiver report if we advertised the capability, have a
    /// baseline, and the ~1 Hz cadence has elapsed.
    private func maybeSendReceiverReport() {
        guard caps.contains(.receiverReport), rr.hasBaseline else { return }
        let due = !sentFirstReport || nowNs &- lastReportNs >= Self.receiverReportIntervalNs
        guard due else { return }
        guard let (fracLostQ8, extHighestSeq) = rr.makeReport() else { return }

        let delayMs = lastPingTs == 0 ? 0 : UInt16(min(UInt64(UInt16.max), (nowNs &- lastPingReceivedNs) / 1_000_000))
        let report = ReceiverReport(
            fracLostQ8: fracLostQ8,
            extHighestSeq: extHighestSeq,
            jitterTicks: 0,
            lastPingTs: lastPingTs,
            delaySincePingMs: delayMs,
            fecRecovered: UInt16(clamping: fecRecoveredSinceReport),
            nackRecovered: UInt16(min(Int(UInt16.max), nack.drainNackRecovered()))
        )
        // The extended (recovery-field) form only when both sides negotiated
        // FEC; otherwise the legacy 20-byte layout every sharer already parses.
        let includeRecovery = caps.contains(.fec) && serverCaps.contains(.fec)
        onControlToSend(
            ScreenShareControlMessage.encodeReceiverReport(report, includeRecoveryFields: includeRecovery)
        )
        lastReportNs = nowNs
        sentFirstReport = true
        fecRecoveredSinceReport = 0
    }
}
