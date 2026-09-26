import AppKit
import CoreVideo
import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenViewer
import os

/// Screen-share viewer.
///
/// Uses `PacketListener` (UDP via tsnet's `ListenPacket`), not the Dial-UDP
/// path: `TsnetDial` uses a SOCK_STREAM socketpair, which doesn't preserve
/// datagram boundaries. `PacketListener` (SOCK_DGRAM) keeps every datagram
/// intact.
///
/// The receive-side data plane (HELLO/HELLO_ACK, NACK, RR, PLI, FEC, RTP
/// reassembly, control demux) is the portable `ViewerSession`, shared with
/// Linux/Windows. This class is the mac-only shell around it: UDP socket,
/// VideoToolbox/Metal adapters, TCP annotation + remote-control channels,
/// `VoiceChannel` audio, decode-recovery ladder, keepalive/idle-disconnect.
///
/// Flow on connect: bind a UDP `PacketListener` at an ephemeral port -> build
/// and start a `ViewerSession` (emits extended HELLO) -> feed inbound
/// datagrams to `ViewerSession.receiveRTP` (decoded frames flow decoder ->
/// `MetalSinkAdapter` -> renderer) -> periodic KEEPALIVE against the server's
/// idle sweeper.
@available(macOS 10.15, *)
final class TailscaleScreenShareClient: @unchecked Sendable {
    var node: TailscaleNode?
    /// False when this client borrowed AppState's node instead of creating
    /// its own; controls whether `disconnect()` tears the node down.
    private var ownsNode: Bool = true

    private var packetListener: PacketListener?
    private var serverAddr: String?
    /// Set when opened with `connectGuest` instead of a tailnet dial. Owned
    /// like a self-created node: torn down in `disconnect()`.
    private var guestClient: GuestClientNode?
    /// Picks the guest tunnel's dial for the TCP back-channel and labels the
    /// stats overlay; affordances are still gated by the sharer's caps.
    private(set) var isGuestSession = false
    private let renderer: MetalViewerRenderer
    private var decoder: VideoDecoder?

    /// The viewer's **sole** receive path: the mac client is a socket + mac
    /// adapters (`VTVideoDecoderAdapter`/`MetalSinkAdapter`) + mac-only side
    /// channels (annotations, remote control, `VoiceChannel`, decode-recovery
    /// ladder) arranged around this. Built fresh per `connect()`.
    private var viewerSession: ViewerSession?
    /// The frame path (adapter -> sink -> renderer) isn't the receive task's
    /// context; the session tolerates that only via its two thread-safe entry
    /// points (`noteDecodedFrame`/`noteHostDecodeFailure`), a mailbox the
    /// receive side drains.
    private let viewerFrameQueue = DispatchQueue(label: "com.tailscreen.viewer-session-frames")
    private var isConnected = false
    /// Shared so overlapping disconnect callers await the same teardown
    /// instead of returning while cleanup is still running.
    private let disconnectLock = NSLock()
    private var isDisconnecting = false
    private var disconnectTask: Task<Void, Never>?

    /// nil until HELLO_ACK arrives; VoiceChannel waits on this before sending
    /// mic audio.
    private(set) var assignedAudioSSRC: UInt32?

    /// Forwarded to the portable `ViewerSession`, which actually records
    /// handshake events — this class is the mac host around it.
    var recorder: DiagnosticsRecorder?

    /// AppState uses this to lazily build the local VoiceChannel.
    var onAudioSSRCAssigned: ((UInt32) -> Void)?

    /// HELLO_PENDING. AppState toggles a "Waiting for sharer to accept"
    /// overlay; HELLO_ACK or disconnect clears it.
    var onAwaitingApproval: (() -> Void)?

    /// HELLO_DENY. When unset, the receive loop falls back to the generic
    /// peer-closed teardown (same as the SERVER_BYE that follows on the wire).
    var onDeniedBySharer: (() -> Void)?

    var onAudioReceived: ((Data) -> Void)?

    /// Test-only: production presents via `MetalViewerRenderer`, whose
    /// `onVideoSizeChanged` needs an on-screen `NSView`'s `CADisplayLink`,
    /// unavailable under xctest. E2E tests assert on this instead to verify
    /// the capture->encode->RTP->tsnet->decode pipeline headlessly.
    var onDecodedFrameForTesting: ((CVPixelBuffer) -> Void)?
    private let logger: TSLogger
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?

    /// Separate from the UDP video stream because strokes need reliable,
    /// ordered delivery. Existential over `FramedControlChannel` since two
    /// tunnels can carry it: a tailnet dial or a guest tunnel dial.
    private var annotationChannel: (any FramedControlChannel)?

    /// Serializes writes so concurrent `sendAnnotationOp` calls don't
    /// interleave framed-message bytes on the wire.
    private let annotationWriter = ConnectionWriter()
    /// `TAILSCREEN_DEBUG_INPUT=1` stats, touched only from `sendInputEvent`.
    private var inputSendSampler = InputDebugLog.Sampler()
    /// Drains inbound ops fanned out by the server. Cancelled in `disconnect()`.
    private var annotationReceiveTask: Task<Void, Never>?

    /// AppState wires this to the viewer's overlay so sharer + other-viewer
    /// strokes render alongside locally drawn ones.
    var onAnnotationReceived: ((AnnotationOp) -> Void)?

    var onControlGranted: (() -> Void)?

    /// `true` if HELLO_ACK carried `ScreenShareCaps.remoteControl`. Gates the
    /// "Request Control" affordance; static support only — a live request is
    /// still subject to the sharer's runtime toggle + Accessibility gate.
    var onRemoteControlSupportChanged: ((Bool) -> Void)?

    /// `true` if HELLO_ACK carried `ScreenShareCaps.annotations`. Gates the
    /// annotation toolbar so the viewer doesn't draw local-only strokes at a
    /// sharer that can't render/relay them.
    var onAnnotationSupportChanged: ((Bool) -> Void)?

    /// `true` if HELLO_ACK carried `ScreenShareCaps.openLink`. Gates the
    /// "Open Link on Sharer…" affordance.
    var onOpenLinkSupportChanged: ((Bool) -> Void)?

    /// Argument is the sharer's short reason tag (English, logs only).
    var onControlRevoked: ((String) -> Void)?

    init(renderer: MetalViewerRenderer) {
        self.renderer = renderer
        self.logger = TSLogger()
    }

    /// Safe to call concurrently; writes are serialized through
    /// ``ConnectionWriter``.
    func sendAnnotationOp(_ op: AnnotationOp) async {
        guard let conn = annotationChannel, isConnected else {
            // Once per session: a viewer drawing before the back-channel is
            // up loses those strokes silently otherwise.
            if Self.takeLatch(annotationDropLogged) {
                logger.log("Client: annotation dropped — back-channel not open")
            }
            return
        }
        let data = ScreenShareMessage.annotation(op).encode()
        do {
            try await annotationWriter.send(data, over: conn)
            // Likewise once: answers whether strokes ever reached the wire,
            // without a row per stroke.
            if Self.takeLatch(annotationSentLogged) {
                logger.log("Client: first annotation op sent")
            }
        } catch {
            logger.log("Client: sendAnnotationOp failed: \(error)")
        }
    }

    private let annotationSentLogged = Guarded<Bool>(false)
    private let annotationDropLogged = Guarded<Bool>(false)

    /// True the first time called for a given latch, false after.
    private static func takeLatch(_ latch: Guarded<Bool>) -> Bool {
        latch.withLock { taken -> Bool in
            if taken { return false }
            taken = true
            return true
        }
    }

    /// Best-effort; no-op if the channel isn't open.
    func requestControl() async {
        guard let conn = annotationChannel, isConnected else { return }
        do {
            try await annotationWriter.send(ScreenShareMessage.controlRequest.encode(), over: conn)
        } catch {
            logger.log("Client: requestControl failed: \(error)")
        }
    }

    /// Offer the sharer a link (`.openLink`); they see it and choose whether
    /// to open it. Returns whether it reached the wire, so the UI never
    /// claims "sent" for a link that wasn't. Callers validate with
    /// `OpenLinkPayload.isAcceptable` first — the sharer drops anything else.
    func sendOpenLink(_ url: String) async -> Bool {
        guard let conn = annotationChannel, isConnected else { return false }
        do {
            try await annotationWriter.send(ScreenShareMessage.openLink(url: url).encode(), over: conn)
            return true
        } catch {
            logger.log("Client: sendOpenLink failed: \(error)")
            return false
        }
    }

    /// Rides the same reliable, serialized TCP channel as annotations so a
    /// `mouseDown` never arrives without its `mouseUp`.
    func sendInputEvent(_ event: InputEvent) async {
        guard let conn = annotationChannel, isConnected else { return }
        let startNs = DispatchTime.now().uptimeNanoseconds
        do {
            try await annotationWriter.send(ScreenShareMessage.inputEvent(event).encode(), over: conn)
        } catch {
            logger.log("Client: sendInputEvent failed: \(error)")
        }
        noteInputSend(startNs: startNs)
    }

    /// Separates "the sharer is slow" from "our send is queued behind
    /// something on this connection". Timed at the call site, not inside the
    /// writer actor, so the number includes the wait for the actor.
    private func noteInputSend(startNs: UInt64) {
        guard InputDebugLog.isEnabled else { return }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let elapsedNs = nowNs &- startNs
        if elapsedNs >= Self.slowInputSendNs {
            InputDebugLog.log("viewer send BLOCKED \(InputDebugLog.ms(elapsedNs))")
        }
        if let summary = inputSendSampler.note(elapsedNs, nowNs: nowNs) {
            InputDebugLog.log("viewer sends \(summary)")
        }
    }

    /// 100ms is well past a healthy framed write and well short of the
    /// multi-second stall this is meant to catch.
    private static let slowInputSendNs: UInt64 = 100_000_000

    func releaseControl() async {
        guard let conn = annotationChannel, isConnected else { return }
        do {
            try await annotationWriter.send(ScreenShareMessage.controlReleased.encode(), over: conn)
        } catch {
            logger.log("Client: releaseControl failed: \(error)")
        }
    }

    /// Failures here only kill the inbound channel; outbound
    /// `sendAnnotationOp` still works until the conn errors too.
    private func receiveAnnotationLoop(over connection: any FramedControlChannel) async {
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

    /// Drains inbound ops and reconnects with capped backoff if the
    /// connection drops mid-session — without this, a dropped back-channel
    /// stayed dead while video kept flowing. `initial` is nil if the first
    /// dial failed.
    private func runAnnotationChannel(
        initial: (any FramedControlChannel)?,
        redial: @escaping () async -> (any FramedControlChannel)?
    ) async {
        var conn = initial
        var reconnectAttempts = 0
        while !Task.isCancelled && isConnected {
            if conn == nil {
                conn = await redial()
                guard conn != nil else {
                    if Task.isCancelled || !isConnected { break }
                    reconnectAttempts += 1
                    // Same capped doubling as the UDP receive loops (`ReceiveLoopPolicy`).
                    try? await Task.sleep(
                        nanoseconds: ReceiveLoopPolicy.retryDelayNs(consecutiveErrors: reconnectAttempts))
                    continue
                }
                reconnectAttempts = 0  // reset after a clean (re)connect
            }
            guard let live = conn else { break }
            await receiveAnnotationLoop(over: live)
            self.annotationChannel = nil
            conn = nil
            // On shutdown, disconnect() owns closing the connection; on a
            // mid-session drop we close it and reconnect.
            if Task.isCancelled || !isConnected { break }
            await live.close()
            logger.log("Annotation back-channel dropped — reconnecting")
        }
        self.annotationChannel = nil
    }

    private func dialAnnotation(to target: String) async -> (any FramedControlChannel)? {
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

    /// Guest twin of `dialAnnotation`; same publish-on-success contract.
    private func dialGuestAnnotation() async -> (any FramedControlChannel)? {
        guard let guest = guestClient else { return nil }
        do {
            let conn = try await guest.dial(port: NetworkConfig.tailscreenPort)
            self.annotationChannel = conn
            logger.log("Annotation back-channel open through the guest tunnel")
            return conn
        } catch {
            logger.log("Guest annotation back-channel dial failed: \(error) — retrying")
            return nil
        }
    }

    /// Each `sendAudioRTP` call parks on the previous one's job before
    /// sending, so detached Tasks don't pile up when `pl.send` stalls — at
    /// 50Hz that would otherwise grow an unbounded queue.
    private let audioSendTail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// Fire-and-forget; serialized internally via `audioSendTail`.
    func sendAudioRTP(_ packet: Data) {
        guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
        let prev = audioSendTail.withLock { $0 }
        // Explicit capture list: never retain `self` in this 50Hz chain.
        let job = Task { [pl, addr, packet] in
            await prev?.value
            try? await pl.send(packet, to: addr)
        }
        audioSendTail.withLock { $0 = job }
    }

    /// Test-only: the production PLI path fires from `ViewerSession` on
    /// detected loss, hard to provoke deterministically; this drives the
    /// path directly.
    func sendPLIForTesting() async {
        guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
        try? await pl.send(ScreenShareControlMessage.encode(.pli), to: addr)
    }

    /// Lighter cousin of the `codecUnsupported` fallback, for a viewer that
    /// decodes HEVC but not Main 10. The production decoder can't cheaply
    /// tell "profile unsupported" from "codec unsupported" pre-decode, so
    /// today's 8-bit-only streams never trigger it; exposed for tests and a
    /// future 10-bit capability probe.
    func sendBitDepthFallbackRequest() async {
        guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
        for _ in 0..<3 {
            try? await pl.send(ScreenShareControlMessage.encode(.profileUnsupported), to: addr)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private var disconnectRequested: Bool {
        disconnectLock.withLock { isDisconnecting }
    }

    private func throwIfDisconnectRequested() throws {
        if disconnectRequested {
            throw CancellationError()
        }
    }

    /// Installs atomically with the cancellation check, so either this path
    /// or the shared teardown owns closing the listener.
    private func keepListenerUnlessDisconnecting(_ listener: PacketListener) async throws {
        let installed = disconnectLock.withLock {
            guard !isDisconnecting else { return false }
            packetListener = listener
            return true
        }
        guard installed else {
            await listener.close()
            throw CancellationError()
        }
    }

    /// Teardown either sees the complete task set or start was rejected — it
    /// can never miss tasks installed just after it finished.
    private func startMediaUnlessDisconnecting() throws {
        let started = disconnectLock.withLock {
            guard !isDisconnecting else { return false }
            isConnected = true
            viewerSession?.start()
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
            keepaliveTask = Task { [weak self] in
                await self?.keepaliveLoop()
            }
            return true
        }
        guard started else {
            decoder?.onDecodedFrame = nil
            decoder?.onFrameDecodeFailed = nil
            decoder?.onRecoveryAction = nil
            decoder?.onRecovered = nil
            decoder?.shutdown()
            decoder = nil
            viewerSession = nil
            serverAddr = nil
            throw CancellationError()
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
        try throwIfDisconnectRequested()

        // Fresh session, so the stats overlay doesn't inherit a stale
        // drop-rate/codec label across reconnects.
        renderer.resetStats()
        resetViewerSupportState()
        isGuestSession = false

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
            logger.log("Starting Tailscale client…")

            // Ephemeral, undiscoverable client-prefixed hostname (a transient
            // viewer, not a screen anyone should pick).
            let clientHostname = "\(TailscreenInstance.clientHostnamePrefix)\(UUID().uuidString.prefix(8))"
            let spec = TsnetNodeFactory.Spec(
                hostName: clientHostname,
                ephemeral: true,
                statePath: statePath,
                authKey: authKey,
                controlURL: controlURL)

            let newNode = try TsnetNodeFactory.makeNode(spec: spec, logger: logger)
            self.node = newNode
            self.ownsNode = true
            try await TsnetNodeFactory.up(newNode, spec: spec, timeout: .unbounded)
            try throwIfDisconnectRequested()
            node = newNode
        }

        let ips = try await node.addrs()
        try throwIfDisconnectRequested()
        logger.log("Tailscale connected — ip4=\(ips.ip4 ?? "-") ip6=\(ips.ip6 ?? "-")")

        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }
        try throwIfDisconnectRequested()

        // Port 0 -> kernel picks an ephemeral port; the server learns where
        // to send RTP back from our HELLO's source address.
        let bindIP = ips.ip4 ?? ips.ip6 ?? "0.0.0.0"
        let bindAddr = ips.ip4 != nil ? "\(bindIP):0" : "[\(bindIP)]:0"
        let pl = try await PacketListener(
            tailscale: tailscaleHandle,
            address: bindAddr,
            logger: logger
        )
        try await keepListenerUnlessDisconnecting(pl)
        let addr = formatAddr(host: hostname, port: port)
        self.serverAddr = addr
        logger.log("Bound local UDP, dialing \(addr)")

        let decoder = VideoDecoder()
        self.decoder = decoder
        buildViewerSession(decoder: decoder, addr: addr)

        // Old servers read byte 0 only and reply with a legacy 5-byte ack
        // (caps `[]`); a NACK-era server's ack simply lacks `.fec`.
        try startMediaUnlessDisconnecting()
        logger.log("HELLO sent via ViewerSession to \(addr)")

        // Dial inline so it's ready by the time connect() returns, then hand
        // off to a reconnecting task. Best-effort — a failure here never
        // breaks video.
        var initialAnnotationConn: (any FramedControlChannel)?
        do {
            let conn = try await OutgoingConnection(
                tailscale: tailscaleHandle, to: "\(hostname):\(port)", proto: .tcp, logger: logger)
            try await conn.connect()
            let installed = disconnectLock.withLock {
                guard !isDisconnecting else { return false }
                annotationChannel = conn
                return true
            }
            if !installed {
                await conn.close()
                throw CancellationError()
            }
            initialAnnotationConn = conn
            logger.log("Annotation back-channel open to \(hostname):\(port)")
        } catch let error as CancellationError {
            throw error
        } catch {
            logger.log("Annotation back-channel initial dial failed: \(error) — retrying in background")
        }
        let target = "\(hostname):\(port)"
        let annotationConn = initialAnnotationConn
        let started = disconnectLock.withLock {
            guard !isDisconnecting else { return false }
            annotationReceiveTask = Task { [weak self] in
                await self?.runAnnotationChannel(initial: annotationConn) { [weak self] in
                    await self?.dialAnnotation(to: target)
                }
            }
            return true
        }
        guard started else { throw CancellationError() }
    }

    /// No tsnet node, no sign-in — the token names the DERP relay and the
    /// sharer's node key. Guest approval is mandatory, so the
    /// awaiting-approval placard is the expected first state. Everything
    /// downstream is the tailnet path's; only the dials differ.
    func connectGuest(token: String) async throws {
        guard !isConnected else { return }
        try throwIfDisconnectRequested()

        renderer.resetStats()
        resetViewerSupportState()
        isGuestSession = true

        logger.log("Starting guest (share-by-token) tunnel…")
        let guest = GuestClientNode(token: token, logger: logger)
        self.guestClient = guest
        let pl = try await guest.dialUDP(port: NetworkConfig.tailscreenPort)
        try await keepListenerUnlessDisconnecting(pl)
        let addr = formatAddr(
            host: try await guest.serverAddr(), port: NetworkConfig.tailscreenPort)
        try throwIfDisconnectRequested()
        self.serverAddr = addr
        logger.log("Guest tunnel up, dialing \(addr)")

        let decoder = VideoDecoder()
        self.decoder = decoder
        buildViewerSession(decoder: decoder, addr: addr)

        try startMediaUnlessDisconnecting()
        logger.log("HELLO sent via ViewerSession to \(addr) (guest)")

        // Same framed protocol/reconnect loop as the tailnet path; a sharer
        // that predates the guest TCP channel simply never accepts, and the
        // redial loop keeps retrying quietly.
        var initialConn: (any FramedControlChannel)?
        do {
            let conn = try await guest.dial(port: NetworkConfig.tailscreenPort)
            let installed = disconnectLock.withLock {
                guard !isDisconnecting else { return false }
                annotationChannel = conn
                return true
            }
            if !installed {
                await conn.close()
                throw CancellationError()
            }
            initialConn = conn
            logger.log("Annotation back-channel open through the guest tunnel")
        } catch let error as CancellationError {
            throw error
        } catch {
            logger.log("Guest annotation back-channel initial dial failed: \(error) — retrying in background")
        }
        let annotationConn = initialConn
        let started = disconnectLock.withLock {
            guard !isDisconnecting else { return false }
            annotationReceiveTask = Task { [weak self] in
                await self?.runAnnotationChannel(initial: annotationConn) { [weak self] in
                    await self?.dialGuestAnnotation()
                }
            }
            return true
        }
        guard started else { throw CancellationError() }
    }

    /// IPv6 literals must be bracketed: "[::1]:7447", not "::1:7447".
    private func formatAddr(host: String, port: UInt16) -> String {
        if host.contains(":") && !host.hasPrefix("[") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    /// Sent a few times since CODEC_NO rides best-effort UDP and a single
    /// drop would strand us on a black screen. Fires at most once per codec.
    private func handleDecodeFailure(_ codec: VideoCodec) {
        logger.log("Decode failure for \(codec) — requesting H.264 fallback from sharer")
        // `reason` distinguishes this (VideoToolbox couldn't build a session
        // at all) from per-frame failures, recorded elsewhere.
        recorder?.record(
            .decodeFailed,
            role: .viewer,
            fields: ["codec": .string(codec.rawValue), "reason": .string("codec_unsupported")])
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
            object: self,
            userInfo: ["codec": String(describing: codec)]
        )
    }

    /// Ladder PLIs deliberately bypass the 100ms throttle: each rung fires at
    /// most once per failing episode, and the throttle swallowing one would
    /// leave the wedged decoder waiting for the next rung. Loss-driven PLIs
    /// stay throttled.
    private func handleDecodeRecoveryAction(_ action: DecodeRecoveryAction) {
        logger.log("Client: decode-recovery action \(action)")
        // Mac ladder runs inside `VideoDecoder`, not `ViewerSession`, so it
        // records its own rungs with the same event/field names as the
        // portable session.
        recorder?.record(
            .decodeRecoveryAction,
            role: .viewer,
            fields: ["action": .string(action.diagnosticName)])
        if action == .surfaceError {
            recorder?.record(.videoStalled, role: .viewer)
        }
        switch action {
        case .requestKeyframe, .recreateSession:
            // A fresh IDR un-wedges decoding either way; also feeds the
            // server's adaptive-bitrate PLI window.
            Task { [weak self] in
                await self?.sendPLIUnthrottled()
            }
        case .signalDegraded:
            renderer.setDegraded(true)
        case .surfaceError:
            NotificationCenter.default.post(name: .tailscreenViewerVideoStalled, object: self)
        }
    }

    // MARK: - ViewerSession receive path

    private func buildViewerSession(decoder: VideoDecoder, addr: String) {
        let adapter = VTVideoDecoderAdapter(decoder: decoder, callbackQueue: viewerFrameQueue)
        // Ride the adapter's pass-through hooks (bypassing ViewerSession,
        // which never inspects a decoded frame) so codec fallback and the
        // decode-recovery ladder run mac-side.
        adapter.onCodecUnsupported = { [weak self] codec in
            self?.handleDecodeFailure(codec)
        }
        // Test seam: the E2E suites assert a frame decoded via this callback
        // (the windowed Metal render path doesn't run under xctest).
        adapter.onDecodedPixelBufferForTesting = { [weak self] buffer in
            self?.onDecodedFrameForTesting?(buffer)
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
            // `.tenBit`: VideoToolbox decodes HEVC Main 10 on every Mac that
            // can run this app, down-converting for the 32BGRA renderer
            // rather than refusing. Advertising it lets a mac-to-mac share use
            // the sharer's 10-bit opt-in — one viewer without this bit drops
            // the whole share to 8-bit.
            caps: [.nack, .receiverReport, .fec, .tenBit],
            decoder: adapter,
            videoSink: sink,
            audioSink: nil,
            onControlToSend: { [weak self] data in
                // Cross-message ordering isn't guaranteed, but control bytes
                // tolerate it (HELLO is the only order-critical one).
                Task { [weak self] in try? await self?.packetListener?.send(data, to: addr) }
            },
            onAudioDatagram: { [weak self] datagram in
                self?.onAudioReceived?(datagram)
            }
        )
        // `VideoDecoder` runs its own escalation ladder, so this must NOT
        // reach the session's `onDecodeFailure` (double-ladders one episode).
        // `noteHostDecodeFailure` is the counting-only entry.
        adapter.onFrameDecodeFailed = { [weak self, weak session] in
            self?.renderer.noteDecodeFailure()
            session?.noteHostDecodeFailure()
        }
        session.recorder = recorder
        session.onPLISent = { [weak self] in self?.renderer.notePLISent() }
        session.onNACKSent = { [weak self] in self?.renderer.noteNACKSent() }
        session.onFECRecovered = { [weak self] in self?.renderer.noteFECRecovered() }
        viewerSession = session
    }

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
            // Re-fetched each iteration and used only in this synchronous
            // block, so it's never held across the await below.
            guard let session = viewerSession else { break }
            session.tick(nowNs: DispatchTime.now().uptimeNanoseconds)

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
                    postPeerClosed(.sharerStopped)
                }
                break
            }
            if !firedAdmission, let ssrc = session.assignedSSRC {
                firedAdmission = true
                awaitingApproval = false
                assignedAudioSSRC = ssrc
                onAudioSSRCAssigned?(ssrc)
                // The sharer's caps decide, guest or tailnet: the guest
                // tunnel carries the framed TCP channel now, and a sharer
                // that predates it (or whose guest TCP bind failed) simply
                // doesn't advertise — its HELLO_ACK caps come from the
                // same build that would or wouldn't accept the dial.
                onRemoteControlSupportChanged?(session.serverCaps.contains(.remoteControl))
                onAnnotationSupportChanged?(session.serverCaps.contains(.annotations))
                onOpenLinkSupportChanged?(session.serverCaps.contains(.openLink))
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

    /// AppState rejects a close from a replaced client before explaining the
    /// current session's ending.
    private func postPeerClosed(_ reason: ViewerCloseReason) {
        NotificationCenter.default.post(
            name: .tailscreenViewerPeerClosed,
            object: self,
            userInfo: [ViewerCloseReason.userInfoKey: reason.rawValue])
    }

    private func keepaliveLoop() async {
        // 500ms cadence: two missed sends in a row still leaves ~14s of
        // slack against the server's 15s idle sweep.
        while isConnected {
            try? await Task.sleep(nanoseconds: TransportTuning.keepaliveIntervalNs)
            guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
            try? await pl.send(ScreenShareControlMessage.encode(.keepalive), to: addr)
        }
    }

    /// Loss-driven PLIs are `ViewerSession`'s own concern (via its NACK
    /// scheduler); this is only for the decode-recovery ladder's rungs, which
    /// fire at most once per failing episode.
    private func sendPLIUnthrottled() async {
        guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
        renderer.notePLISent()
        try? await pl.send(ScreenShareControlMessage.encode(.pli), to: addr)
    }

    /// So a reused client doesn't carry the previous session's advertised
    /// support into a new one before HELLO_ACK re-establishes it.
    private func resetViewerSupportState() {
        onRemoteControlSupportChanged?(false)
        onAnnotationSupportChanged?(true)
        onOpenLinkSupportChanged?(false)
    }

    func disconnect() async {
        let task = disconnectLock.withLock { () -> Task<Void, Never> in
            isDisconnecting = true
            if let disconnectTask {
                return disconnectTask
            }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.performDisconnect()
            }
            disconnectTask = task
            return task
        }
        await task.value
    }

    private func performDisconnect() async {
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

        if let guest = guestClient {
            await guest.close()
            self.guestClient = nil
        }

        if let decoder = decoder {
            decoder.onDecodedFrame = nil
            decoder.onFrameDecodeFailed = nil
            decoder.onRecoveryAction = nil
            decoder.onRecovered = nil
            decoder.shutdown()
            self.decoder = nil
        }
        viewerSession = nil

        // Leaving this latched would keep the toolbar triangle/overlay banner
        // up through disconnect and into the next session's first paint.
        renderer.setDegraded(false)

        logger.log("Client disconnected")
    }

    deinit {
        isConnected = false
        receiveTask?.cancel()
        keepaliveTask?.cancel()
    }

    /// Mirrors `SharerOverlayWindow.localIdentity()` so a process that's both
    /// sharer and viewer uses the same color in both surfaces.
    static func localIdentity() -> String {
        let host = Host.current().localizedName ?? "tailscreen"
        return "\(host)\(TailscreenInstance.hostnameSuffix)"
    }
}

/// `PrintLogSink` is `package`-scoped, so this app can't use it; this struct
/// tees the same way, under the same `"Tailscale"` source tag, so a merged
/// timeline files both sides' lines alike.
private struct TSLogger: LogSink {
    var logFileHandle: Int32?
    func log(_ message: String) {
        print("[Tailscale] \(message)")
        DiagnosticsCenter.shared.captureLog(source: "Tailscale", message: message)
    }
}

/// `ViewerCloseReason` rides `.tailscreenViewerPeerClosed` as
/// `userInfo[ViewerCloseReason.userInfoKey]` (raw value, since userInfo stays
/// property-list-friendly). The key is mac-only plumbing, so it lives here
/// rather than in the portable enum.
extension ViewerCloseReason {
    static let userInfoKey = "reason"
}

extension Notification.Name {
    /// Sharer stop, idle timeout, or a socket-error storm — told apart by
    /// `ViewerCloseReason` in `userInfo`.
    static let tailscreenViewerPeerClosed = Notification.Name("tailscreen.viewer.peerClosed")

    /// VideoToolbox couldn't build a decompression session; the client has
    /// already asked the sharer to fall back to H.264. `userInfo["codec"]`
    /// carries the codec name as a String.
    static let tailscreenViewerDecodeFailed = Notification.Name("tailscreen.viewer.decodeFailed")

    /// The decode-failure ladder's last rung: frames arrive but decoding has
    /// failed for several seconds despite a keyframe request and session rebuild.
    static let tailscreenViewerVideoStalled = Notification.Name("tailscreen.viewer.videoStalled")
}

/// Serializes `send(_:)` calls on a control-channel connection. Two
/// concurrent sends would interleave framed-message bytes on the wire and
/// desync the peer's parser.
private actor ConnectionWriter {
    func send(_ data: Data, over connection: any FramedControlChannel) async throws {
        try await connection.send(data)
    }
}
