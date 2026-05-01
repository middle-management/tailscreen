import AppKit
import CoreVideo
import Foundation
import TailscaleKit

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
            print("Client: sendAnnotationOp failed: \(error)")
        }
    }

    func connect(
        to hostname: String,
        port: UInt16 = 7447,
        authKey: String? = nil,
        path: String? = nil,
        existingNode: TailscaleNode? = nil
    ) async throws {
        guard !isConnected else { return }

        let node: TailscaleNode
        if let existing = existingNode {
            node = existing
            self.node = existing
            self.ownsNode = false
            print("Screen-share client reusing existing Tailscale node")
        } else {
            let statePath = path ?? {
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                return appSupport.appendingPathComponent("Tailscreen/tailscale-client\(TailscreenInstance.stateSuffix)").path
            }()
            try? FileManager.default.createDirectory(atPath: statePath, withIntermediateDirectories: true)

            print("Starting Tailscale client…")

            let clientHostname = "tailscreen-client-\(UUID().uuidString.prefix(8))"
            let config = Configuration(
                hostName: clientHostname,
                path: statePath,
                authKey: authKey ?? TailscreenInstance.authKey,
                controlURL: TailscreenInstance.controlURLOverride ?? kDefaultControlURL,
                ephemeral: true
            )

            let newNode = try TailscaleNode(config: config, logger: logger)
            self.node = newNode
            self.ownsNode = true
            try await newNode.up()
            node = newNode
        }

        let ips = try await node.addrs()
        print("Tailscale connected — ip4=\(ips.ip4 ?? "-") ip6=\(ips.ip6 ?? "-")")

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
        self.serverAddr = formatAddr(host: hostname, port: port)
        print("Bound local UDP, dialing \(serverAddr ?? "?")")

        let decoder = VideoDecoder()
        decoder.onDecodedFrame = { [weak self] pixelBuffer in
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
            print("Annotation back-channel open to \(hostname):\(port)")
        } catch {
            print("Annotation back-channel failed to open: \(error) (annotations disabled)")
        }

        self.isConnected = true

        try await pl.send(ScreenShareControlMessage.encode(.hello), to: serverAddr!)
        print("HELLO sent to \(serverAddr!)")

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
        let idleDisconnectAfterNs: UInt64 = 3_000_000_000  // 3s
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

                // Server shouldn't be sending us control bytes, but ignore
                // them cleanly if it does. Real RTP has V=2 → 0x80–0xBF.
                guard !ScreenShareControlMessage.looksLikeControl(datagram) else { continue }

                if let au = depacketizer.ingest(datagram) {
                    framesDelivered += 1
                    if au.lostBeforeThisAU {
                        try? await pl.send(ScreenShareControlMessage.encode(.pli), to: serverAddr!)
                    }
                    if framesDelivered == 1 || framesDelivered % 60 == 0 {
                        print("Client: AU #\(framesDelivered) (kf=\(au.containsIDR), \(au.avcc.count)B, packets=\(packetsReceived))")
                    }
                    self.lastReceiveUptimeNs = DispatchTime.now().uptimeNanoseconds
                    deliverAU(au)
                }
            } catch TailscaleError.readFailed {
                if !isConnected { break }
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if nowNs &- lastDataNs > idleDisconnectAfterNs {
                    print("Receive: idle for > 3s, assuming server gone")
                    NotificationCenter.default.post(name: .tailscreenViewerPeerClosed, object: nil)
                    break
                }
                continue
            } catch {
                if isConnected { print("Receive error: \(error)") }
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
        while isConnected {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
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

        print("Client disconnected")
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
    var logFileHandle: Int32? = nil
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
