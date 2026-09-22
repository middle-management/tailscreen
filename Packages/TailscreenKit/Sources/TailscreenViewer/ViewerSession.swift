import Foundation
import TailscreenAudio
import TailscreenProtocol

/// Why a viewer session is over. The wire-side causes (`sharerStopped`,
/// `deniedOrKicked`) are set by `ViewerSession` itself from the control bytes;
/// the transport-side causes (`timedOut`, `connectionLost`) are diagnosed by
/// whatever owns the socket, since the session owns no clock source and no
/// socket. One enum for all four so every host maps the same raw values onto
/// its presentation — the macOS app's former app-local `ViewerPeerCloseReason`
/// used these exact cases and raw values.
///
/// Deny and kick are deliberately ONE case: both arrive as the same HELLO_DENY
/// byte, and the wire carries no distinction. The split the UI wants ("declined"
/// at the approval placard vs "disconnected by sharer" mid-watch) is host-side
/// context — whether an SSRC had been assigned when the byte landed.
public enum ViewerCloseReason: String, Sendable, Equatable {
    /// The sharer ended the session (SERVER_BYE / BYE).
    case sharerStopped
    /// Nothing arrived for longer than the idle threshold.
    case timedOut
    /// The receive path died on repeated socket errors.
    case connectionLost
    /// The sharer sent HELLO_DENY — a declined approval, or a mid-session kick.
    case deniedOrKicked
}

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

    /// Minimum spacing between keyframe requests while waiting for the FIRST
    /// keyframe (see `maybeRequestKeyframe`). One second, chosen against the
    /// sharer's own PLI-driven keyframe cadence of roughly two: fast enough that
    /// a lost admission keyframe costs about a second rather than the session,
    /// slow enough that a keyframe already on its way doesn't collect a queue of
    /// duplicate requests behind it. Stops entirely at the first keyframe.
    public static let keyframeRequestIntervalNs: UInt64 = 1_000_000_000

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

    /// Where this session records its handshake for later troubleshooting.
    ///
    /// Host-installed and optional: nil means no recording, which is the
    /// stable-release default (``DiagnosticsPreference``). Named `recorder`
    /// rather than `diagnostics` because ``ViewerSession/diagnostics`` is
    /// already taken by the live counter snapshot the stats overlay reads —
    /// a different thing entirely, kept for a different purpose.
    ///
    /// Three kinds of thing are recorded here, and the per-packet paths are
    /// deliberately not one of them (`receiveRTP` runs hundreds of times a
    /// second): the handshake and the terminal transitions; the media
    /// milestones — the first decoded frame, a frame-size change, a decode
    /// failure and each rung of the recovery ladder, up to the stall; and one
    /// `transport.summary` per ``DiagnosticsTransportSampler`` window,
    /// rolling up the counters in ``ViewerSession/diagnostics`` into a row a
    /// reader can diff against the sharer's summary for the same window.
    /// Recording these in the session rather than in each host is what makes
    /// a macOS, GTK and WinUI viewer bundle say the same things.
    public var recorder: DiagnosticsRecorder?

    /// Cadence for `transport.summary`. Ticks from `tick(nowNs:)`, and only
    /// once admitted — before the HELLO_ACK there is no media to roll up.
    private var transportSampler = DiagnosticsTransportSampler()
    /// The counters as they stood when the last summary was recorded, so each
    /// summary carries this window's deltas rather than session totals: a
    /// reader wants "no frames in these five seconds", and a running total
    /// makes them subtract two rows to find it.
    private var lastSummarizedDiagnostics = Diagnostics()
    /// Session clock at the HELLO_ACK, for `decode.first_frame`'s time-to-
    /// first-frame; 0 before admission.
    private var admittedAtNs: UInt64 = 0
    /// Size of the most recently presented frame, for `render.size.changed`.
    private var lastFrameSize: (width: Int, height: Int)?
    /// True while a run of decode failures is open — set on the first failure
    /// after a success, cleared by the next decoded frame — so `decode.failed`
    /// is recorded once per episode rather than once per frame. A wedged
    /// decoder fails at frame rate, and per-frame events would push the
    /// handshake out of the ring in seconds.
    private var decodeFailureEpisodeOpen = false

    // MARK: Decode-recovery ladder opt-in (optional; host cooperation)

    /// Installing EITHER callback below opts the session into the shared
    /// decode-failure escalation ladder (`DecodeRecovery`, the same
    /// 5/30/90/300-consecutive-failure policy the macOS viewer runs inside its
    /// own `VideoDecoder`): per-frame decode failures are then counted
    /// consecutively and answered per rung — a PLI at `.requestKeyframe`,
    /// `onDecoderResetNeeded` (plus a PLI, since a fresh IDR is what un-wedges
    /// a rebuilt decoder) at `.recreateSession`, and `onDecodeFatal` at
    /// `.surfaceError` — each rung at most once per failing episode, with the
    /// counter and latches reset by the next successfully decoded frame.
    /// (`.signalDegraded` is latched for ordering but currently has no
    /// portable surface.) With BOTH left nil the session keeps today's flat
    /// path: one PLI per decode failure, no escalation — so a host that
    /// doesn't opt in sees no behavior change.
    ///
    /// Fired synchronously on the host's serialization context (the same one
    /// `receiveRTP` runs on), like every other decode-path callback here.

    /// The `.recreateSession` rung: the decoder looks wedged (30 consecutive
    /// failures despite a keyframe request), so the host should reset/recreate
    /// its concrete decoder (e.g. `FFmpegVideoDecoder.reset()`).
    public var onDecoderResetNeeded: (() -> Void)?
    /// The `.surfaceError` rung: decoding has been failing for hundreds of
    /// consecutive frames despite a keyframe request and a decoder reset —
    /// surface a user-visible session error.
    public var onDecodeFatal: (() -> Void)?

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

    /// Depacketize + per-SSRC Opus decode (sharer voice 0, system audio 1, and
    /// any relayed viewer voices).
    ///
    /// Shared with the sharer hosts rather than kept here: a Linux or Windows
    /// sharer needs the identical demux to hear its viewers, and the inline
    /// version this replaced was the reason those hosts could be heard but
    /// could not hear. Bounded decoder map, which the inline version was not —
    /// and loss-resilient (Opus-PLC gap concealment, decoder-failure cooldown,
    /// adaptive jitter target), composed from the same `VoiceReceiveDecisions`
    /// the macOS `VoiceChannel` pipeline uses; the session threads its `tick`
    /// clock into `ingest(_:nowNs:)` so those decisions age deterministically.
    private let voiceDownlink = VoiceDownlink()

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
    /// Why the session is over, nil while it is live. First cause wins: a
    /// HELLO_DENY is always chased by a SERVER_BYE (the deny protocol), and the
    /// trailing bye must not relabel a deny as an ordinary stop. Only the
    /// wire-side causes are set here; the transport-side ones (`timedOut`,
    /// `connectionLost`) belong to whoever owns the socket.
    private(set) public var closeReason: ViewerCloseReason?

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
    /// Clock reading of the last keyframe request sent while waiting for a first
    /// keyframe. See `maybeRequestKeyframe`.
    private var lastKeyframeRequestNs: UInt64 = 0
    /// Whether a pre-keyframe request has been sent, so the first one fires on
    /// the next tick after admission rather than an interval later.
    private var sentKeyframeRequest = false

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

        // Route decoded frames straight to the sink, and decode failures to
        // recovery (a flat PLI, or the escalation ladder once a host installs
        // `onDecoderResetNeeded`/`onDecodeFatal`), regardless of NACK
        // negotiation. The sink is captured directly (not via `self`) so the
        // frame callback doesn't retain the session; per `VideoDecoding`'s
        // threading contract these fire on the host's serialization context
        // (synchronously for FFmpeg, after an adapter hop for an async backend
        // like VideoToolbox).
        decoder.onDecodedFrame = { [weak self] frame in
            self?.noteDecodedFrame(frame)
            videoSink.present(frame)
        }
        decoder.onDecodeFailure = { [weak self] in
            self?.handleDecodeFailure()
        }

        // Every voice, mixed by the sink. The SSRC the downlink tags each
        // buffer with is dropped here on purpose: `AudioSink` is one device,
        // and a viewer has nowhere to route "this one is system audio" that a
        // person would notice. macOS, which does — a separate player node for
        // system audio — takes `onAudioDatagram` and never reaches this path.
        // Captured directly rather than via `self` so the downlink's callback
        // does not retain the session.
        if let audioSink {
            voiceDownlink.onPCM = { _, pcm in audioSink.play(pcm) }
        }
    }

    // MARK: - Lifecycle

    /// Emit the extended HELLO advertising our capabilities. The host sends the
    /// returned bytes to the sharer; the sharer replies with a HELLO_ACK
    /// (handled in `receiveRTP`).
    public func start() {
        recorder?.record(.helloSent, role: .viewer, fields: ["caps": .string(caps.diagnosticDescription)])
        onControlToSend(ScreenShareControlMessage.encodeHello(caps: caps))
    }

    // MARK: - Inbound datagrams

    /// Demux one inbound UDP datagram: a non-RTP control byte, a video RTP
    /// packet, or an audio RTP packet. Safe to call with arbitrary bytes —
    /// malformed input is dropped.
    public func receiveRTP(_ data: Data) {
        guard !data.isEmpty else { return }

        if ScreenShareControlMessage.looksLikeControl(data) {
            controlPacketsReceived += 1
            handleControl(data)
            return
        }

        guard let (header, _) = RTPHeader.decode(from: data) else {
            undecodablePackets += 1
            return
        }
        switch header.payloadType {
        case RTPHeader.h264PayloadType, RTPHeader.hevcPayloadType:
            videoPacketsReceived += 1
            handleVideo(data, header: header)
        case RTPHeader.voicePayloadType, RTPHeader.systemAudioPayloadType:
            audioPacketsReceived += 1
            handleAudio(data)
        default:
            unknownPayloadPackets += 1  // Unknown PT — drop (forward compatible).
        }
    }

    // MARK: - Diagnostics

    /// Inbound/decode tallies, for the "admitted but the window is blank" case.
    ///
    /// Every failure between admission and a first frame is otherwise SILENT —
    /// unknown payload types, RTP that never reassembles, the keyframe gate
    /// below, and a decoder that cannot be built are all a bare `return` or a
    /// PLI. That left a real Mac→Windows blank-viewer report with no way to tell
    /// "no packets arrived" from "packets arrived and nothing could be done with
    /// them", which are opposite bugs. These counters are the cheapest thing
    /// that separates them; `TsnetTransport` logs a snapshot while a session is
    /// admitted with no frames yet.
    public struct Diagnostics: Sendable {
        public var videoPacketsReceived = 0
        public var audioPacketsReceived = 0
        public var controlPacketsReceived = 0
        public var unknownPayloadPackets = 0
        public var undecodablePackets = 0
        public var accessUnitsAssembled = 0
        public var preKeyframeDrops = 0
        public var framesDecoded = 0
        public var decodeFailures = 0
        public var seenKeyframe = false
        /// Access units that assembled and were discarded as torn. The
        /// counterpart to `accessUnitsAssembled`, which counts only the ones
        /// that survived: `aus` standing still with `tornAUs` climbing is a
        /// wholly different fault from both standing still, and until this
        /// existed the two were indistinguishable.
        public var tornAUs = 0
        /// Reorder gaps abandoned as loss.
        public var skippedGaps = 0
        /// Keyframe requests sent. If this climbs while `keyframe=false`, the
        /// viewer is asking and not being answered — which points at the sharer
        /// or the path, not at anything here.
        public var keyframeRequests = 0
        /// Codec of the first video packet seen, from its RTP payload type.
        /// nil until video arrives. Named because "does this build have that
        /// decoder" cost a round of guessing, and the log never said.
        public var codec: VideoCodec?
        /// Smoothed RTT from the NACK scheduler, ms. 0 before the first sample.
        public var rttMs: Int = 0
        /// NACKs (selective-retransmit requests) sent.
        public var nacksSent = 0
        /// Packets recovered via FEC parity, over the session.
        public var fecRecovered = 0
        /// The `fracLostQ8` of the most recent receiver report this viewer
        /// sent — its own residual-loss reading, as the sharer sees it. 0
        /// before the first report.
        public var lastReportedLossQ8: Int = 0
        /// True while parity is flowing and the FEC receive path is armed.
        public var fecActive = false

        /// One line, for a log. Deliberately terse — it is printed on a cadence.
        public var summary: String {
            "video=\(videoPacketsReceived) audio=\(audioPacketsReceived) "
                + "ctrl=\(controlPacketsReceived) unknownPT=\(unknownPayloadPackets) "
                + "badRTP=\(undecodablePackets) aus=\(accessUnitsAssembled) "
                + "tornAUs=\(tornAUs) skippedGaps=\(skippedGaps) "
                + "preKeyframeDrops=\(preKeyframeDrops) keyframe=\(seenKeyframe) "
                + "kfReq=\(keyframeRequests) codec=\(codec?.rawValue ?? "none") "
                + "rtt=\(rttMs)ms "
                + "decoded=\(framesDecoded) decodeFailures=\(decodeFailures)"
        }

        /// The `transport.summary` row for one window: this snapshot's
        /// counters minus `previous`'s, plus the gauges (RTT, last reported
        /// loss, codec, keyframe, FEC state) as they stand now.
        ///
        /// Deltas, not totals, for every counter: the question a summary
        /// answers is "what happened in these five seconds", and a running
        /// total makes a reader subtract two rows to find out. `frames_total`
        /// is the one cumulative field, because "still zero" is the blank-
        /// viewer question and it should not need the previous row either.
        ///
        /// Pure — a struct method over two values — so the field set is
        /// pinned by a test with no session behind it, and the session's
        /// only job is to remember the previous snapshot.
        public func transportSummaryFields(
            since previous: Diagnostics, windowNs: UInt64
        ) -> [String: DiagnosticValue] {
            [
                "window_ms": DiagnosticValue(windowNs / 1_000_000),
                "video_packets": DiagnosticValue(videoPacketsReceived - previous.videoPacketsReceived),
                "audio_packets": DiagnosticValue(audioPacketsReceived - previous.audioPacketsReceived),
                "control_packets": DiagnosticValue(controlPacketsReceived - previous.controlPacketsReceived),
                "bad_rtp": DiagnosticValue(undecodablePackets - previous.undecodablePackets),
                "aus": DiagnosticValue(accessUnitsAssembled - previous.accessUnitsAssembled),
                "torn_aus": DiagnosticValue(tornAUs - previous.tornAUs),
                "skipped_gaps": DiagnosticValue(skippedGaps - previous.skippedGaps),
                "pre_keyframe_drops": DiagnosticValue(preKeyframeDrops - previous.preKeyframeDrops),
                "frames": DiagnosticValue(framesDecoded - previous.framesDecoded),
                "frames_total": DiagnosticValue(framesDecoded),
                "decode_failures": DiagnosticValue(decodeFailures - previous.decodeFailures),
                "plis_sent": DiagnosticValue(keyframeRequests - previous.keyframeRequests),
                "nacks_sent": DiagnosticValue(nacksSent - previous.nacksSent),
                "fec_recovered": DiagnosticValue(fecRecovered - previous.fecRecovered),
                "loss_q8": DiagnosticValue(lastReportedLossQ8),
                "rtt_ms": DiagnosticValue(rttMs),
                "codec": .string(codec?.rawValue ?? "none"),
                "keyframe": .bool(seenKeyframe),
                "fec_active": .bool(fecActive)
            ]
        }
    }

    public var diagnostics: Diagnostics {
        var snapshot = Diagnostics()
        snapshot.videoPacketsReceived = videoPacketsReceived
        snapshot.audioPacketsReceived = audioPacketsReceived
        snapshot.controlPacketsReceived = controlPacketsReceived
        snapshot.unknownPayloadPackets = unknownPayloadPackets
        snapshot.undecodablePackets = undecodablePackets
        snapshot.accessUnitsAssembled = accessUnitsAssembled
        snapshot.preKeyframeDrops = preKeyframeDropCount
        snapshot.framesDecoded = framesDecoded
        snapshot.decodeFailures = decodeFailures
        snapshot.seenKeyframe = seenKeyframe
        snapshot.tornAUs = depacketizer.tornAUCount
        snapshot.skippedGaps = depacketizer.skippedGapCount
        snapshot.keyframeRequests = keyframeRequestsSent
        snapshot.codec = observedCodec
        snapshot.rttMs = Int(nack.rttEstimateNs / 1_000_000)
        snapshot.nacksSent = nacksSent
        snapshot.fecRecovered = fecRecoveredTotal
        snapshot.lastReportedLossQ8 = lastReportedLossQ8
        snapshot.fecActive = fecParityActive
        return snapshot
    }

    private var videoPacketsReceived = 0
    private var audioPacketsReceived = 0
    private var controlPacketsReceived = 0
    private var unknownPayloadPackets = 0
    private var undecodablePackets = 0
    private var accessUnitsAssembled = 0
    private var framesDecoded = 0
    private var decodeFailures = 0
    private var nacksSent = 0
    private var fecRecoveredTotal = 0
    private var lastReportedLossQ8 = 0
    /// Every PLI this session has sent, from all three senders (the pre-keyframe
    /// retry, a decode failure, and the NACK scheduler giving up on a gap).
    private var keyframeRequestsSent = 0
    /// Codec of the first video packet, read off its RTP payload type.
    private var observedCodec: VideoCodec?

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
        maybeRequestKeyframe()
        maybeSendReceiverReport()
        maybeRecordTransportSummary()
    }

    /// One `transport.summary` per sampler window, once admitted.
    ///
    /// Gated on `assignedSSRC` for the same reason `maybeRequestKeyframe`
    /// is: before the HELLO_ACK there is no media to roll up, and a viewer
    /// parked on the approval prompt for a minute would otherwise record
    /// twelve rows of zeros ahead of the handshake that matters. The sampler
    /// is only ticked once admitted too, so the first window is measured
    /// from admission rather than from `start()`.
    private func maybeRecordTransportSummary() {
        guard assignedSSRC != nil, let recorder else { return }
        guard let windowNs = transportSampler.windowClosed(nowNs: nowNs) else { return }
        let now = diagnostics
        let previous = lastSummarizedDiagnostics
        lastSummarizedDiagnostics = now
        recorder.record(
            .transportSummary,
            role: .viewer,
            fields: now.transportSummaryFields(since: previous, windowNs: windowNs)
                .merging(["ssrc": DiagnosticValue(assignedSSRC ?? 0)]) { current, _ in current })
    }

    /// Ask for a keyframe, on a cadence, while admitted with none yet.
    ///
    /// The sharer forces a keyframe when a viewer joins (and again when a
    /// pending viewer is approved), but that is a ONE-SHOT: if the IDR is lost
    /// or torn in transit, nothing on either side asks again, and this viewer is
    /// blank for the rest of the session on an otherwise perfect link. Neither
    /// existing PLI path covers it — the decode-failure PLI can't fire because
    /// `submit` gates P-frames before the decoder ever sees them, and the NACK
    /// scheduler only PLIs on a gap it gave up on, so a clean link produces
    /// nothing to recover from.
    ///
    /// A real Mac→Windows session showed exactly this: 112 access units
    /// assembled in three seconds, every one of them a P-frame
    /// (`aus == preKeyframeDrops`, `keyframe=false`), because the admission
    /// keyframe was shredded while the receive loop was still overflowing its
    /// socket and no second request ever went out.
    ///
    /// Gated on `assignedSSRC` — before the HELLO_ACK there is nothing admitted
    /// to serve the request, and a PLI sent while parked at the approval prompt
    /// would ask a sharer who hasn't let us in yet. Stops at the first keyframe,
    /// after which the ordinary decode-failure and NACK paths own recovery.
    private func maybeRequestKeyframe() {
        guard !seenKeyframe, assignedSSRC != nil else { return }
        let elapsed = nowNs &- lastKeyframeRequestNs
        guard !sentKeyframeRequest || elapsed >= Self.keyframeRequestIntervalNs else { return }
        lastKeyframeRequestNs = nowNs
        sentKeyframeRequest = true
        keyframeRequestsSent += 1
        onControlToSend(ScreenShareControlMessage.encode(.pli))
        onPLISent?()
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
                // Recorded before the assignment so a re-ack (a reconnect
                // onto the same session) still shows both values.
                //
                // `ssrc` is what pairs this event with the sharer's
                // `hello.ack.sent`, which is how `DiagnosticsMerge` aligns the
                // two machines' clocks. It is the one identifier both ends
                // already agree on, so nothing had to be added to the wire to
                // make the merge work — see that type's doc comment.
                recorder?.record(
                    .helloAckReceived,
                    role: .viewer,
                    fields: [
                        "ssrc": DiagnosticValue(ssrc),
                        "server_caps": .string(caps.diagnosticDescription),
                        "was_pending": .bool(isPendingApproval)
                    ])
                if assignedSSRC == nil { admittedAtNs = nowNs }
                assignedSSRC = ssrc
                serverCaps = caps
                isPendingApproval = false
            }
        case .helloPending:
            // Only on the transition. A sharer re-sends HELLO_PENDING for
            // every keepalive while the viewer sits on the approval prompt,
            // and an event per keepalive would push the rest of the session
            // out of the ring.
            if !isPendingApproval {
                recorder?.record(.helloPendingReceived, role: .viewer)
            }
            isPendingApproval = true
        case .helloDenied:
            recorder?.record(
                .helloDeniedReceived,
                role: .viewer,
                fields: ["was_pending": .bool(isPendingApproval)])
            wasDenied = true
            isStopped = true
            if closeReason == nil { closeReason = .deniedOrKicked }
        case .serverBye, .bye:
            // `closeReason == nil` is the "this is the first cause" test the
            // line below already makes — recording inside it keeps the
            // SERVER_BYE that chases a HELLO_DENY from writing a second,
            // contradictory ending into the timeline.
            if closeReason == nil {
                recorder?.record(.serverByeReceived, role: .viewer)
            }
            isStopped = true
            // First cause wins — the SERVER_BYE that chases a HELLO_DENY must
            // not relabel the deny as an ordinary sharer stop.
            if closeReason == nil { closeReason = .sharerStopped }
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
        // Which codec the sharer actually chose, off the payload type. Recorded
        // on the first packet because the log never said, and "is the HEVC
        // decoder present in this build" was guessed at for two rounds.
        if observedCodec == nil {
            observedCodec = header.payloadType == RTPHeader.hevcPayloadType ? .hevc : .h264
        }

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
        fecRecoveredTotal += 1
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
    ///
    /// GATED until the first keyframe: feeding P-frame slices to a decoder
    /// that has never seen parameter sets is guaranteed failure, and libavcodec
    /// says so loudly — the real Mac→Windows session logged two lines
    /// ("PPS id out of range" / "Skipping invalid undecodable NALU") for every
    /// pre-keyframe frame, ~2 s of spam per keyframe interval. The Mac
    /// `VideoDecoder` has always dropped these silently; the portable path now
    /// matches, counting instead of logging so time-to-first-frame problems
    /// stay measurable (`preKeyframeDropCount`, surfaced via `onVideoStats`
    /// consumers that already poll).
    private func submit(_ au: VideoAccessUnit) {
        accessUnitsAssembled += 1
        if !seenKeyframe {
            guard au.containsIDR else {
                preKeyframeDropCount += 1
                return
            }
            seenKeyframe = true
        }
        decoder.decode(accessUnit: au.avcc, codec: au.codec, isKeyframe: au.containsIDR)
    }

    /// True once a keyframe has been submitted; P-frames before it are
    /// undecodable by construction and are counted, not decoded.
    private var seenKeyframe = false
    /// Dropped-before-first-keyframe count — the visibility a silent drop
    /// would otherwise cost (a large value here means keyframes are being
    /// torn in transit; look at NACK/FEC recovery, not the decoder).
    public private(set) var preKeyframeDropCount = 0

    /// Test-only: open the keyframe gate without a real IDR, so suites that
    /// exercise transport mechanics (gap→NACK, FEC recovery) with P-frame-only
    /// streams keep asserting on frame counts. Internal via @testable, per the
    /// package convention.
    func markKeyframeSeenForTesting() { seenKeyframe = true }

    // MARK: - Decode failure recovery

    /// Consecutive per-frame decode failures in the current failing episode.
    /// Only consulted in ladder mode; reset by the first successful frame.
    private var consecutiveDecodeFailures = 0
    /// Rungs already fired this episode — the `DecodeRecovery` latch set,
    /// cleared with the counter on the first successful frame.
    private var firedDecodeRecoveryRungs: Set<DecodeRecoveryAction> = []

    /// One per-frame decode failure, reported by the decoder. With no ladder
    /// callbacks installed this is exactly the historical flat path (one PLI
    /// per failure); with a host opted in, failures are counted consecutively
    /// and answered per `DecodeRecovery` rung instead — the same policy the
    /// macOS `VideoDecoder` applies internally, so all three hosts escalate
    /// identically.
    private func handleDecodeFailure() {
        decodeFailures += 1
        // Once per episode, not per frame — see `decodeFailureEpisodeOpen`.
        // The total rides along so the row still says how bad it has been.
        if !decodeFailureEpisodeOpen {
            decodeFailureEpisodeOpen = true
            recorder?.record(
                .decodeFailed,
                role: .viewer,
                fields: [
                    "codec": .string(observedCodec?.rawValue ?? "none"),
                    "failures_total": DiagnosticValue(decodeFailures),
                    "frames_total": DiagnosticValue(framesDecoded)
                ])
        }
        guard onDecoderResetNeeded != nil || onDecodeFatal != nil else {
            sendDecodeRecoveryPLI()
            return
        }
        consecutiveDecodeFailures += 1
        let decision = DecodeRecovery.action(
            consecutiveFailures: consecutiveDecodeFailures,
            alreadyFired: firedDecodeRecoveryRungs)
        guard let action = decision else { return }
        firedDecodeRecoveryRungs.insert(action)
        // Each rung fires at most once per episode (the latch above), so this
        // is at most four events per failing run. `video.stalled` is the last
        // rung under its own name: it is the event a reader searches for, and
        // the one that carries `error` severity.
        recorder?.record(
            .decodeRecoveryAction,
            role: .viewer,
            fields: [
                "action": .string(action.diagnosticName),
                "consecutive_failures": DiagnosticValue(consecutiveDecodeFailures)
            ])
        switch action {
        case .requestKeyframe:
            sendDecodeRecoveryPLI()
        case .recreateSession:
            // Reset the host's decoder, then ask for the fresh IDR the
            // rebuilt decoder needs (in-band parameter sets ride keyframes) —
            // the same PLI the mac client sends on this rung.
            onDecoderResetNeeded?()
            sendDecodeRecoveryPLI()
        case .signalDegraded:
            // Latched for rung ordering; no portable surface yet (macOS
            // renders its degraded badge host-side).
            break
        case .surfaceError:
            recorder?.record(
                .videoStalled,
                role: .viewer,
                fields: [
                    "consecutive_failures": DiagnosticValue(consecutiveDecodeFailures),
                    "codec": .string(observedCodec?.rawValue ?? "none")
                ])
            onDecodeFatal?()
        }
    }

    /// A successfully decoded frame: reset the ladder's counter and latches so
    /// the next failing run starts a fresh episode (mirrors the mac decoder's
    /// success-path reset), and record the two milestones a frame can be —
    /// the first one, and one of a different size than the last.
    private func noteDecodedFrame(_ frame: any DecodedFrame) {
        framesDecoded += 1
        consecutiveDecodeFailures = 0
        decodeFailureEpisodeOpen = false
        if !firedDecodeRecoveryRungs.isEmpty {
            firedDecodeRecoveryRungs.removeAll()
        }
        if framesDecoded == 1 {
            // Time-to-first-frame from admission is the number that separates
            // "slow to start" from "never started", and the drops and requests
            // beside it say what the wait was spent on.
            recorder?.record(
                .decodeFirstFrame,
                role: .viewer,
                fields: [
                    "size": .string("\(frame.width)x\(frame.height)"),
                    "codec": .string(observedCodec?.rawValue ?? "none"),
                    "ms_since_ack": DiagnosticValue(
                        admittedAtNs == 0 ? 0 : (nowNs &- admittedAtNs) / 1_000_000),
                    "pre_keyframe_drops": DiagnosticValue(preKeyframeDropCount),
                    "keyframe_requests": DiagnosticValue(keyframeRequestsSent)
                ])
        }
        if let last = lastFrameSize, last.width != frame.width || last.height != frame.height {
            // A resolution change mid-share is the sharer's encoder re-anchoring
            // (a display change, a window resize under the portal backend) and
            // is the usual explanation for a bitrate step a reader would
            // otherwise attribute to loss.
            recorder?.record(
                .renderSizeChanged,
                role: .viewer,
                fields: [
                    "from": .string("\(last.width)x\(last.height)"),
                    "to": .string("\(frame.width)x\(frame.height)")
                ])
        }
        lastFrameSize = (frame.width, frame.height)
    }

    /// A decode-recovery keyframe request (both the flat path and the ladder's
    /// PLI-bearing rungs), counted like every other PLI this session sends.
    private func sendDecodeRecoveryPLI() {
        keyframeRequestsSent += 1
        onControlToSend(ScreenShareControlMessage.encode(.pli))
        onPLISent?()
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
        guard audioSink != nil else { return }
        voiceDownlink.ingest(data, nowNs: nowNs)
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
                nacksSent += 1
                onNACKSent?()
            case .sendPLI:
                keyframeRequestsSent += 1
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
        lastReportedLossQ8 = Int(fracLostQ8)
    }
}
