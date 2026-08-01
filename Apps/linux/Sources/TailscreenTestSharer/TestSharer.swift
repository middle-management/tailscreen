import Foundation
import TailscaleKit
import TailscreenProtocol

// tailscreen-test-sharer — a synthetic Tailscreen *sharer* for Linux.
//
//   tailscreen-test-sharer [--state-dir PATH] [--fps N] [--size WxH]
//   Env: TAILSCREEN_TS_AUTHKEY, TAILSCREEN_TS_CONTROL_URL
//
// The real sharer is macOS-only (ScreenCaptureKit), which left the Linux viewer
// end-to-end-untestable: everything past "the node comes up" could only be
// compile-gated. This stands in for it — a second tsnet node that speaks the
// sharer half of the wire protocol against a local headscale, so the whole
// viewer path can actually be exercised on one Linux box:
//
//   discovery → metadata/sharing chip → HELLO/admission → RTP video → decode +
//   GL render → annotations (both directions) → remote-control grant → input
//
// It serves REAL H.264 (libavcodec, moving test pattern), so the viewer's
// FFmpeg decoder and GL renderer do genuine work. It is a development/test tool,
// NOT a product sharer: it captures nothing, and every viewer is admitted.
//
// Pair with scripts/e2e-up-native.sh; see Apps/linux/README.md.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

/// Parsed command line + environment. A `Sendable` value stored in one global
/// `let` so the static serve functions can read it without global mutable state.
struct Config: Sendable {
    var statePath: String
    var fps: Int
    var width: Int
    var height: Int
    var authKey: String?
    var controlURL: String

    static func parse() -> Config {
        let args = Array(CommandLine.arguments.dropFirst())
        let env = ProcessInfo.processInfo.environment
        func arg(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        var width = 640
        var height = 360
        if let size = arg("--size") {
            let parts = size.split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else {
                fail("--size expects WxH, e.g. 640x360")
            }
            width = w
            height = h
        }
        return Config(
            statePath: arg("--state-dir")
                ?? (FileManager.default.currentDirectoryPath + "/.test-sharer-state"),
            fps: Int(arg("--fps") ?? "10") ?? 10,
            width: width,
            height: height,
            authKey: env["TAILSCREEN_TS_AUTHKEY"],
            controlURL: env["TAILSCREEN_TS_CONTROL_URL"] ?? kDefaultControlURL)
    }
}

let config = Config.parse()

struct StderrLog: LogSink {
    var logFileHandle: Int32? { STDERR_FILENO }
    func log(_ message: String) {
        FileHandle.standardError.write(Data("[sharer] \(message)\n".utf8))
    }
}
let logger = StderrLog()
func note(_ message: String) { logger.log(message) }

/// Tracks the viewers that have said HELLO, keyed by their UDP source address.
/// Every viewer is admitted immediately — this is a test tool, so there is no
/// approval gate, allow/deny store, or SSRC anti-spoof (all of which the real
/// macOS sharer implements and its own suites cover).
actor ViewerRoster {
    private var addrs: Set<String> = []
    private var nextSSRC: UInt32 = RTPHeader.firstViewerSSRC

    func admit(_ addr: String) -> UInt32 {
        addrs.insert(addr)
        let ssrc = nextSSRC
        nextSSRC &+= 1
        return ssrc
    }

    func remove(_ addr: String) { addrs.remove(addr) }
    func current() -> [String] { Array(addrs) }
    var isEmpty: Bool { addrs.isEmpty }
}

/// A viewer PLI arrives on the UDP control loop; the encoder is driven by the
/// video pump. This one flag is all that needs to cross between them.
///
/// It exists so the encoder has exactly ONE owner. Handing the encoder itself
/// to both loops let `requestKeyframe()` write `frame.pointee.pict_type` while
/// `encodeFrame` was inside `av_frame_make_writable` and writing that same
/// frame's planes — two threads mutating one `AVFrame`. Swift 6.1 accepted it;
/// 6.3's tightened `sending` check is what named it.
actor KeyframeRequest {
    private var pending = false

    func request() { pending = true }

    /// Consume the request, if any. Called by the pump immediately before
    /// encoding, so the IDR lands on the very next frame.
    func take() -> Bool {
        defer { pending = false }
        return pending
    }
}

@main
enum TestSharer {
    static func main() async {
        try? FileManager.default.createDirectory(atPath: config.statePath, withIntermediateDirectories: true)

        // A LONG-LIVED sharer identity: discovery lists peers whose hostname
        // starts with `tailscreen-` but NOT `tailscreen-client-`, so this must
        // avoid the client/viewer prefixes to show up as a connectable screen.
        let hostName = "\(TailscreenInstance.serverHostnamePrefix)test-sharer-\(UUID().uuidString.prefix(6))"
        let node: TailscaleNode
        do {
            node = try TailscaleNode(
                config: Configuration(
                    hostName: hostName,
                    path: config.statePath,
                    authKey: config.authKey,
                    controlURL: config.controlURL,
                    ephemeral: true),
                logger: logger)
            note("bringing up node \(hostName)…")
            try await node.up()
        } catch {
            fail("node bring-up failed: \(error)")
        }

        guard let ips = try? await node.addrs(), let tailscale = await node.tailscale else {
            fail("no tailnet address")
        }
        let ip4 = ips.ip4 ?? ips.ip6 ?? "?"
        note("up — \(hostName) @ \(ip4)")
        note("serving \(config.width)x\(config.height) @ \(config.fps)fps; waiting for viewers…")

        let roster = ViewerRoster()
        let bindAddr = ips.ip4 != nil
            ? "\(ips.ip4!):\(NetworkConfig.tailscreenPort)"
            : "[\(ips.ip6!)]:\(NetworkConfig.tailscreenPort)"

        // UDP: HELLO/admission + inbound feedback; the video fan-out sends here.
        let udp: PacketListener
        do {
            udp = try await PacketListener(tailscale: tailscale, address: bindAddr, logger: logger)
        } catch {
            fail("UDP bind \(bindAddr) failed: \(error)")
        }

        let encoder = H264TestEncoder(
            width: Int32(config.width), height: Int32(config.height), fps: Int32(config.fps))
        if encoder == nil { fail("no H.264 encoder in this libavcodec build") }

        let keyframe = KeyframeRequest()

        // TCP back-channel: metadata queries + annotations + control.
        Task { await serveTCP(tailscale: tailscale, address: bindAddr) }
        // UDP control receive loop. It gets the keyframe FLAG, not the encoder:
        // the pump below is the encoder's only owner.
        Task { await serveUDP(udp: udp, roster: roster, keyframe: keyframe) }
        // Video fan-out.
        await pumpVideo(udp: udp, roster: roster, encoder: encoder!, keyframe: keyframe)
    }

    // MARK: UDP control

    static func serveUDP(udp: PacketListener, roster: ViewerRoster, keyframe: KeyframeRequest) async {
        while true {
            guard let (data, from) = try? await udp.recv(timeout: 1_000), !data.isEmpty else {
                continue
            }
            guard let byte = data.first, let kind = ScreenShareControlMessage(rawValue: byte) else {
                continue  // RTP or unknown — a sharer receives viewer audio here too
            }
            switch kind {
            case .hello:
                let caps = ScreenShareControlMessage.decodeHelloCaps(data)
                let ssrc = await roster.admit(from)
                // Advertise the two sharer-only bits so the viewer enables its
                // Request-Control and annotation toolbars, plus the recovery
                // caps it offered us.
                let serverCaps: ScreenShareCaps =
                    [.nack, .receiverReport, .fec, .remoteControl, .annotations]
                let ack = ScreenShareControlMessage.encodeHelloAck(ssrc: ssrc, caps: serverCaps)
                try? await udp.send(ack, to: from)
                note("HELLO from \(from) (caps=\(caps.rawValue)) → admitted ssrc=\(ssrc)")
            case .bye:
                await roster.remove(from)
                note("BYE from \(from)")
            case .pli:
                note("PLI from \(from) → forcing keyframe")
                await keyframe.request()
            case .keepalive:
                break
            case .nack:
                note("NACK from \(from) (test sharer does not retransmit; PLI path covers recovery)")
            case .receiverReport:
                break
            default:
                break
            }
        }
    }

    // MARK: Video fan-out

    static func pumpVideo(
        udp: PacketListener, roster: ViewerRoster, encoder: H264TestEncoder,
        keyframe: KeyframeRequest
    ) async {
        let packetizer = H264Packetizer()
        var seq: UInt16 = 0
        var index = 0
        let frameNs = UInt64(1_000_000_000 / max(1, config.fps))
        let ticksPerFrame = UInt32(90_000 / max(1, config.fps))  // 90 kHz RTP clock
        var announced = false

        while true {
            let viewers = await roster.current()
            if viewers.isEmpty {
                announced = false
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            if !announced {
                note("streaming to \(viewers.count) viewer(s)")
                announced = true
            }
            // Consume any PLI the UDP loop parked, so the IDR lands on this
            // very frame rather than one later.
            if await keyframe.take() { encoder.requestKeyframe() }
            for au in encoder.encodeFrame(index: index) {
                let nals = H264TestEncoder.annexBToNALs(au)
                guard !nals.isEmpty else { continue }
                let packets = packetizer.packetize(
                    nals: nals, timestamp: UInt32(index) &* ticksPerFrame,
                    ssrc: RTPHeader.firstViewerSSRC, startSequence: seq)
                seq = seq &+ UInt16(packets.count)
                for packet in packets {
                    for viewer in viewers { try? await udp.send(packet, to: viewer) }
                }
            }
            index += 1
            try? await Task.sleep(nanoseconds: frameNs)
        }
    }

    // MARK: TCP back-channel

    static func serveTCP(tailscale: TailscaleHandle, address: String) async {
        let listener: Listener
        do {
            listener = try await Listener(
                tailscale: tailscale, proto: .tcp, address: address, logger: logger)
        } catch {
            note("TCP bind \(address) failed: \(error) — metadata/annotations disabled")
            return
        }
        while true {
            guard let conn = try? await listener.accept(timeout: 3600) else { continue }
            Task { await handleTCP(conn) }
        }
    }

    static func handleTCP(_ conn: IncomingConnection) async {
        let peer = (await conn.remoteAddress) ?? "?"
        var parser = ScreenShareMessageParser()
        while true {
            guard let chunk = try? await conn.receive(maximumLength: 16 * 1024, timeout: 30_000),
                !chunk.isEmpty
            else { break }
            parser.append(chunk)
            while let message = parser.next() {
                switch message {
                case .metadataRequest:
                    let metadata = TailscreenMetadata(
                        shareName: "Test Pattern",
                        hostname: "tailscreen-test-sharer",
                        screenResolution: .init(width: config.width, height: config.height),
                        isSharing: true,
                        timestamp: Date(),
                        videoCodec: .h264)
                    try? await conn.send(ScreenShareMessage.metadataResponse(metadata).encode())
                case .annotation(let op):
                    // Prove BOTH directions: log the viewer's stroke, then relay
                    // it back the way the real sharer fans out to other viewers.
                    note("annotation from \(peer): \(describe(op)) → relaying back")
                    try? await conn.send(ScreenShareMessage.annotation(op).encode())
                case .controlRequest:
                    note("control request from \(peer) → granting")
                    try? await conn.send(ScreenShareMessage.controlGranted.encode())
                case .inputEvent(let event):
                    note("input from \(peer): \(describe(event))")
                case .controlReleased:
                    note("control released by \(peer)")
                case .requestToShare(let host):
                    note("request-to-share from \(host) → accepting")
                    try? await conn.send(ScreenShareMessage.shareResponse(accepted: true).encode())
                default:
                    break
                }
            }
            if parser.isCorrupt {
                note("oversized frame from \(peer) — closing")
                break
            }
        }
        await conn.close()
    }

    static func describe(_ op: AnnotationOp) -> String {
        switch op {
        case .add(let a): return "add(\(a.tool), \(a.points.count) pts)"
        case .undo: return "undo"
        case .clearAll: return "clearAll"
        }
    }

    static func describe(_ event: InputEvent) -> String {
        switch event {
        case .mouseMove(let x, let y):
            return String(format: "move(%.3f, %.3f)", x, y)
        case .mouseDown(let x, let y, let button, _):
            return String(format: "down(%@ %.3f, %.3f)", "\(button)", x, y)
        case .mouseUp(let x, let y, let button, _):
            return String(format: "up(%@ %.3f, %.3f)", "\(button)", x, y)
        case .scroll(let x, let y, _, _, _):
            return String(format: "scroll(%.3f, %.3f)", x, y)
        case .keyDown(let key, let mods):
            return "keyDown(hid=0x\(String(key, radix: 16)), mods=\(mods.rawValue))"
        case .keyUp(let key, let mods):
            return "keyUp(hid=0x\(String(key, radix: 16)), mods=\(mods.rawValue))"
        }
    }
}
