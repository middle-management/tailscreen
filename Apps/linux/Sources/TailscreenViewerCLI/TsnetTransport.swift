import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenViewer
import TailscreenViewerCore

/// Connection parameters for the tsnet-backed viewer transport.
struct ViewerConfig {
    /// Sharer host to dial — a Tailscale hostname or tailnet IP.
    var hostname: String
    /// UDP/TCP port the sharer listens on.
    var port: UInt16 = 7447
    /// Tailscale pre-auth key (or nil for interactive/existing login).
    var authKey: String?
    /// Control server URL (headscale for local dev, else Tailscale's).
    var controlURL: String = kDefaultControlURL
    /// tsnet state directory (ephemeral node key + config).
    var statePath: String
    /// Capabilities this viewer advertises in its HELLO.
    var caps: ScreenShareCaps = [.nack, .receiverReport, .fec]
}

/// A minimal `LogSink` that writes both the Swift wrapper's logs and the Go
/// backend's logs (`logFileHandle`) to stderr, keeping stdout clean for the
/// eventual data path.
struct StderrLogger: LogSink {
    var logFileHandle: Int32? { STDERR_FILENO }
    func log(_ message: String) {
        FileHandle.standardError.write(Data("[tsnet] \(message)\n".utf8))
    }
}

/// tsnet-backed transport for the portable viewer. It mirrors the macOS
/// client's connect path (`TailscaleScreenShareClient.connect`): bring up an
/// ephemeral `TailscaleNode`, bind a `PacketListener` on this node's tailnet
/// IP, ship the pipeline's outbound control bytes over UDP, and pump inbound
/// datagrams into `ViewerSession.receiveRTP` while ticking its clock.
///
/// **This is the one piece that can't run in CI** — a live tsnet node needs a
/// real tailnet/DERP path (the repo's documented local-only constraint). It's
/// compile-gated by the `linux-viewer` CI job; a live run is manual/local.
/// All the *logic* it drives lives in the CI-tested `ViewerSession` core.
///
/// MainActor-isolated: the decoder, SDL renderer, and ALSA sink must all be
/// driven from a single thread (SDL's hard requirement), and pinning to the
/// main actor gives that for free — the `recv`/`send`/`tick` loop and every
/// sink call run on one executor, matching the non-`Sendable` contract of
/// `ViewerSession`.
@MainActor
final class TsnetTransport {
    private let logger = StderrLogger()

    /// Connect and run until the sharer says goodbye or `shouldClose` fires.
    ///
    /// - Parameters:
    ///   - config: connection + capability parameters.
    ///   - decoder: the concrete video decoder (FFmpeg on Linux).
    ///   - videoSink: where decoded frames go (SDL window).
    ///   - audioSink: where decoded audio goes (ALSA), or nil.
    ///   - shouldClose: polled each loop; returning true ends the session (the
    ///     SDL window close hook).
    func run(
        config: ViewerConfig,
        decoder: VideoDecoding,
        videoSink: VideoSink,
        audioSink: AudioSink?,
        shouldClose: @escaping () -> Bool
    ) async throws {
        try? FileManager.default.createDirectory(
            atPath: config.statePath, withIntermediateDirectories: true)

        // Bring up an ephemeral node (no manual device registration).
        let hostName = "tailscreen-viewer-\(UUID().uuidString.prefix(8))"
        let node = try TailscaleNode(
            config: Configuration(
                hostName: hostName,
                path: config.statePath,
                authKey: config.authKey,
                controlURL: config.controlURL,
                ephemeral: true
            ),
            logger: logger
        )
        logger.log("Bringing up tsnet node \(hostName)…")
        try await node.up()

        let ips = try await node.addrs()
        logger.log("tsnet up — ip4=\(ips.ip4 ?? "-") ip6=\(ips.ip6 ?? "-")")
        guard let tailscale = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        // tsnet's ListenPacket needs an explicit IP; bind IPv4 (preferred) or
        // IPv6 on port 0 so the kernel picks the ephemeral port. The sharer
        // learns our address from the HELLO's source.
        let bindIP = ips.ip4 ?? ips.ip6 ?? "0.0.0.0"
        let bindAddr = ips.ip4 != nil ? "\(bindIP):0" : "[\(bindIP)]:0"
        let listener = try await PacketListener(
            tailscale: tailscale, address: bindAddr, logger: logger)
        let dest = Self.formatAddr(host: config.hostname, port: config.port)
        logger.log("Bound local UDP; dialing \(dest)")

        // Ordered, non-blocking outbound queue: `onControlToSend` (a sync
        // closure the session calls on the receive thread) yields here, and a
        // single consumer task drains it through the actor's `send` in order.
        let (outbound, outboundContinuation) = AsyncStream<Data>.makeStream()
        let pipeline = ViewerPipeline(
            caps: config.caps,
            decoder: decoder,
            videoSink: videoSink,
            audioSink: audioSink,
            onControlToSend: { data in outboundContinuation.yield(data) }
        )

        let senderTask = Task {
            for await datagram in outbound {
                try? await listener.send(datagram, to: dest)
            }
        }
        defer {
            outboundContinuation.finish()
            senderTask.cancel()
        }

        // Advertise our caps; the sharer replies with a HELLO_ACK.
        pipeline.start()
        logger.log("HELLO sent (caps=\(config.caps.rawValue))")

        // Receive + tick loop. `recv` returns at least every second (its
        // timeout), giving a natural ~1 Hz cadence for `tick` even with no
        // inbound traffic; real datagrams return it sooner.
        while !pipeline.isStopped && !shouldClose() {
            pipeline.tick(nowNs: DispatchTime.now().uptimeNanoseconds)
            do {
                let (datagram, from) = try await listener.recv(timeout: 1_000)
                guard !datagram.isEmpty else { continue }
                // The sharer is the only expected sender (it learned our addr
                // from the HELLO); ignore anything else.
                guard from == dest else { continue }
                pipeline.receive(datagram)
            } catch {
                // recv timeouts surface as errors on some paths; keep looping
                // so `tick` and `shouldClose` still run. A truly dead socket
                // will keep erroring — bounded by the outer shouldClose.
                continue
            }
        }
        logger.log(pipeline.isStopped ? "Sharer ended the session." : "Viewer window closed.")
        await listener.close()
        try? await node.down()
    }

    /// Bracket IPv6 literals ("[::1]:7447"); leave IPv4 untouched.
    static func formatAddr(host: String, port: UInt16) -> String {
        if host.contains(":") && !host.hasPrefix("[") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }
}
