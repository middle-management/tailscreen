import AppKit
import CoreVideo
import Foundation
import TailscaleKit
import TailscreenViewer
import os

/// Screen-share viewer.
///
/// Both the client and server use the new `PacketListener` (UDP via tsnet's
/// `ListenPacket`). The Dial-UDP path through `OutgoingConnection` is
/// unsuitable here: libtailscale's existing `TsnetDial` uses a SOCK_STREAM
/// socketpair under the hood, which streams bytes without preserving
/// datagram boundaries — multiple writes can coalesce, incoming datagrams
/// can split. Going through `PacketListener` (SOCK_DGRAM socketpair, see
/// patches 013-015) keeps every datagram intact in both directions.
///
/// The receive-side data plane — HELLO/HELLO_ACK, NACK, receiver reports,
/// PLI, FEC, RTP reassembly, and control demux — is the portable
/// `ViewerSession` (shared with the Linux/Windows viewer). This class owns the
/// mac-only shell around it: the UDP socket, the VideoToolbox/Metal adapters,
/// the TCP annotation + remote-control channels, `VoiceChannel` audio, the
/// decode-recovery escalation ladder, and the keepalive / idle-disconnect
/// plumbing.
///
/// Flow on connect:
///
///   1. Bind a local UDP `PacketListener` on the node's tailnet IP at an
///      ephemeral port. tsnet picks the port; the server learns it from
///      the source address of the HELLO datagram.
///   2. Build a `ViewerSession` and `start()` it — the session emits the
///      extended HELLO (advertising NACK / receiver-report / FEC) via
///      `onControlToSend`.
///   3. Feed every inbound datagram to `ViewerSession.receiveRTP`; decoded
///      frames flow decoder → `MetalSinkAdapter` → renderer, and the session
///      emits its own NACK/PLI/RR feedback back over UDP.
///   4. Periodically send KEEPALIVE so the server's idle sweeper doesn't
///      drop us during quiet stretches.
///
/// The renderer (and the `NSWindow` it lives in) is owned by `AppState` for
/// the process lifetime — see the long comment that used to live here for
/// the AppKit teardown race that motivated that.
@available(macOS 10.15, *)
final class TailscaleScreenShareClient: @unchecked Sendable {
    var node: TailscaleNode?
    /// True when this client created the tsnet node itself; false when it
    /// borrowed AppState's node. Controls whether `disconnect()` tears the
    /// node down or just releases its reference.
    private var ownsNode: Bool = true

    private var packetListener: PacketListener?
    private var serverAddr: String?
    private let renderer: MetalViewerRenderer
    private var decoder: VideoDecoder?

    /// The portable `ViewerSession` — the video / audio / loss-recovery data
    /// plane (HELLO/HELLO_ACK, NACK, receiver reports, PLI, FEC, reassembly,
    /// control demux) shared with the Linux/Windows viewer and covered by the
    /// `linux-protocol` / `linux-viewer` CI. Built fresh per `connect()`. This
    /// is the viewer's **sole** receive path: the mac client is now a socket +
    /// the mac adapters (`VTVideoDecoderAdapter` / `MetalSinkAdapter`) + the
    /// mac-only side channels (annotations, remote control, `VoiceChannel`
    /// audio, the decode-recovery ladder) arranged *around* the session.
    private var viewerSession: ViewerSession?
    /// Serial queue the VideoToolbox adapter hops decoded frames onto (the
    /// frame path — adapter → sink → renderer — never touches session state, so
    /// it needn't be the receive task's context; it just must be consistent).
    private let viewerFrameQueue = DispatchQueue(label: "com.tailscreen.viewer-session-frames")
    private var isConnected = false
    private var isDisconnecting = false

    /// Audio SSRC the sharer assigned via HELLO_ACK. nil until the ack
    /// arrives; the VoiceChannel waits on this before sending mic audio.
    private(set) var assignedAudioSSRC: UInt32?

    /// Fires when the sharer assigns us an audio SSRC. AppState uses this
    /// to lazily build the local VoiceChannel.
    var onAudioSSRCAssigned: ((UInt32) -> Void)?

    /// Fires when the sharer reports our HELLO is parked behind their
    /// approval gate (HELLO_PENDING). AppState toggles a "Waiting for
    /// sharer to accept" overlay; cleared on first decoded frame or
    /// disconnect.
    var onAwaitingApproval: (() -> Void)?

    /// Fires when the sharer declines (or has blocked) this viewer
    /// (HELLO_DENY). AppState surfaces an alert and disconnects. When
    /// unset, the receive loop falls back to the generic peer-closed
    /// teardown — same as the SERVER_BYE that follows on the wire.
    var onDeniedBySharer: (() -> Void)?

    /// Fires on every inbound audio RTP packet (PT=98). AppState pipes
    /// this into VoiceChannel.receive(_:).
    var onAudioReceived: ((Data) -> Void)?

    /// Test-only: fires on the decoder's output thread each time a frame is
    /// decoded. Production presents frames via `MetalViewerRenderer`, whose
    /// `onVideoSizeChanged` only fires once the renderer's `CADisplayLink` is
    /// driving — and that link requires an on-screen `NSView` (`start(in:)`),
    /// which doesn't exist under xctest. E2E tests assert on this instead so
    /// they verify the capture→encode→RTP→tsnet→decode pipeline without a
    /// windowed render surface.
    var onDecodedFrameForTesting: ((CVPixelBuffer) -> Void)?
    private let logger: TSLogger
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?

    /// TCP back-channel for annotation ops. Separate from the UDP video
    /// stream because strokes need reliable, ordered delivery — a dropped
    /// UDP datagram would leave a visual gap mid-stroke. Goes to the same
    /// host:port as the peer-discovery probe.
    private var annotationChannel: OutgoingConnection?

    /// Serializes writes on `annotationChannel` so concurrent
    /// `sendAnnotationOp` calls (e.g. rapid stroke segments) don't
    /// interleave framed-message bytes on the wire.
    private let annotationWriter = ConnectionWriter()
    /// Background task draining inbound annotation ops fanned out by the
    /// server (sharer-painted strokes, other viewers' strokes). Cancelled
    /// in `disconnect()`.
    private var annotationReceiveTask: Task<Void, Never>?

    /// Fires for each inbound annotation op received on the back-channel.
    /// AppState wires this to the viewer's overlay so sharer + other-viewer
    /// strokes render alongside locally drawn ones.
    var onAnnotationReceived: ((AnnotationOp) -> Void)?

    /// Fires when the sharer grants this viewer remote control
    /// (`.controlGranted`). AppState flips the viewer into control mode and
    /// starts capturing input.
    var onControlGranted: (() -> Void)?

    /// Fires when the sharer's advertised remote-control support becomes known
    /// or changes — `true` if the sharer's HELLO_ACK carried
    /// `ScreenShareCaps.remoteControl`. AppState gates the viewer's "Request
    /// Control" affordance on this so it isn't offered against a sharer whose
    /// build/platform can't inject input at all (the request would otherwise
    /// be silently dropped as an unknown TCP type). Static support only;
    /// a live request is still subject to the sharer's runtime toggle +
    /// Accessibility gate.
    var onRemoteControlSupportChanged: ((Bool) -> Void)?

    /// Fires when the sharer's advertised annotation support becomes known or
    /// changes — `true` if the HELLO_ACK carried `ScreenShareCaps.annotations`.
    /// AppState gates the viewer's annotation toolbar on this so the viewer
    /// doesn't draw local-only strokes at a sharer that can't render/relay
    /// them (they would reach neither the sharer nor other viewers). Sharer
    /// capability only.
    var onAnnotationSupportChanged: ((Bool) -> Void)?

    /// Fires when the sharer revokes (or declines) control (`.controlRevoked`).
    /// The argument is the sharer's short reason tag (English, for logs — the
    /// viewer UI shows its own localized message). AppState leaves control
    /// mode and stops capturing input.
    var onControlRevoked: ((String) -> Void)?

    init(renderer: MetalViewerRenderer) {
        self.renderer = renderer
        self.logger = TSLogger()
    }

    /// Transmit an annotation op to the sharer over the TCP back-channel.
    /// Safe to call concurrently; writes are serialized through
    /// ``ConnectionWriter``. Drops silently if the back-channel isn't open.
    func sendAnnotationOp(_ op: AnnotationOp) async {
        guard let conn = annotationChannel, isConnected else { return }
        let data = ScreenShareMessage.annotation(op).encode()
        do {
            try await annotationWriter.send(data, over: conn)
        } catch {
            logger.log("Client: sendAnnotationOp failed: \(error)")
        }
    }

    /// Ask the sharer for remote control (`.controlRequest`) over the TCP
    /// back-channel. Best-effort; no-op if the channel isn't open.
    func requestControl() async {
        guard let conn = annotationChannel, isConnected else { return }
        do {
            try await annotationWriter.send(ScreenShareMessage.controlRequest.encode(), over: conn)
        } catch {
            logger.log("Client: requestControl failed: \(error)")
        }
    }

    /// Send one input event to the sharer for injection (`.inputEvent`). Rides
    /// the same reliable, serialized TCP channel as annotations so a
    /// `mouseDown` never arrives without its `mouseUp`. No-op if the channel
    /// isn't open.
    func sendInputEvent(_ event: InputEvent) async {
        guard let conn = annotationChannel, isConnected else { return }
        do {
            try await annotationWriter.send(ScreenShareMessage.inputEvent(event).encode(), over: conn)
        } catch {
            logger.log("Client: sendInputEvent failed: \(error)")
        }
    }

    /// Tell the sharer we're done controlling (`.controlReleased`) so it
    /// revokes the grant — keeping the sharer UI + gate in step with the
    /// viewer leaving control mode. Best-effort; no-op if the channel is closed.
    func releaseControl() async {
        guard let conn = annotationChannel, isConnected else { return }
        do {
            try await annotationWriter.send(ScreenShareMessage.controlReleased.encode(), over: conn)
        } catch {
            logger.log("Client: releaseControl failed: \(error)")
        }
    }

    /// Drains framed annotation ops from the server's back-channel
    /// fan-out (sharer-painted strokes + other viewers' strokes that the
    /// server relays). Runs until the connection closes or `disconnect()`
    /// cancels the task. Failures here only kill the inbound channel;
    /// outbound `sendAnnotationOp` still works until the conn errors too.
    private func receiveAnnotationLoop(over connection: OutgoingConnection) async {
        var parser = ScreenShareMessageParser()
        while !Task.isCancelled {
            do {
                let chunk = try await connection.receive(maximumLength: 16 * 1024, timeout: 5_000)
                if chunk.isEmpty { return }  // EOF
                parser.append(chunk)
                while let message = parser.next() {
                    switch message {
                    case .annotation(let op):
                        onAnnotationReceived?(op)
                    case .controlGranted:
                        onControlGranted?()
                    case .controlRevoked(let reason):
                        onControlRevoked?(reason)
                    default:
                        break
                    }
                }
                // Oversized/bogus frame: the stream can't resync, drop it.
                if parser.isCorrupt {
                    logger.log("Annotation back-channel sent an oversized frame — closing")
                    return
                }
            } catch TailscaleError.readFailed {
                if Task.isCancelled { return }
                continue  // poll timeout — keep reading
            } catch {
                return
            }
        }
    }

    /// Owns the TCP annotation back-channel for the whole session: drain
    /// inbound ops and reconnect with capped backoff if the connection drops
    /// mid-session. Before this, a dropped back-channel stayed dead for the
    /// rest of the call — annotations silently stopped even though video kept
    /// flowing. `initial` is the connection `connect()` already dialed (nil if
    /// that first dial failed). Best-effort; runs until `disconnect()` cancels
    /// `annotationReceiveTask`.
    private func runAnnotationChannel(initial: OutgoingConnection?, host: String, port: UInt16) async {
        let target = "\(host):\(port)"
        var conn = initial
        var reconnectAttempts = 0
        while !Task.isCancelled && isConnected {
            if conn == nil {
                conn = await dialAnnotation(to: target)
                guard conn != nil else {
                    if Task.isCancelled || !isConnected { break }
                    reconnectAttempts += 1
                    // Same 250 ms → 5 s capped doubling as the UDP receive
                    // loops; the constants live in `ReceiveLoopPolicy`.
                    try? await Task.sleep(
                        nanoseconds: ReceiveLoopPolicy.retryDelayNs(consecutiveErrors: reconnectAttempts))
                    continue
                }
                reconnectAttempts = 0  // reset after a clean (re)connect
            }
            guard let live = conn else { break }
            // Drains until the connection drops or the task is cancelled.
            await receiveAnnotationLoop(over: live)
            self.annotationChannel = nil
            conn = nil
            // On shutdown, disconnect() owns closing the connection it still
            // referenced; on a mid-session drop we close it and reconnect.
            if Task.isCancelled || !isConnected { break }
            await live.close()
            logger.log("Annotation back-channel dropped — reconnecting")
        }
        self.annotationChannel = nil
    }

    /// Dial the annotation back-channel once, publishing it to
    /// `annotationChannel` on success. Returns nil (logged) on failure.
    private func dialAnnotation(to target: String) async -> OutgoingConnection? {
        guard let node = self.node, let tailscale = await node.tailscale else { return nil }
        do {
            let conn = try await OutgoingConnection(
                tailscale: tailscale, to: target, proto: .tcp, logger: logger)
            try await conn.connect()
            self.annotationChannel = conn
            logger.log("Annotation back-channel reconnected to \(target)")
            return conn
        } catch {
            logger.log("Annotation back-channel reconnect failed: \(error) — retrying")
            return nil
        }
    }

    /// Tail of the audio send chain. Each call to `sendAudioRTP` parks
    /// on the previous one's job before issuing its own send. Stops
    /// detached `Task`s from piling up when `pl.send` stalls (poor link,
    /// peer reachability change) — at 50 Hz a backed-up actor would
    /// otherwise grow an unbounded queue.
    private let audioSendTail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// Send one outbound audio RTP packet up to the sharer. VoiceChannel
    /// calls this from its onSend closure. Fire-and-forget; serialised
    /// internally via `audioSendTail`.
    func sendAudioRTP(_ packet: Data) {
        guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
        let prev = audioSendTail.withLock { $0 }
        // Explicit capture list keeps the 50 Hz chain from accidentally
        // retaining `self` if a future edit ever reads an instance
        // property inside the Task body. Each link holds `pl`, `addr`,
        // and the previous task — never `self`.
        let job = Task { [pl, addr, packet] in
            await prev?.value
            try? await pl.send(packet, to: addr)
        }
        audioSendTail.withLock { $0 = job }
    }

    /// Test-only: send one PLI control packet to the server immediately. The
    /// production PLI path fires from inside `ViewerSession` on detected packet
    /// loss, which is hard to provoke deterministically; this drives the
    /// viewer→server PLI path directly so a test can assert the server records it.
    func sendPLIForTesting() async {
        guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
        try? await pl.send(ScreenShareControlMessage.encode(.pli), to: addr)
    }

    /// Ask the sharer to fall back to 8-bit (PROFILE_NO) — the lighter cousin
    /// of the `codecUnsupported` H.264 fallback, for a viewer that decodes
    /// HEVC but not its 10-bit Main 10 profile. Sent a few times since it
    /// rides best-effort UDP. Reserved for the opt-in 10-bit/HDR path: the
    /// production decoder can't cheaply tell "profile unsupported" from
    /// "codec unsupported" pre-decode, so today's 8-bit-only streams never
    /// trigger it; exposed so a test (and a future 10-bit capability probe)
    /// can drive the server's `force8bit` latch.
    func sendBitDepthFallbackRequest() async {
        guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
        for _ in 0..<3 {
            try? await pl.send(ScreenShareControlMessage.encode(.profileUnsupported), to: addr)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func connect(
        to hostname: String,
        port: UInt16 = NetworkConfig.tailscreenPort,
        authKey: String? = nil,
        path: String? = nil,
        controlURL: String = kDefaultControlURL,
        existingNode: TailscaleNode? = nil
    ) async throws {
        guard !isConnected else { return }

        // Fresh session — drop counters from the previous connection so
        // the stats overlay doesn't inherit a stale drop-rate or codec
        // label across reconnects.
        renderer.resetStats()
        // Reset the per-session viewer UI support flags; the loss-recovery
        // data plane is rebuilt fresh below as a new `ViewerSession`.
        resetViewerSupportState()

        let node: TailscaleNode
        if let existing = existingNode {
            node = existing
            self.node = existing
            self.ownsNode = false
            logger.log("Screen-share client reusing existing Tailscale node")
        } else {
            let statePath =
                path
                ?? {
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                        .first!
                    return appSupport.appendingPathComponent(
                        "Tailscreen/tailscale-client\(TailscreenInstance.stateSuffix)"
                    ).path
                }()
            try? FileManager.default.createDirectory(atPath: statePath, withIntermediateDirectories: true)

            logger.log("Starting Tailscale client…")

            let clientHostname = "\(TailscreenInstance.clientHostnamePrefix)\(UUID().uuidString.prefix(8))"
            let config = Configuration(
                hostName: clientHostname,
                path: statePath,
                authKey: authKey,
                controlURL: controlURL,
                ephemeral: true
            )

            let newNode = try TailscaleNode(config: config, logger: logger)
            self.node = newNode
            self.ownsNode = true
            try await newNode.up()
            node = newNode
        }

        let ips = try await node.addrs()
        logger.log("Tailscale connected — ip4=\(ips.ip4 ?? "-") ip6=\(ips.ip6 ?? "-")")

        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        // tsnet's ListenPacket needs an explicit IP. Bind on this node's
        // tailnet IPv4 (preferred) or IPv6 with port 0 → kernel picks an
        // ephemeral port. The server learns where to send RTP back to from
        // the source address of our HELLO.
        let bindIP = ips.ip4 ?? ips.ip6 ?? "0.0.0.0"
        let bindAddr = ips.ip4 != nil ? "\(bindIP):0" : "[\(bindIP)]:0"
        let pl = try await PacketListener(
            tailscale: tailscaleHandle,
            address: bindAddr,
            logger: logger
        )
        self.packetListener = pl
        let addr = formatAddr(host: hostname, port: port)
        self.serverAddr = addr
        logger.log("Bound local UDP, dialing \(addr)")

        let decoder = VideoDecoder()
        self.decoder = decoder
        // The mac adapters own the decoder's callbacks; the portable
        // ViewerSession drives the receive path (built here, run below).
        buildViewerSession(decoder: decoder, addr: addr)

        self.isConnected = true

        // The session advertises NACK + receiver-report + FEC in its extended
        // HELLO (via `onControlToSend`). Old servers read byte 0 only and reply
        // with a legacy 5-byte ack (caps `[]`), so the viewer degrades to the
        // PLI path against them; a NACK-era server's ack simply lacks `.fec`.
        viewerSession?.start()
        logger.log("HELLO sent via ViewerSession to \(addr)")

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        keepaliveTask = Task { [weak self] in
            await self?.keepaliveLoop()
        }

        // Annotation back-channel: dial inline (so it's ready by the time
        // connect() returns), then hand the connection to a task that drains it
        // and reconnects with backoff if it drops mid-session. Best-effort — a
        // failure here never breaks video. Spawned after isConnected=true so
        // the reconnect loop's `isConnected` guard doesn't trip immediately.
        var initialAnnotationConn: OutgoingConnection?
        do {
            let conn = try await OutgoingConnection(
                tailscale: tailscaleHandle, to: "\(hostname):\(port)", proto: .tcp, logger: logger)
            try await conn.connect()
            self.annotationChannel = conn
            initialAnnotationConn = conn
            logger.log("Annotation back-channel open to \(hostname):\(port)")
        } catch {
            logger.log("Annotation back-channel initial dial failed: \(error) — retrying in background")
        }
        annotationReceiveTask = Task { [weak self] in
            await self?.runAnnotationChannel(initial: initialAnnotationConn, host: hostname, port: port)
        }
    }

    /// IPv6 literals must be bracketed: "[::1]:7447", not "::1:7447". IPv4
    /// addresses don't need brackets. Detection: presence of ":" outside a
    /// trailing port is the IPv6 signal.
    private func formatAddr(host: String, port: UInt16) -> String {
        if host.contains(":") && !host.hasPrefix("[") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    /// The decoder couldn't build a session for `codec` (typically HEVC on a
    /// Mac without HEVC decode). Ask the sharer to fall back to H.264 — sent a
    /// few times since CODEC_NO rides best-effort UDP and a single drop would
    /// strand us on a black screen — and surface the failure to the user. The
    /// decoder fires this at most once per codec, so this isn't a hot path.
    private func handleDecodeFailure(_ codec: VideoCodec) {
        logger.log("Decode failure for \(codec) — requesting H.264 fallback from sharer")
        if let addr = serverAddr, let pl = packetListener {
            Task {
                for _ in 0..<3 {
                    try? await pl.send(ScreenShareControlMessage.encode(.codecUnsupported), to: addr)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        NotificationCenter.default.post(
            name: .tailscreenViewerDecodeFailed,
            object: nil,
            userInfo: ["codec": String(describing: codec)]
        )
    }

    /// One rung of the decoder's consecutive-failure escalation ladder (see
    /// `DecodeRecoveryAction`). Fires on the decoder's serial queue, so the
    /// PLI sends hop into a Task. Ladder PLIs deliberately bypass the 100 ms
    /// throttle: each rung fires at most once per failing episode (rare by
    /// construction, so no amplification risk), and letting the throttle
    /// swallow one would leave the wedged decoder waiting on the next rung
    /// for another chance. Loss-driven PLIs stay throttled.
    private func handleDecodeRecoveryAction(_ action: DecodeRecoveryAction) {
        logger.log("Client: decode-recovery action \(action)")
        switch action {
        case .requestKeyframe, .recreateSession:
            // The decoder handles the session rebuild itself; either way a
            // fresh IDR is what un-wedges decoding, so ask the sharer for
            // one. This also feeds the server's adaptive-bitrate PLI window,
            // so a genuinely lossy link steps its rate down.
            Task { [weak self] in
                await self?.sendPLIUnthrottled()
            }
        case .signalDegraded:
            renderer.setDegraded(true)
        case .surfaceError:
            NotificationCenter.default.post(name: .tailscreenViewerVideoStalled, object: nil)
        }
    }

    // MARK: - ViewerSession receive path

    /// Assemble the portable `ViewerSession` wired to the mac adapters: the
    /// VideoToolbox decoder (frames hop onto `viewerFrameQueue`, then to the
    /// Metal renderer via `MetalSinkAdapter`), raw audio forwarded to the host's
    /// `VoiceChannel` (`onAudioReceived`), and control feedback (HELLO / NACK /
    /// PLI / receiver reports) sent back over UDP. Built once per `connect()`.
    private func buildViewerSession(decoder: VideoDecoder, addr: String) {
        let adapter = VTVideoDecoderAdapter(decoder: decoder, callbackQueue: viewerFrameQueue)
        // Mac decode-recovery + codec-fallback paths. These ride the adapter's
        // pass-through hooks (bypassing ViewerSession, which never inspects a
        // decoded frame) so the CODEC_NO H.264 fallback and the decode-recovery
        // escalation ladder run mac-side.
        adapter.onCodecUnsupported = { [weak self] codec in
            self?.handleDecodeFailure(codec)
        }
        // Test seam: the E2E suites assert a frame decoded via this callback
        // (the windowed Metal render path doesn't run under xctest).
        adapter.onDecodedPixelBufferForTesting = { [weak self] buffer in
            self?.onDecodedFrameForTesting?(buffer)
        }
        adapter.onFrameDecodeFailed = { [weak self] in
            self?.renderer.noteDecodeFailure()
        }
        adapter.onRecoveryAction = { [weak self] action in
            self?.handleDecodeRecoveryAction(action)
        }
        adapter.onRecovered = { [weak self] in
            self?.logger.log("Client: decoding recovered — clearing degraded indication")
            self?.renderer.setDegraded(false)
        }
        let sink = MetalSinkAdapter(renderer: renderer)
        let session = ViewerSession(
            caps: [.nack, .receiverReport, .fec],
            decoder: adapter,
            videoSink: sink,
            audioSink: nil,
            onControlToSend: { [weak self] data in
                // Fire-and-forget async send on the tsnet listener. Cross-message
                // ordering isn't guaranteed, but control bytes tolerate it (HELLO
                // is the first, and the only order-critical one).
                Task { [weak self] in try? await self?.packetListener?.send(data, to: addr) }
            },
            onAudioDatagram: { [weak self] datagram in
                // The host owns audio decode: pipe PT-98/99 straight into the
                // mac VoiceChannel, exactly as the legacy loop's onAudioReceived.
                self?.onAudioReceived?(datagram)
            }
        )
        // Stats overlay: feed the renderer's loss-recovery counters as the
        // session emits feedback. These fire on the receive task (where
        // receiveRTP/tick run), same as the legacy loop's note* calls.
        session.onPLISent = { [weak self] in self?.renderer.notePLISent() }
        session.onNACKSent = { [weak self] in self?.renderer.noteNACKSent() }
        session.onFECRecovered = { [weak self] in self?.renderer.noteFECRecovered() }
        viewerSession = session
    }

    /// Stats-overlay bookkeeping for the ViewerSession receive path: account for
    /// every video byte off the wire and report the codec on first sight,
    /// mirroring the legacy loop. The loss-recovery counters (PLI/NACK/FEC) are
    /// fed via the session's observation hooks wired in `buildViewerSession`.
    private func noteReceivedVideoStats(_ datagram: Data) {
        guard let (header, _) = RTPHeader.decode(from: datagram) else { return }
        switch header.payloadType {
        case RTPHeader.h264PayloadType:
            renderer.noteReceivedBytes(datagram.count)
            renderer.noteCodec(.h264)
        case RTPHeader.hevcPayloadType:
            renderer.noteReceivedBytes(datagram.count)
            renderer.noteCodec(.hevc)
        default:
            break
        }
    }

    /// The receive loop: route every datagram through the portable
    /// `ViewerSession`, drive its ~1 Hz tick, and translate the session's
    /// negotiated state (assigned SSRC + serverCaps, pending/denied/stopped)
    /// into the client callbacks `AppState` consumes. Owns only the recv +
    /// idle-disconnect + backoff plumbing; all loss recovery lives in the
    /// session.
    private func receiveLoop() async {
        guard let pl = packetListener else { return }
        let idleDisconnectAfterNs = TransportTuning.clientIdleDisconnectNs
        var lastDataNs = DispatchTime.now().uptimeNanoseconds
        var awaitingApproval = false
        var consecutiveErrors = 0
        var errorStampsNs: [UInt64] = []
        var firedAdmission = false
        var firedAwaiting = false

        while isConnected {
            // Re-fetch the (non-Sendable) session each iteration and use it only
            // in this synchronous block, so it's never held across the await
            // below. `receiveRTP` after the await reads the property fresh.
            guard let session = viewerSession else { break }
            session.tick(nowNs: DispatchTime.now().uptimeNanoseconds)

            // Translate one-shot session-state transitions into the client's
            // callbacks (the bespoke loop fires these inline on the control bytes).
            if !firedAwaiting, session.isPendingApproval {
                firedAwaiting = true
                awaitingApproval = true
                onAwaitingApproval?()
            }
            if session.wasDenied {
                logger.log("Receive(VS): denied by sharer")
                if let onDeniedBySharer {
                    onDeniedBySharer()
                } else {
                    // No deny handler installed — fall back to the generic
                    // peer-closed teardown, attributed to the sharer since
                    // a HELLO_DENY is their explicit decision.
                    postPeerClosed(.sharerStopped)
                }
                break
            }
            if !firedAdmission, let ssrc = session.assignedSSRC {
                firedAdmission = true
                awaitingApproval = false
                assignedAudioSSRC = ssrc
                onAudioSSRCAssigned?(ssrc)
                onRemoteControlSupportChanged?(session.serverCaps.contains(.remoteControl))
                onAnnotationSupportChanged?(session.serverCaps.contains(.annotations))
            }
            if session.isStopped {
                logger.log("Receive(VS): sharer stopped")
                postPeerClosed(.sharerStopped)
                break
            }

            let recvStartNs = DispatchTime.now().uptimeNanoseconds
            do {
                let (datagram, from) = try await pl.recv(timeout: 1_000)
                consecutiveErrors = 0
                if datagram.isEmpty { continue }
                if from != serverAddr { continue }
                lastDataNs = DispatchTime.now().uptimeNanoseconds
                noteReceivedVideoStats(datagram)
                viewerSession?.receiveRTP(datagram)
            } catch {
                guard isConnected else { break }
                if case TailscaleError.readFailed = error {
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds &- recvStartNs
                    if !ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: elapsedNs) {
                        consecutiveErrors = 0
                        let nowNs = DispatchTime.now().uptimeNanoseconds
                        if !awaitingApproval && nowNs &- lastDataNs > idleDisconnectAfterNs {
                            logger.log("Receive(VS): idle for >timeout, assuming server gone")
                            postPeerClosed(.timedOut)
                            break
                        }
                        continue
                    }
                }
                consecutiveErrors += 1
                let nowNs = DispatchTime.now().uptimeNanoseconds
                let windowCount = ReceiveLoopPolicy.slidingWindowErrorCount(
                    &errorStampsNs, appending: nowNs)
                logger.log("Receive(VS) error #\(consecutiveErrors) (\(windowCount) in window): \(error)")
                let deadConsecutive = consecutiveErrors >= ReceiveLoopPolicy.maxConsecutiveErrors
                let deadWindowed = windowCount >= ReceiveLoopPolicy.maxErrorsPerWindow
                if deadConsecutive || deadWindowed {
                    postPeerClosed(.connectionLost)
                    break
                }
                try? await Task.sleep(
                    nanoseconds: ReceiveLoopPolicy.retryDelayNs(consecutiveErrors: consecutiveErrors))
            }
        }
    }

    /// Post `.tailscreenViewerPeerClosed` with the reason riding along, so
    /// AppState can explain the ending instead of collapsing sharer-stop,
    /// idle timeout, and socket-error storms into one unexplained
    /// disconnect.
    private func postPeerClosed(_ reason: ViewerCloseReason) {
        NotificationCenter.default.post(
            name: .tailscreenViewerPeerClosed,
            object: nil,
            userInfo: [ViewerCloseReason.userInfoKey: reason.rawValue])
    }

    private func keepaliveLoop() async {
        // 500 ms cadence so a dropped UDP keepalive (or a one-off Task
        // scheduling stall) doesn't push us past the server's 15 s idle
        // sweep. Two missed sends in a row still leaves ~14 s of slack.
        while isConnected {
            try? await Task.sleep(nanoseconds: TransportTuning.keepaliveIntervalNs)
            guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
            try? await pl.send(ScreenShareControlMessage.encode(.keepalive), to: addr)
        }
    }

    /// Send a PLI to the sharer immediately. Used by the decode-recovery ladder
    /// (`handleDecodeRecoveryAction`) — its rungs fire at most once per failing
    /// episode, so there's no loss-amplification risk. Loss-driven PLIs are the
    /// session's own concern now (emitted from `ViewerSession` via its NACK
    /// scheduler), so the old receive-task throttle went with the legacy loop.
    private func sendPLIUnthrottled() async {
        guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
        renderer.notePLISent()
        try? await pl.send(ScreenShareControlMessage.encode(.pli), to: addr)
    }

    /// Reset the per-session viewer UI support flags on a fresh `connect()` so a
    /// reused client instance doesn't carry the previous session's advertised
    /// remote-control / annotation support into the new one before its HELLO_ACK
    /// re-establishes them. The loss-recovery state proper now lives in the
    /// freshly-built `ViewerSession`, so there's nothing else to clear here.
    private func resetViewerSupportState() {
        onRemoteControlSupportChanged?(false)
        onAnnotationSupportChanged?(true)
    }

    func disconnect() async {
        if isDisconnecting { return }
        isDisconnecting = true

        // Best-effort BYE so the server can drop us immediately rather than
        // wait the full idle timeout. UDP send isn't guaranteed; if it
        // doesn't arrive, the server's sweeper will collect us.
        if let pl = packetListener, let addr = serverAddr, isConnected {
            try? await pl.send(ScreenShareControlMessage.encode(.bye), to: addr)
        }

        isConnected = false

        if let pl = packetListener {
            await pl.close()
            self.packetListener = nil
        }
        serverAddr = nil

        if let conn = annotationChannel {
            await conn.close()
            self.annotationChannel = nil
        }
        if let task = annotationReceiveTask {
            task.cancel()
            _ = await task.value
        }
        annotationReceiveTask = nil

        if let receiveTask = receiveTask {
            receiveTask.cancel()
            _ = await receiveTask.value
        }
        receiveTask = nil
        if let keepaliveTask = keepaliveTask {
            keepaliveTask.cancel()
            _ = await keepaliveTask.value
        }
        keepaliveTask = nil

        if let node = node, ownsNode {
            try? await node.close()
        }
        self.node = nil

        if let decoder = decoder {
            decoder.onDecodedFrame = nil
            decoder.onFrameDecodeFailed = nil
            decoder.onRecoveryAction = nil
            decoder.onRecovered = nil
            decoder.shutdown()
            self.decoder = nil
        }
        // Release the session (and, through it, the VT adapter's hold on the
        // now-shut-down decoder) once the receive task that drove it has been
        // cancelled and awaited above.
        viewerSession = nil

        // Teardown owns clearing the degraded indication — the ladder that
        // set it is gone with the decoder, and leaving it latched kept the
        // toolbar triangle + overlay banner up through the disconnected
        // state and into the next session's first paint. The remaining
        // counters reset on the next connect via `resetStats()`.
        renderer.setDegraded(false)

        logger.log("Client disconnected")
    }

    deinit {
        isConnected = false
        receiveTask?.cancel()
        keepaliveTask?.cancel()
    }

    /// Stable identity string used to derive this viewer's drawing color.
    /// Mirrors SharerOverlayWindow.localIdentity() so a process that's
    /// both a sharer and (separately) a viewer uses the *same* color in
    /// both surfaces.
    static func localIdentity() -> String {
        let host = Host.current().localizedName ?? "tailscreen"
        return "\(host)\(TailscreenInstance.hostnameSuffix)"
    }
}

private struct TSLogger: LogSink {
    var logFileHandle: Int32?
    func log(_ message: String) { print("[Tailscale] \(message)") }
}

/// Why the viewer's receive loop declared the session over is the shared
/// tier-4 `ViewerCloseReason` (TailscreenViewer) — the former app-local
/// `ViewerPeerCloseReason` with the same cases and raw values, now portable so
/// the GTK and WinUI viewers report the same endings. It rides
/// `.tailscreenViewerPeerClosed` as `userInfo[ViewerCloseReason.userInfoKey]`
/// (the raw value — Notification userInfo stays property-list-friendly) so
/// AppState can tell the user *which* ending happened. The key itself is
/// mac-only plumbing, so it lives here rather than in the portable enum.
extension ViewerCloseReason {
    /// The `userInfo` key the raw value travels under.
    static let userInfoKey = "reason"
}

extension Notification.Name {
    /// Posted from the viewer's receive loop when the session is over —
    /// sharer stop, idle timeout, or a socket-error storm, told apart by
    /// the `ViewerCloseReason` in `userInfo`. AppState observes this
    /// and ends the session with an in-window explanation.
    static let tailscreenViewerPeerClosed = Notification.Name("tailscreen.viewer.peerClosed")

    /// Posted from the viewer's decoder when VideoToolbox can't build a
    /// decompression session for the stream's codec. AppState surfaces an
    /// alert; the client has already asked the sharer to fall back to H.264.
    /// `userInfo["codec"]` carries the codec name as a String.
    static let tailscreenViewerDecodeFailed = Notification.Name("tailscreen.viewer.decodeFailed")

    /// Posted from the decode-failure escalation ladder's last rung: frames
    /// are arriving but decoding has been failing for several seconds
    /// despite a keyframe request and a decoder-session rebuild. AppState
    /// surfaces an alert so a frozen frame isn't a silent mystery.
    static let tailscreenViewerVideoStalled = Notification.Name("tailscreen.viewer.videoStalled")
}

/// Serializes `send(_:)` calls on an `OutgoingConnection`. Two concurrent
/// sends would interleave framed-message bytes on the wire and desync the
/// peer's parser.
private actor ConnectionWriter {
    func send(_ data: Data, over connection: OutgoingConnection) async throws {
        try await connection.send(data)
    }
}
