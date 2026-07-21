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
/// `AudioRTPDepacketizer`, `ScreenShareControlMessage`) and `TailscreenAudio`
/// (`OpusVoiceDecoder`), so nothing here is macOS-specific.
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

    private let decoder: VideoDecoding
    private let videoSink: VideoSink
    private let audioSink: AudioSink?
    private let onControlToSend: (Data) -> Void

    // MARK: Video path

    private let depacketizer: MultiCodecDepacketizer
    private var nack: NACKScheduler
    private var rr = RRAccounting()

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
    ///   - audioSink: where decoded audio goes (nil to drop audio).
    ///   - onControlToSend: the host sends these bytes back to the sharer over
    ///     UDP (HELLO, NACK, PLI, receiver reports).
    public init(
        caps: ScreenShareCaps,
        decoder: VideoDecoding,
        videoSink: VideoSink,
        audioSink: AudioSink? = nil,
        onControlToSend: @escaping (Data) -> Void
    ) {
        self.caps = caps
        self.decoder = decoder
        self.videoSink = videoSink
        self.audioSink = audioSink
        self.onControlToSend = onControlToSend

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
        case RTPHeader.aacPayloadType, RTPHeader.systemAudioPayloadType:
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

        maybeSendReceiverReport()
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
        default:
            break  // keepalive / viewer-only bytes — nothing to do here.
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

        guard let au = depacketizer.ingest(data, nowNs: nowNs) else { return }
        decodeAndPresent(au)
    }

    private func decodeAndPresent(_ au: VideoAccessUnit) {
        do {
            let frames = try decoder.decode(accessUnit: au.avcc, codec: au.codec, isKeyframe: au.containsIDR)
            for frame in frames {
                videoSink.present(frame)
            }
        } catch {
            // Decode failed — ask for a fresh keyframe so the stream can
            // recover, regardless of NACK negotiation.
            onControlToSend(ScreenShareControlMessage.encode(.pli))
        }
    }

    // MARK: - Audio handling

    private func handleAudio(_ data: Data) {
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
            case .sendPLI:
                onControlToSend(ScreenShareControlMessage.encode(.pli))
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
            fecRecovered: 0,
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
    }
}

// TODO(fec): FEC ingest (FECGroupBuffer + FECCodec.recover in front of the
// depacketizer, arming on the first 0x0D parity datagram, and the FEC-mode
// NACKScheduler tolerances via setReorderTolerances) is deferred to a
// follow-up. The RR already carries the negotiated recovery-field layout, and
// serverCaps records the sharer's .fec advertisement, so wiring the buffer in
// is additive — no wire or handshake change. Until then a viewer degrades to
// NACK-or-PLI, exactly like a peer that never advertised .fec.
