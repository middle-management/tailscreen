import AppKit
import CoreVideo
import Foundation
import TailscaleKit
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
/// Flow on connect:
///
///   1. Bind a local UDP `PacketListener` on the node's tailnet IP at an
///      ephemeral port. tsnet picks the port; the server learns it from
///      the source address of the HELLO datagram.
///   2. Send a HELLO control byte to the server's "ip:port".
///   3. Receive RTP packets, reassemble into AVCC access units, decode.
///   4. Periodically send KEEPALIVE so the server's idle sweeper doesn't
///      drop us during quiet stretches.
///
/// On packet loss the depacketizer flags the next clean access unit; we
/// react by sending a PLI back to the server, which forces a fresh IDR.
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
    /// Demultiplexes incoming RTP packets to the right codec depacketizer
    /// based on the payload type — viewer auto-detects H.264 (PT 96) or
    /// HEVC (PT 97) without out-of-band negotiation.
    private var depacketizer = MultiCodecDepacketizer()
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

    /// Last-installed parameter sets, applied to the decoder on first sight
    /// and re-applied if they change (resolution change, encoder restart).
    /// The server emits parameter sets in-band as RTP packets at the head
    /// of every IDR, so we don't need a separate parameter-sets message.
    private var installedParameters: CodecParameterSets?

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
                    if case .annotation(let op) = message {
                        onAnnotationReceived?(op)
                    }
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
    /// production PLI path fires from the depacketizer on detected packet loss,
    /// which is hard to provoke deterministically; this drives the viewer→server
    /// PLI path directly so a test can assert the server records it.
    func sendPLIForTesting() async {
        guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
        try? await pl.send(ScreenShareControlMessage.encode(.pli), to: addr)
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
        decoder.onDecodedFrame = { [weak self] pixelBuffer in
            self?.onDecodedFrameForTesting?(pixelBuffer)
            self?.handleDecodedFrame(pixelBuffer)
        }
        decoder.onDecodeFailure = { [weak self] codec in
            self?.handleDecodeFailure(codec)
        }
        decoder.onFrameDecodeFailed = { [weak self] in
            self?.renderer.noteDecodeFailure()
        }
        decoder.onRecoveryAction = { [weak self] action in
            self?.handleDecodeRecoveryAction(action)
        }
        decoder.onRecovered = { [weak self] in
            self?.logger.log("Client: decoding recovered — clearing degraded indication")
            self?.renderer.setDegraded(false)
        }
        self.decoder = decoder

        self.isConnected = true

        try await pl.send(ScreenShareControlMessage.encode(.hello), to: addr)
        logger.log("HELLO sent to \(addr)")

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

    private func receiveLoop() async {
        guard let pl = packetListener else { return }
        var packetsReceived = 0
        var framesDelivered = 0
        // Match the sharer's 15 s idle sweep so a sharer that's just
        // pausing video (e.g. backgrounded SCStream while the user
        // switches Spaces) doesn't fully tear our session down. The
        // sharer's own watchdog will still notice if we've truly gone
        // silent for >15 s, at which point both ends time out together.
        // Both constants live in TransportTuning to keep them coupled.
        let idleDisconnectAfterNs = TransportTuning.clientIdleDisconnectNs
        var lastDataNs = DispatchTime.now().uptimeNanoseconds
        var consecutiveErrors = 0
        var errorStampsNs: [UInt64] = []

        while isConnected {
            let recvStartNs = DispatchTime.now().uptimeNanoseconds
            do {
                // recv returns one UDP datagram. The server is the only
                // party that should be sending to us (it learned our addr
                // from the HELLO source); ignore datagrams from anywhere
                // else as a precaution.
                let (datagram, from) = try await pl.recv(timeout: 1_000)
                consecutiveErrors = 0
                if datagram.isEmpty { continue }
                if from != serverAddr {
                    // Don't pollute the depacketizer with packets from
                    // unexpected senders. In practice this never happens
                    // on a tailnet; safety net only.
                    continue
                }
                lastDataNs = DispatchTime.now().uptimeNanoseconds
                packetsReceived += 1

                // The server sends control bytes at us:
                //   - SERVER_BYE on `Stop Sharing` — tear down immediately
                //     instead of waiting out the no-video idle timer.
                //   - HELLO_ACK in response to our HELLO — assigns the
                //     audio SSRC we'll use to send mic packets.
                // Real RTP has V=2 → 0x80–0xBF, so a leading non-V=2 byte
                // is a control packet we need to interpret.
                if ScreenShareControlMessage.looksLikeControl(datagram) {
                    switch ScreenShareControlMessage.decode(datagram) {
                    case .serverBye:
                        logger.log("Receive: SERVER_BYE — sharer stopped")
                        NotificationCenter.default.post(name: .tailscreenViewerPeerClosed, object: nil)
                        return
                    case .helloAck:
                        if let ssrc = ScreenShareControlMessage.decodeHelloAck(datagram),
                            assignedAudioSSRC != ssrc
                        {
                            assignedAudioSSRC = ssrc
                            onAudioSSRCAssigned?(ssrc)
                        }
                    case .helloPending:
                        onAwaitingApproval?()
                    default:
                        break
                    }
                    continue
                }
                // Audio RTP (PT=98): route to VoiceChannel, skip video path.
                if let (header, _) = RTPHeader.decode(from: datagram),
                    header.payloadType == RTPHeader.aacPayloadType
                {
                    onAudioReceived?(datagram)
                    continue
                }

                // Video RTP: bookkeeping for the stats overlay. Account for
                // every video byte off the wire (header + payload) so the
                // overlay's bitrate readout reflects actual link load, not
                // just decoded payload, and report the codec the first time
                // we see one of the video payload types.
                if let (videoHeader, _) = RTPHeader.decode(from: datagram) {
                    switch videoHeader.payloadType {
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

                if let au = depacketizer.ingest(datagram) {
                    framesDelivered += 1
                    if au.lostBeforeThisAU {
                        // Rate-limited — see `sendPLIThrottled` for the
                        // loss-amplification hazard the throttle prevents.
                        await sendPLIThrottled()
                    }
                    if framesDelivered == 1 || framesDelivered % 60 == 0 {
                        logger.log(
                            "Client: AU #\(framesDelivered) (kf=\(au.containsIDR), \(au.avcc.count)B, packets=\(packetsReceived))"
                        )
                    }
                    self.lastReceiveUptimeNs = DispatchTime.now().uptimeNanoseconds
                    deliverAU(au)
                }
            } catch {
                guard isConnected else { break }
                // `TailscaleError.readFailed` is thrown both for the benign
                // 1 s poll timeout and for a dead fd (POLLHUP → instant
                // return). errno isn't visible from here, but elapsed time
                // tells them apart — treating every readFailed as a timeout
                // let a dead socket busy-spin with the error counter
                // permanently reset.
                if case TailscaleError.readFailed = error {
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds &- recvStartNs
                    if !ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: elapsedNs) {
                        consecutiveErrors = 0
                        let nowNs = DispatchTime.now().uptimeNanoseconds
                        if nowNs &- lastDataNs > idleDisconnectAfterNs {
                            let idleMs = (nowNs &- lastDataNs) / 1_000_000
                            logger.log("Receive: idle for \(idleMs) ms, assuming server gone")
                            NotificationCenter.default.post(name: .tailscreenViewerPeerClosed, object: nil)
                            break
                        }
                        continue
                    }
                    // Near-instant readFailed = dead fd; count it below.
                }
                // A one-off receive error used to kill this loop permanently
                // — and, unlike the idle-timeout path, without posting
                // `.tailscreenViewerPeerClosed`, so the window froze on a
                // stale frame with a live-looking UI. Retry with a capped
                // backoff instead, and if the socket is genuinely dead
                // (`maxConsecutiveErrors` in a row, or the windowed backstop
                // for errors interleaved with timeouts) tear down through
                // the same notification the idle path uses.
                consecutiveErrors += 1
                let nowNs = DispatchTime.now().uptimeNanoseconds
                let windowCount = ReceiveLoopPolicy.slidingWindowErrorCount(&errorStampsNs, appending: nowNs)
                logger.log("Receive error #\(consecutiveErrors) (\(windowCount) in window): \(error)")
                let deadConsecutive = consecutiveErrors >= ReceiveLoopPolicy.maxConsecutiveErrors
                let deadWindowed = windowCount >= ReceiveLoopPolicy.maxErrorsPerWindow
                if deadConsecutive || deadWindowed {
                    let detail = "\(consecutiveErrors) consecutive, \(windowCount) in window"
                    logger.log("Receive loop dead (\(detail)) — disconnecting")
                    NotificationCenter.default.post(name: .tailscreenViewerPeerClosed, object: nil)
                    break
                }
                try? await Task.sleep(
                    nanoseconds: ReceiveLoopPolicy.retryDelayNs(consecutiveErrors: consecutiveErrors))
            }
        }
    }

    private func deliverAU(_ au: VideoAccessUnit) {
        if au.containsIDR {
            if let params = Self.extractParameterSets(from: au) {
                if params != installedParameters {
                    installedParameters = params
                    decoder?.setParameterSets(params)
                }
            }
        }
        decoder?.decode(data: au.avcc, isKeyframe: au.containsIDR)
    }

    /// Pulls parameter sets out of an IDR access unit. The server prepends
    /// them in-band on every keyframe (SPS+PPS for H.264; VPS+SPS+PPS for
    /// HEVC) so any AU flagged `containsIDR` should carry them. NAL types
    /// 7/8 for H.264; 32/33/34 for HEVC. Internal (not private) so the
    /// extraction is unit testable.
    static func extractParameterSets(from au: VideoAccessUnit) -> CodecParameterSets? {
        let nals = AVCCParser.nalUnits(from: au.avcc)
        switch au.codec {
        case .h264:
            var sps: Data?
            var pps: Data?
            for nal in nals {
                guard let header = nal.first else { continue }
                switch header & 0x1F {
                case 7: sps = nal
                case 8: pps = nal
                default: break
                }
            }
            guard let sps = sps, let pps = pps else { return nil }
            return .h264(sps: sps, pps: pps)
        case .hevc:
            var vps: Data?
            var sps: Data?
            var pps: Data?
            for nal in nals {
                guard let header = nal.first else { continue }
                switch (header >> 1) & 0x3F {
                case 32: vps = nal
                case 33: sps = nal
                case 34: pps = nal
                default: break
                }
            }
            guard let vps = vps, let sps = sps, let pps = pps else { return nil }
            return .hevc(vps: vps, sps: sps, pps: pps)
        }
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

    private var lastReceiveUptimeNs: UInt64 = 0

    /// Throttle state for PLIs (see `sendPLIThrottled`). Locked because it's
    /// written from the receive task *and* from decoder-escalation Tasks.
    private let lastPLISentNs = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    /// Minimum spacing between PLIs. ~100 ms caps keyframe requests at ~10/s
    /// instead of up to one per dropped frame (60/s), while staying responsive.
    private let pliMinIntervalNs: UInt64 = 100_000_000

    /// Send a PLI to the server unless one went out within
    /// `pliMinIntervalNs`. The loss-driven path (depacketizer gap in
    /// `receiveLoop`) routes through this throttle: each PLI forces the
    /// encoder to emit a (large) keyframe, which fragments into more packets
    /// and, on a lossy link, can lose *more* — unthrottled loss-driven PLIs
    /// are a loss-amplification loop. One per interval is plenty; the
    /// keyframe it triggers covers all loss up to its arrival. The
    /// decode-recovery ladder uses `sendPLIUnthrottled` instead.
    private func sendPLIThrottled() async {
        guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let shouldSend = lastPLISentNs.withLock { last -> Bool in
            guard nowNs &- last >= pliMinIntervalNs else { return false }
            last = nowNs
            return true
        }
        guard shouldSend else { return }
        renderer.notePLISent()
        try? await pl.send(ScreenShareControlMessage.encode(.pli), to: addr)
    }

    /// Send a PLI immediately, bypassing the 100 ms throttle. Reserved for
    /// the decode-recovery ladder: its rungs fire at most once per failing
    /// episode, so there's no amplification risk — and a ladder PLI the
    /// throttle swallowed would stall recovery until the next rung. Pushes
    /// the throttle window forward so an immediately-following loss-driven
    /// PLI still spaces out.
    private func sendPLIUnthrottled() async {
        guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
        lastPLISentNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        renderer.notePLISent()
        try? await pl.send(ScreenShareControlMessage.encode(.pli), to: addr)
    }

    private func handleDecodedFrame(_ buffer: CVPixelBuffer) {
        guard isConnected, !isDisconnecting else { return }
        renderer.setPixelBuffer(buffer, receiveUptimeNs: lastReceiveUptimeNs)
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

extension Notification.Name {
    /// Posted from the viewer's receive loop when the server appears to
    /// have gone silent for longer than the idle threshold. AppState
    /// observes this and runs disconnect() so the UI tears down.
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
