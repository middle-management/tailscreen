import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenTransport
import TailscreenViewer

/// Connection parameters for the tsnet-backed viewer transport.
public struct ViewerConfig: Sendable {
    /// Sharer host to dial — a Tailscale hostname or tailnet IP.
    public var hostname: String
    /// UDP/TCP port the sharer listens on.
    public var port: UInt16 = 7447
    /// Tailscale pre-auth key (or nil for interactive/existing login).
    public var authKey: String?
    /// Control server URL (headscale for local dev, else Tailscale's).
    public var controlURL: String = kDefaultControlURL
    /// tsnet state directory (ephemeral node key + config).
    public var statePath: String
    /// Capabilities this viewer advertises in its HELLO.
    public var caps: ScreenShareCaps = [.nack, .receiverReport, .fec]

    /// What this node is *for*, which decides the hostname it registers under
    /// and therefore whether other peers can discover it.
    ///
    /// `isTailscreenServerHostname` admits `tailscreen-…` but excludes
    /// `tailscreen-client-…`, so a pure viewer is deliberately invisible in
    /// everyone's screen list. An app that can also *share* has to be visible,
    /// or nobody could ever pick it.
    public enum NodeRole: Sendable {
        /// Ephemeral, undiscoverable — a viewer that only ever watches.
        case viewerOnly
        /// Discoverable as a long-lived instance, under
        /// `TailscreenInstance.serverHostnamePrefix + name`. Use for a host that
        /// can share. Note the consequence: it appears in other peers' lists
        /// even while idle, exactly as the macOS app does — the "only screens
        /// being shared" filter is what distinguishes idle from sharing, via the
        /// metadata probe rather than by hiding the node.
        case shareCapable(name: String)
    }
    public var nodeRole: NodeRole = .viewerOnly

    public init(
        hostname: String,
        port: UInt16 = 7447,
        authKey: String? = nil,
        controlURL: String = kDefaultControlURL,
        statePath: String,
        caps: ScreenShareCaps = [.nack, .receiverReport, .fec],
        nodeRole: NodeRole = .viewerOnly
    ) {
        self.hostname = hostname
        self.port = port
        self.authKey = authKey
        self.controlURL = controlURL
        self.statePath = statePath
        self.caps = caps
        self.nodeRole = nodeRole
    }
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
/// MainActor-isolated: the GTK viewer services this transport loop on its main
/// thread (swift-cross-ui ticks `RunLoop.main`), and pinning to the main actor
/// makes the `recv`/`send`/`tick` loop and every sink call run on one executor,
/// matching the non-`Sendable` contract of
/// `ViewerSession`.
/// A Tailscreen sharer discovered on the tailnet — the picker's row model.
/// A deliberately small value type (not `TailscreenPeer`) so the GTK app
/// depends only on `TailscreenViewerTsnet`, not the whole transport package.
/// `tailscaleIP` is the dial target: dialing by IP (not hostname) also sidesteps
/// the `from == dest` hostname-mismatch limitation the CLI host path warns about.
public struct DiscoveredSharer: Sendable, Identifiable, Equatable {
    public let id: String
    public let hostname: String
    public let tailscaleIP: String
    public let isOnline: Bool

    public init(id: String, hostname: String, tailscaleIP: String, isOnline: Bool) {
        self.id = id
        self.hostname = hostname
        self.tailscaleIP = tailscaleIP
        self.isOnline = isOnline
    }
}

@MainActor
public final class TsnetTransport {
    private let logger = StderrLogger()

    /// The brought-up ephemeral node, retained between `prepare` (+ optional
    /// `discoverPeers`) and `run` so a picker flow can list sharers on the live
    /// node before choosing one to dial. `run` brings it up itself if a caller
    /// skips `prepare` (the direct-host path, which dials without discovery).
    private var preparedNode: TailscaleNode?

    /// The Tailscale login/identity the prepared node authenticated as (e.g.
    /// "user@github"), resolved during `prepare`. nil before bring-up or after
    /// `teardown`. A GUI host uses it to label the active account.
    public private(set) var accountIdentity: String?

    public init() {}

    /// Keep the tsnet node up when a viewing session ends, instead of taking it
    /// down with the session.
    ///
    /// A viewer-only app wants the default: the node exists for exactly as long
    /// as the session that needs it. An app that *also shares* can't work that
    /// way — its sharer must stay reachable between viewing sessions, and both
    /// halves must ride ONE node so the app presents a single tailnet identity
    /// (the macOS app does this by owning the node in `AppState` and passing it
    /// to both the server and the client). Set this before `run`.
    public var retainsNodeAcrossSessions = false

    /// The tsnet hostname and ephemerality a role implies. Pure, so the
    /// discovery-visibility contract can be tested without a tailnet: a
    /// viewer-only node MUST fail `isTailscreenServerHostname` (else transient
    /// watchers clutter every peer's screen list) and a share-capable one MUST
    /// pass it (else nobody can ever pick this host).
    /// `nonisolated` because it's pure — the transport is `@MainActor` for its
    /// loop, but this decision needs no actor and shouldn't force tests onto one.
    nonisolated static func nodeIdentity(
        for role: ViewerConfig.NodeRole, uniqueSuffix: String
    ) -> (hostName: String, ephemeral: Bool) {
        switch role {
        case .viewerOnly:
            return ("\(TailscreenInstance.viewerHostnamePrefix)\(uniqueSuffix.prefix(8))", true)
        case .shareCapable(let name):
            // Non-ephemeral on purpose: an ephemeral node vanishes from the
            // tailnet the moment it goes down, which is wrong for a host a peer
            // may come back to.
            return ("\(TailscreenInstance.serverHostnamePrefix)\(name)", false)
        }
    }

    /// The live node, for a host that needs to lend it to something else —
    /// notably `TailscaleScreenShareServer(existingNode:)`. Non-nil only
    /// between `prepare` and `teardown`.
    public var liveNode: TailscaleNode? { preparedNode }

    /// Bring up the ephemeral tsnet node (interactive login supported) without
    /// starting a session. Idempotent — a second call while a node is live is a
    /// no-op. Lets a host bring the node up, discover sharers, and only then
    /// choose one to `run` against. Only the state/auth/control fields of
    /// `config` are used here (not `hostname`, which is the later dial target).
    ///
    /// - Parameter onLoginURL: where an interactive-login URL is surfaced
    ///   (default: the stderr banner + best-effort `xdg-open`). A GUI host
    ///   passes its own to show the URL in-window.
    public func prepare(
        config: ViewerConfig,
        onLoginURL: (@Sendable (URL) -> Void)? = nil
    ) async throws {
        guard preparedNode == nil else { return }
        try? FileManager.default.createDirectory(
            atPath: config.statePath, withIntermediateDirectories: true)

        // Node identity follows the role. A viewer-only node is ephemeral and
        // named with `viewerHostnamePrefix`, which peer discovery excludes, so
        // a transient watcher never shows up as a connectable screen. A
        // share-capable node must be discoverable, so it registers under
        // `serverHostnamePrefix` instead — and stays non-ephemeral, since an
        // ephemeral node disappears from the tailnet the moment it goes down,
        // which is wrong for something a peer may reconnect to.
        let nodeID = Self.nodeIdentity(for: config.nodeRole, uniqueSuffix: UUID().uuidString)
        let hostName = nodeID.hostName
        let ephemeral = nodeID.ephemeral
        let node = try TailscaleNode(
            config: Configuration(
                hostName: hostName,
                path: config.statePath,
                authKey: config.authKey,
                controlURL: config.controlURL,
                ephemeral: ephemeral
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
            watcher.onBrowseToURL = { url in
                if let onLoginURL { onLoginURL(url) } else { Self.surfaceLoginURL(url) }
            }
            try await watcher.startWatching(node: node)
            authWatcher = watcher
            logger.log("No auth key set — waiting for interactive browser login…")
        }

        logger.log("Bringing up tsnet node \(hostName)…")
        // Stop the auth watcher on failure too: it subscribed the IPN bus
        // before `up()`, and its MessageProcessor keeps running (retaining the
        // node) unless `stopWatching()` cancels it — a leak on the interactive-
        // login path if `up()` throws.
        do {
            try await node.up()
        } catch {
            authWatcher?.stopWatching()
            throw error
        }
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
        accountIdentity = auth.userProfile?.loginName

        preparedNode = node
    }

    /// List Tailscreen sharers on the tailnet (requires `prepare` first).
    /// One-shot seed from `backendStatus` — enough to populate a picker; the
    /// live IPN-bus refresh is a follow-up. Excludes offline peers is left to
    /// the caller (the row carries `isOnline`).
    public func discoverPeers() async throws -> [DiscoveredSharer] {
        guard let node = preparedNode else { throw TailscaleError.badInterfaceHandle }
        let discovery = TailscalePeerDiscovery()
        try await discovery.startDiscovery(node: node)
        return discovery.availablePeers.map {
            DiscoveredSharer(
                id: $0.id, hostname: $0.hostname,
                tailscaleIP: $0.tailscaleIP, isOnline: $0.isOnline)
        }
    }

    /// Fetch a discovered sharer's live share metadata (name / resolution /
    /// `isSharing`) over TCP/7447 using the prepared node — the fetch half of the
    /// picker's "which screens are actually being shared" annotations. Lazy: the
    /// caller decides when to dial (typically right after discovery + on refresh).
    /// All failure modes (no node, dial/connect failure, timeout, legacy peer)
    /// collapse to nil = status-unknown, never "not sharing".
    public func fetchMetadata(ip: String) async -> TailscreenMetadata? {
        guard let node = preparedNode else { return nil }
        return await TailscreenMetadataClient.fetchMetadata(fromIP: ip, via: node)
    }

    /// Bring the current node down and clear it so a later `prepare` can bring up
    /// a fresh one — e.g. under a different state directory when switching
    /// profiles. A no-op if no node is up. (`run`'s own `defer` clears the node
    /// on session exit; this is the picker-idle teardown path.)
    public func teardown() async {
        if let node = preparedNode {
            try? await node.down()
        }
        preparedNode = nil
        accountIdentity = nil
    }

    /// Connect and run until the sharer says goodbye or `shouldClose` fires.
    ///
    /// If `config.authKey` is nil, brings the node up via interactive browser
    /// login (the login URL is surfaced on stderr / best-effort opened);
    /// otherwise the key joins headlessly.
    ///
    /// - Parameters:
    ///   - config: connection + capability parameters.
    ///   - decoder: the concrete video decoder (FFmpeg on Linux).
    ///   - videoSink: where decoded frames go (the GTK GLArea).
    ///   - audioSink: where decoded audio goes (ALSA), or nil.
    ///   - shouldClose: polled each loop; returning true ends the session (the
    ///     host's window-close hook).
    ///   - backChannelHandlers: inbound annotation / control-grant callbacks for
    ///     the TCP back-channel (empty by default).
    ///   - onBackChannelReady: called once the outbound TCP back-channel is
    ///     dialing, handing the host a `ViewerBackChannel` to send annotation
    ///     ops / control requests / input events (nil ⇒ receive-only).
    public func run(
        config: ViewerConfig,
        decoder: VideoDecoding,
        videoSink: VideoSink,
        audioSink: AudioSink?,
        shouldClose: @escaping () -> Bool,
        backChannelHandlers: ViewerBackChannel.Handlers = ViewerBackChannel.Handlers(),
        onBackChannelReady: (@Sendable (ViewerBackChannel) -> Void)? = nil,
        onAdmitted: (@Sendable (ScreenShareCaps) -> Void)? = nil,
        onAwaitingApproval: (@Sendable () -> Void)? = nil,
        onDeclined: (@Sendable () -> Void)? = nil
    ) async throws {
        // Bring the node up if a caller skipped `prepare` (the direct-host
        // path); a picker host that already called `prepare` + `discoverPeers` reuses
        // the live node (this is a no-op then).
        try await prepare(config: config)
        guard let node = preparedNode else { throw TailscaleError.badInterfaceHandle }
        // Clear the node reference on EVERY exit path, not just the clean loop
        // exit below. `preparedNode` lives on the process-lifetime transport, so
        // a throw between here and that tail (addrs / tailscale / listener bind /
        // back-channel start) would otherwise pin the node forever — its last
        // reference never drops, so `deinit` (the real `tailscale_close`) never
        // runs, leaking the tsnet node and wedging any retry on the stale one.
        // Clearing `preparedNode` on every exit path is what stops a throw
        // between here and the tail from pinning the node forever. When the
        // host retains the node, `retainedNode` carries it back across that
        // same defer rather than defeating it.
        var retainedNode: TailscaleNode?
        defer { preparedNode = retainedNode }
        // Claim the node for retention immediately, not at the clean exit:
        // a throw partway through a session must not orphan a node that a
        // sharer on this same host is still serving from. Dropping it here
        // would leave `preparedNode == nil` while the node object stays alive
        // behind the sharer's reference, so the next `prepare()` would bring up
        // a SECOND node — two tailnet identities for one app, which is exactly
        // what sharing one node is meant to avoid.
        if retainsNodeAcrossSessions { retainedNode = node }

        let ips = try await node.addrs()
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

        // Outbound TCP back-channel (annotations / control), reusing the same
        // node handle. It dials + reconnects on its own task, so failure here
        // never blocks the video path — a viewer with a dead back-channel still
        // watches. Handed to the host so its chrome can send strokes/requests.
        let backChannel = ViewerBackChannel(
            tailscale: tailscale, host: config.hostname, port: config.port,
            handlers: backChannelHandlers, logger: logger)
        await backChannel.start()
        onBackChannelReady?(backChannel)
        // Teardown backstop for every exit path (incl. a throw before the
        // normal end): cancel the back-channel's loop + close its socket. Kept
        // fire-and-forget on purpose — `stop()` can park up to the receive
        // poll interval closing the live connection, and blocking session
        // teardown on that would freeze the window close. The unstructured Task
        // is independently rooted so it still runs to completion, and
        // `node.down()` below tears the whole node (and this fd) down
        // regardless, so ordering here is immaterial.
        defer { Task { await backChannel.stop() } }

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
                onAwaitingApproval?()
            }
            if let ssrc = session.assignedSSRC, !loggedAdmitted {
                logger.log(
                    "▶ Admitted by sharer (ssrc=\(ssrc), serverCaps=\(session.serverCaps.rawValue)) — awaiting video…"
                )
                loggedAdmitted = true
                // Surface the sharer's caps so the host can gate its chrome
                // (the Request-Control button rides `.remoteControl`, the
                // annotation toolbar rides `.annotations`) — same gating the
                // mac viewer applies from the HELLO_ACK.
                onAdmitted?(session.serverCaps)
            }
            do {
                let (datagram, from) = try await listener.recv(timeout: 250)
                guard !datagram.isEmpty else { continue }
                // The sharer is the only expected sender (it learned our addr
                // from the HELLO); ignore anything else.
                // KNOWN LIMITATION (only affects the direct-host path; the
                // picker dials the resolved tailnet IP, which does match):
                // `dest` is the dialed string, so if `config.hostname` is a
                // Tailscale *hostname* rather than a tailnet IP, `from` (the
                // sharer's resolved IP) won't string-match and video is dropped.
                // Dial by tailnet IP until this matches on the resolved peer.
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
            onDeclined?()
        } else if pipeline.isStopped {
            logger.log("▶ Sharer ended the session.")
        } else {
            logger.log("▶ Viewer window closed.")
        }
        await listener.close()
        // When retaining, `teardown()` is the only thing that takes the node
        // down — `retainedNode` was claimed at entry, so nothing to do here.
        if !retainsNodeAcrossSessions {
            try? await node.down()
        }
        // `preparedNode = nil` is handled by the `defer` above (which also
        // covers the throwing exit paths).
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
    nonisolated static func formatAddr(host: String, port: UInt16) -> String {
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

    func present(_ frame: any DecodedFrame) {
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
