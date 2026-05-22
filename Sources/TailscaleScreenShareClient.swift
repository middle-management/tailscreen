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
        self.decoder = decoder

        // Open the TCP annotation back-channel to the same host:port.
        // Best-effort: a connect failure here doesn't break video, it just
        // disables annotation streaming for this session.
        do {
            let conn = try await OutgoingConnection(
                tailscale: tailscaleHandle,
                to: "\(hostname):\(port)",
                proto: .tcp,
                logger: logger
            )
            try await conn.connect()
            self.annotationChannel = conn
            logger.log("Annotation back-channel open to \(hostname):\(port)")
            annotationReceiveTask = Task { [weak self] in
                await self?.receiveAnnotationLoop(over: conn)
            }
        } catch {
            logger.log("Annotation back-channel failed to open: \(error) (annotations disabled)")
        }

        self.isConnected = true

        try await pl.send(ScreenShareControlMessage.encode(.hello), to: addr)
        logger.log("HELLO sent to \(addr)")

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        keepaliveTask = Task { [weak self] in
            await self?.keepaliveLoop()
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

    private func receiveLoop() async {
        guard let pl = packetListener else { return }
        var packetsReceived = 0
        var framesDelivered = 0
        // Match the sharer's 15 s idle sweep so a sharer that's just
        // pausing video (e.g. backgrounded SCStream while the user
        // switches Spaces) doesn't fully tear our session down. The
        // sharer's own watchdog will still notice if we've truly gone
        // silent for >15 s, at which point both ends time out together.
        let idleDisconnectAfterNs: UInt64 = 15_000_000_000
        var lastDataNs = DispatchTime.now().uptimeNanoseconds

        while isConnected {
            do {
                // recv returns one UDP datagram. The server is the only
                // party that should be sending to us (it learned our addr
                // from the HELLO source); ignore datagrams from anywhere
                // else as a precaution.
                let (datagram, from) = try await pl.recv(timeout: 1_000)
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
                    if au.lostBeforeThisAU, let addr = serverAddr {
                        try? await pl.send(ScreenShareControlMessage.encode(.pli), to: addr)
                    }
                    if framesDelivered == 1 || framesDelivered % 60 == 0 {
                        logger.log(
                            "Client: AU #\(framesDelivered) (kf=\(au.containsIDR), \(au.avcc.count)B, packets=\(packetsReceived))"
                        )
                    }
                    self.lastReceiveUptimeNs = DispatchTime.now().uptimeNanoseconds
                    deliverAU(au)
                }
            } catch TailscaleError.readFailed {
                if !isConnected { break }
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if nowNs &- lastDataNs > idleDisconnectAfterNs {
                    let idleMs = (nowNs &- lastDataNs) / 1_000_000
                    logger.log("Receive: idle for \(idleMs) ms, assuming server gone")
                    NotificationCenter.default.post(name: .tailscreenViewerPeerClosed, object: nil)
                    break
                }
                continue
            } catch {
                if isConnected { logger.log("Receive error: \(error)") }
                break
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
    /// 7/8 for H.264; 32/33/34 for HEVC.
    private static func extractParameterSets(from au: VideoAccessUnit) -> CodecParameterSets? {
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
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard isConnected, let pl = packetListener, let addr = serverAddr else { return }
            try? await pl.send(ScreenShareControlMessage.encode(.keepalive), to: addr)
        }
    }

    private var lastReceiveUptimeNs: UInt64 = 0

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
            decoder.shutdown()
            self.decoder = nil
        }

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
}

/// Serializes `send(_:)` calls on an `OutgoingConnection`. Two concurrent
/// sends would interleave framed-message bytes on the wire and desync the
/// peer's parser.
private actor ConnectionWriter {
    func send(_ data: Data, over connection: OutgoingConnection) async throws {
        try await connection.send(data)
    }
}
