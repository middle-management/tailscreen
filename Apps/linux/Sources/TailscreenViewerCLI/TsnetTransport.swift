import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenTransport
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
    /// If `config.authKey` is nil, brings the node up via interactive browser
    /// login (the login URL is surfaced on stderr / best-effort opened);
    /// otherwise the key joins headlessly.
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
        // Interactive login (no auth key): tsnet's `up()` blocks until the
        // backend reaches Running, which on a fresh device means waiting for a
        // browser login. tsnet emits that login URL as a BrowseToURL notify on
        // the IPN bus — subscribe BEFORE `up()` (else the notify fires with
        // nobody listening and `up()` waits forever) and surface the URL for
        // the user to open. With an auth key this path is skipped entirely.
        var authWatcher: TailscaleIPNWatcher?
        if config.authKey == nil {
            let watcher = TailscaleIPNWatcher()
            watcher.onBrowseToURL = { url in Self.surfaceLoginURL(url) }
            try await watcher.startWatching(node: node)
            authWatcher = watcher
            logger.log("No auth key set — waiting for interactive browser login…")
        }

        logger.log("Bringing up tsnet node \(hostName)…")
        try await node.up()
        authWatcher?.stopWatching()

        let ips = try await node.addrs()
        logger.log("tsnet up — ip4=\(ips.ip4 ?? "-") ip6=\(ips.ip6 ?? "-")")

        // Surface which tailnet identity we actually joined. A viewer that
        // authenticated into the wrong tailnet looks identical to a connected
        // one that just isn't getting frames — printing the account here turns
        // that into an obvious mismatch. Best-effort; never blocks the session.
        let auth = TailscaleAuth()
        await auth.checkAuthStatus(node: node)
        let identity = auth.userProfile?.loginName ?? "unknown account"
        logger.log("▶ Connected as \(identity) — node \(hostName) @ \(ips.ip4 ?? ips.ip6 ?? "?")")

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
        // Wrap the caller's sink so the first decoded frame (and any later
        // resolution change) is announced — the "am I actually receiving
        // video?" signal.
        let loggingSink = StatusVideoSink(inner: videoSink, logger: logger)
        let pipeline = ViewerPipeline(
            caps: config.caps,
            decoder: decoder,
            videoSink: loggingSink,
            audioSink: audioSink,
            onControlToSend: { data in outboundContinuation.yield(data) }
        )

        let sendLogger = logger
        let senderTask = Task {
            var loggedSendError = false
            for await datagram in outbound {
                do {
                    try await listener.send(datagram, to: dest)
                } catch {
                    // Surface the first failure (a dial/resolve error means the
                    // target is wrong or unreachable) rather than silently
                    // dropping every outbound packet.
                    if !loggedSendError {
                        sendLogger.log("⚠ UDP send to \(dest) failed: \(error)")
                        loggedSendError = true
                    }
                }
            }
        }
        defer {
            outboundContinuation.finish()
            senderTask.cancel()
        }

        // Advertise our caps; the sharer replies with a HELLO_ACK.
        pipeline.start()
        logger.log("HELLO queued to \(dest) (caps=\(config.caps.rawValue)) — awaiting HELLO_ACK…")

        // Receive + tick loop. `recv`'s timeout gives a steady tick cadence
        // (NACK/PLI aging) even with no inbound traffic; real datagrams return
        // it sooner. Rendering is independent — the sink's own thread keeps the
        // window painted — so this loop only needs to service the network and
        // feed frames. Session-state transitions are announced once each so the
        // user sees admission / pending-approval rather than a silent window.
        var loggedPending = false
        var loggedAdmitted = false
        while !pipeline.isStopped && !shouldClose() {
            pipeline.tick(nowNs: DispatchTime.now().uptimeNanoseconds)
            let session = pipeline.session
            if session.isPendingApproval, !loggedPending {
                logger.log("▶ Waiting for the sharer to approve this viewer…")
                loggedPending = true
            }
            if let ssrc = session.assignedSSRC, !loggedAdmitted {
                logger.log(
                    "▶ Admitted by sharer (ssrc=\(ssrc), serverCaps=\(session.serverCaps.rawValue)) — awaiting video…"
                )
                loggedAdmitted = true
            }
            do {
                let (datagram, from) = try await listener.recv(timeout: 250)
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
        if pipeline.session.wasDenied {
            logger.log("▶ Sharer declined this viewer.")
        } else if pipeline.isStopped {
            logger.log("▶ Sharer ended the session.")
        } else {
            logger.log("▶ Viewer window closed.")
        }
        await listener.close()
        try? await node.down()
    }

    /// Surface an interactive-login URL: print it prominently on stderr (so it
    /// stands out from the `[tsnet]` log stream — the common case is a headless
    /// guest where the user copies it to a browser on another machine) and, if
    /// a desktop session is present, best-effort `xdg-open` it locally. Nothing
    /// here can throw into the login path — a failed open just leaves the
    /// printed URL.
    nonisolated static func surfaceLoginURL(_ url: URL) {
        let line = String(repeating: "─", count: 60)
        let banner = """

            \(line)
              Tailscale login required — open this URL in a browser:

                \(url.absoluteString)
            \(line)

            """
        FileHandle.standardError.write(Data(banner.utf8))

        // Only attempt a local open when a display is available; in a headless
        // guest there's no browser and xdg-open would just error.
        guard ProcessInfo.processInfo.environment["DISPLAY"] != nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xdg-open", url.absoluteString]
        try? process.run()
    }

    /// Bracket IPv6 literals ("[::1]:7447"); leave IPv4 untouched.
    static func formatAddr(host: String, port: UInt16) -> String {
        if host.contains(":") && !host.hasPrefix("[") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }
}

/// Forwards decoded frames to the real sink while announcing the first frame
/// (the "video is actually flowing" signal) and any later resolution change.
/// Everything runs on the transport's single actor, so plain mutable state is
/// safe here.
private final class StatusVideoSink: VideoSink {
    private let inner: VideoSink
    private let logger: StderrLogger
    private var announced = false
    private var lastWidth = 0
    private var lastHeight = 0

    init(inner: VideoSink, logger: StderrLogger) {
        self.inner = inner
        self.logger = logger
    }

    func present(_ frame: DecodedVideoFrame) {
        if !announced {
            logger.log("▶ Receiving video — \(frame.width)×\(frame.height)")
            announced = true
        } else if frame.width != lastWidth || frame.height != lastHeight {
            logger.log("▶ Video size changed to \(frame.width)×\(frame.height)")
        }
        lastWidth = frame.width
        lastHeight = frame.height
        inner.present(frame)
    }
}
