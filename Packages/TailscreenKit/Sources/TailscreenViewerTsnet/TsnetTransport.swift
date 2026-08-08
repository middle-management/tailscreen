import Foundation
import TailscaleKit
import TailscreenAudio
import TailscreenProtocol
import TailscreenTransport
import TailscreenViewer

/// Connection parameters for the tsnet-backed viewer transport.
public struct ViewerConfig: Sendable {
    /// Sharer host to dial — a Tailscale hostname or tailnet IP.
    public var hostname: String
    /// UDP/TCP port the sharer listens on.
    public var port: UInt16 = NetworkConfig.tailscreenPort
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
        port: UInt16 = NetworkConfig.tailscreenPort,
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
///
/// Deliberately NOT `TailscreenTransport.PrintLogSink` (the package's shared
/// print sink): that one writes to stdout, and the stderr destination here is
/// the point — viewer executables reserve stdout for data.
struct StderrLogger: LogSink {
    var logFileHandle: Int32? { STDERR_FILENO }
    func log(_ message: String) {
        FileHandle.standardError.write(Data("[tsnet] \(message)\n".utf8))
    }
}

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
    /// Tailscale ACL tags ("tag:server"), straight off the netmap
    /// `TailscalePeerDiscovery` already parses — the tag axis of
    /// `PeerListFilter`. Empty for untagged nodes, which is a filterable state
    /// in its own right (`includeUntagged`), not an absence of data.
    ///
    /// Defaulted in the initialiser so the field is additive: the GTK app's
    /// `--ui-preview` seeds `DiscoveredSharer`s by hand, and a required
    /// parameter would have made a display-only field a breaking change.
    public let tags: [String]
    /// The path this peer's traffic is taking, as `PeerRoute.from` classifies
    /// it. Straight off the same LocalAPI status seed `TailscalePeerDiscovery`
    /// already parses — there is no probe behind this and no wire change.
    ///
    /// Note the seed, not the netmap: netmap ticks carry no path information,
    /// so `TailscalePeerDiscovery.publishMerged` deliberately preserves these
    /// fields rather than letting a tick blank them.
    public let route: PeerRoute

    public init(
        id: String, hostname: String, tailscaleIP: String, isOnline: Bool,
        tags: [String] = [], route: PeerRoute = .unknown
    ) {
        self.id = id
        self.hostname = hostname
        self.tailscaleIP = tailscaleIP
        self.isOnline = isOnline
        self.tags = tags
        self.route = route
    }
}

/// The shared peer-list projection (`PeerListFilter.narrow` / `knownTags`)
/// applies to this type unchanged, so both swift-cross-ui hubs derive their
/// filtered list and their tag menu from the same code macOS does.
extension DiscoveredSharer: PeerListRow {}

/// What one lazy peer probe found: the peer's share status, and how long the
/// round trip took.
///
/// The latency rides along because it is FREE — the metadata fetch is already
/// a TCP round trip over the live Tailscale path, so timing it costs one
/// clock read rather than a second dial. It is an estimate over that path
/// including dial and service time, not a wire ping, which is why
/// `ConnectionQualityTier`'s thresholds are as generous as they are.
///
/// Both fields are independently optional: a peer can answer (status known)
/// while the timing is discarded, and a peer that never answers has neither.
public struct PeerProbe: Sendable {
    public let metadata: TailscreenMetadata?
    public let latencyMs: Int?

    public init(metadata: TailscreenMetadata?, latencyMs: Int?) {
        self.metadata = metadata
        self.latencyMs = latencyMs
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
/// MainActor-isolated: the GTK and WinUI viewers service this transport loop on
/// their main thread (swift-cross-ui ticks `RunLoop.main`), and pinning to the
/// main actor makes the `recv`/`send`/`tick` loop and every sink call run on one
/// executor, matching the non-`Sendable` contract of `ViewerSession`. The socket
/// read is deliberately NOT on that actor — see `DatagramInbox` and the
/// `Task.detached` below, which is load-bearing and easy to undo by accident.
@MainActor
public final class TsnetTransport {
    private let logger = StderrLogger()

    /// How often to report a blank viewer's inbound/decode tallies. Slow on
    /// purpose: this fires only while admitted with nothing decoded, and a
    /// stalled stream is diagnosed from a handful of lines, not a stream of them.
    private static let blankViewerDiagnosticIntervalNs: UInt64 = 3_000_000_000

    /// Datagrams to drain from the socket per pass of the run loop before
    /// yielding back to `tick` and `shouldClose`.
    ///
    /// The loop used to take exactly ONE datagram per pass, which made the
    /// inbound packet rate equal to the loop's own iteration rate — everything
    /// else in the pass (the tick, the host's UI work on the same actor) set the
    /// ceiling. Measured on the Windows viewer: 15.6 datagrams/s against a
    /// stream sending several hundred, so ~96% of it overflowed the socket
    /// buffer and was discarded by the OS before `recv` ever saw it. Every
    /// frame arrived with holes, so every access unit was dropped as torn and
    /// the viewer stayed blank with a perfectly healthy-looking wire.
    ///
    /// 256 clears a keyframe's packet count in a couple of passes while keeping
    /// the tick cadence well inside the reorder buffer's gap hold — the cap
    /// exists so a flood can't starve `tick` (which owns NACK/PLI/RR) or delay
    /// noticing that the window closed, not to limit throughput.
    private static let maxDatagramsPerReceivePass = 256

    /// `PeerRoute` for a log line. Spells the relay region out because "relayed
    /// via fra" and "relayed via lax" are different stories about the same
    /// symptom, and `.relay(region:)`'s default reflection is noisier than
    /// either.
    private static func describe(_ route: PeerRoute) -> String {
        switch route {
        case .direct: return "direct"
        case .relay(let region): return "DERP relay (\(region))"
        case .unknown: return "unknown"
        }
    }

    /// How long the loop parks when the inbox came back empty. With the socket
    /// on its own task there is no blocking `recv` left in the loop to pace it,
    /// and 5 ms keeps the tick cadence (NACK aging, RR, `shouldClose`) far
    /// inside every deadline that depends on it while costing an idle viewer
    /// almost nothing. Skipped entirely whenever datagrams were drained.
    private static let idlePollIntervalMs = 5

    /// The brought-up ephemeral node, retained between `prepare` (+ optional
    /// `discoverPeers`) and `run` so a picker flow can list sharers on the live
    /// node before choosing one to dial. `run` brings it up itself if a caller
    /// skips `prepare` (the direct-host path, which dials without discovery).
    private var preparedNode: TailscaleNode?

    /// The live node, for a host that also SHARES.
    ///
    /// `TailscaleScreenShareServer.start(existingNode:)` takes this so the
    /// sharer runs on the same tailnet identity the user signed in with. The
    /// alternative — letting the server bring up its own — needs a second state
    /// directory, and a state directory holds a machine key, so it is a second
    /// machine: a second interactive browser login the user is never prompted
    /// for, and a share that silently never joins the tailnet. That is exactly
    /// what the Windows app did before it read this.
    ///
    /// Pair it with `retainsNodeAcrossSessions` and a `.shareCapable` role.
    public var sharedNode: TailscaleNode? { preparedNode }

    /// The Tailscale login/identity the prepared node authenticated as (e.g.
    /// "user@github"), resolved during `prepare`. nil before bring-up or after
    /// `teardown`. A GUI host uses it to label the active account.
    public private(set) var accountIdentity: String?

    /// The tailnet the prepared node joined (e.g. "example.org.github"),
    /// resolved during `prepare`. nil before bring-up, after `teardown`, or
    /// when the control plane does not report one.
    ///
    /// Distinct from `accountIdentity` on purpose, and the more useful of the
    /// two in a header: the login says *who* you are, the tailnet says *which
    /// namespace the screen list belongs to*, and it is the tailnet that
    /// explains why an expected machine is missing. The macOS hub shows the
    /// tailnet for exactly this reason, falling back to the login when the
    /// control plane reports no name (headscale often does not).
    public private(set) var tailnetName: String?

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

    /// Which build the host is, e.g. `"a1b2c3d release"`. Logged once per
    /// session and nowhere else.
    ///
    /// Set this. Two separate rounds of blank-viewer diagnosis were spent on a
    /// log produced by a binary that predated the fix being tested, and neither
    /// the log nor the app said so — "the new counter isn't there" and "you are
    /// running last hour's exe" are the same observation until something names
    /// the commit. The Windows app has `BuildInfo.summary` for this and was
    /// showing it only in a window footer, where a stderr log never sees it.
    ///
    /// Optional because the transport cannot know it: the stamp is a per-app
    /// build-time substitution, so it has to arrive from the host.
    public var buildIdentity: String?

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
        // Bring-up runs OFF this actor. `TsnetTransport` is `@MainActor` for
        // its steady-state loop (see the type's note), and a GUI host's
        // `Task { try await transport.prepare(...) }` therefore executes the
        // whole of bring-up on the UI thread. That was enough to hang the
        // Windows app outright: the window painted "Starting Tailscale…" and
        // then stopped answering messages, so the login URL it was waiting for
        // could never be shown — a deadlock the user cannot even read an error
        // out of.
        //
        // Nothing here needs the main actor. Every step is a call into the Go
        // c-archive or an await on the node actor, and the results are three
        // values assigned back below. `nonisolated static` puts it on the
        // global executor, which is where multi-second work belongs.
        let brought = try await Self.bringUpNode(config: config, onLoginURL: onLoginURL)
        preparedNode = brought.node
        accountIdentity = brought.identity
        tailnetName = brought.tailnet
    }

    /// The bring-up itself: `TsnetNodeFactory.bringUp` (state dir, node,
    /// optional IPN-bus login watcher with leak-safe teardown, `up()`) plus
    /// this transport's identity lookup.
    ///
    /// `nonisolated` so it does not inherit `@MainActor` — see `prepare`. The
    /// factory logs each step before it starts (`stepLogPrefix: "prepare"`),
    /// because the failure this was written for is a *hang*, and a log line
    /// that only prints on success tells you nothing about where a hang is.
    ///
    /// `up()` is deliberately `.unbounded` even when an auth key is present —
    /// this transport has always left it unbounded, unlike the sharer and the
    /// macOS app, which bound the auth-keyed path to 60 s.
    private nonisolated static func bringUpNode(
        config: ViewerConfig,
        onLoginURL: (@Sendable (URL) -> Void)?
    ) async throws -> (node: TailscaleNode, identity: String?, tailnet: String?) {
        let logger = StderrLogger()

        // Node identity follows the role. A viewer-only node is ephemeral and
        // named with `viewerHostnamePrefix`, which peer discovery excludes, so
        // a transient watcher never shows up as a connectable screen. A
        // share-capable node must be discoverable, so it registers under
        // `serverHostnamePrefix` instead — and stays non-ephemeral, since an
        // ephemeral node disappears from the tailnet the moment it goes down,
        // which is wrong for something a peer may reconnect to.
        let nodeID = Self.nodeIdentity(for: config.nodeRole, uniqueSuffix: UUID().uuidString)
        let hostName = nodeID.hostName
        let node = try await TsnetNodeFactory.bringUp(
            spec: TsnetNodeFactory.Spec(
                hostName: hostName,
                ephemeral: nodeID.ephemeral,
                statePath: config.statePath,
                authKey: config.authKey,
                controlURL: config.controlURL),
            logger: logger,
            timeout: .unbounded,
            onLoginURL: { url in
                // ALWAYS log it, then hand it to the host.
                //
                // The host's callback is a GUI update, and a GUI update is
                // exactly what is unavailable when the app has stopped
                // answering — which is the state this URL is needed to get
                // out of, since `up()` will not return until someone visits
                // it. A line on stderr is readable from the console the user
                // launched from even then, so a frozen window becomes an
                // inconvenience rather than a dead end.
                Self.surfaceLoginURL(url)
                onLoginURL?(url)
            },
            stepLogPrefix: "prepare")

        logger.log("prepare: up() returned — reading addresses")
        let ips = try await node.addrs()
        logger.log("prepare: tsnet up — ip4=\(ips.ip4 ?? "-") ip6=\(ips.ip6 ?? "-")")

        // Surface which tailnet identity we actually joined. A viewer that
        // authenticated into the wrong tailnet looks identical to a connected
        // one that just isn't getting frames — printing the account here turns
        // that into an obvious mismatch. Best-effort; never blocks the session.
        logger.log("prepare: resolving account identity")
        let auth = await TailscaleAuth()
        await auth.checkAuthStatus(node: node)
        // Read once and reuse: `userProfile` is actor-isolated, so from this
        // nonisolated context each access is a separate hop.
        let loginName = await auth.userProfile?.loginName
        let identity = loginName ?? "unknown account"
        // The tailnet is a second best-effort read off the same status the
        // discovery seed already uses. Empty is a real answer from some control
        // planes (headscale commonly reports none), so it is normalised to nil
        // here rather than surfacing as a blank header.
        let statusClient = LocalAPIClient(localNode: node, logger: logger)
        let tailnet = try? await statusClient.backendStatus().CurrentTailnet?.Name
        let namedTailnet = (tailnet?.isEmpty ?? true) ? nil : tailnet
        logger.log(
            "▶ Connected as \(identity) on \(namedTailnet ?? "an unnamed tailnet") "
                + "— node \(hostName) @ \(ips.ip4 ?? ips.ip6 ?? "?")")

        return (node, loginName, namedTailnet)
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
                tailscaleIP: $0.tailscaleIP, isOnline: $0.isOnline, tags: $0.tags,
                route: PeerRoute.from(curAddr: $0.curAddr, relay: $0.relay))
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

    /// `fetchMetadata`, timed.
    ///
    /// The sweep that populates the sharing chip is already a TCP round trip
    /// over the live path, so the latency behind the peer-detail pane's
    /// quality dot is one clock read rather than a second probe. A peer that
    /// does not answer reports neither status nor latency — never a latency
    /// for a round trip that did not complete, which would read as a fast link
    /// to a machine that is gone.
    public func probePeer(ip: String) async -> PeerProbe {
        guard let node = preparedNode else { return PeerProbe(metadata: nil, latencyMs: nil) }
        let startNs = DispatchTime.now().uptimeNanoseconds
        let metadata = await TailscreenMetadataClient.fetchMetadata(fromIP: ip, via: node)
        guard metadata != nil else { return PeerProbe(metadata: nil, latencyMs: nil) }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- startNs
        return PeerProbe(metadata: metadata, latencyMs: Int(elapsedNs / 1_000_000))
    }

    /// Ask a peer to share its screen, and park until it answers.
    ///
    /// Sibling of `fetchMetadata` — same prepared node, same port, the other
    /// half of the same TCP channel — but the call parks for up to
    /// `responseTimeout`, because the answer comes back on the connection the
    /// request went out on rather than by a dial-back. Callers should hold it
    /// in a cancellable task and show that the ask is outstanding; a UI that
    /// awaits this inline looks frozen for two minutes.
    ///
    /// No node reads as `.noAnswer` rather than throwing, which is the same
    /// thing a peer running an older build produces: nothing was refused, and
    /// nothing is going to happen.
    public func requestToShare(ip: String, from hostname: String) async -> ShareRequestOutcome {
        guard let node = preparedNode else { return .noAnswer }
        do {
            return try await TailscreenRequestToShareClient.requestToShare(
                toIP: ip, from: hostname, via: node)
        } catch {
            return .noAnswer
        }
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
        tailnetName = nil
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
    ///   - onDecoderResetNeeded / onDecodeFatal: opt-in to the shared
    ///     decode-failure escalation ladder (see
    ///     `ViewerSession.onDecoderResetNeeded` / `.onDecodeFatal`): reset the
    ///     concrete decoder at the ladder's wedged-decoder rung, surface a
    ///     user-visible session error at its terminal rung. Both nil (the
    ///     default) keeps the flat decode-failure → PLI behavior.
    /// Run one viewing session to completion.
    ///
    /// `onVoiceReady` is MainActor-isolated, unlike the other callbacks here:
    /// the uplink is a session-scoped object the host holds for the session's
    /// lifetime, and every host that holds one holds it in main-actor UI
    /// state. This transport is already MainActor-isolated, so the isolation
    /// costs nothing and saves each host a hop that would let the session end
    /// first.
    ///
    /// `onEnded` fires once, just before `run` returns, for every ending the
    /// USER did not ask for — sharer stop, deny/kick, idle timeout, socket
    /// death — so the host can explain the ending instead of the window
    /// silently reverting. It does NOT fire when `shouldClose` ended the
    /// session: the person who closed the window needs no explanation.
    /// `wasAdmitted` is whether an SSRC had been assigned, which is how a host
    /// words the one HELLO_DENY byte as "declined" (still at the approval
    /// placard) vs "disconnected by sharer" (already watching) — the same
    /// context split the macOS viewer applies. `onDeclined` still fires for a
    /// deny, before `onEnded`, so existing callers keep working.
    public func run(
        config: ViewerConfig,
        decoder: VideoDecoding,
        videoSink: VideoSink,
        audioSink: AudioSink?,
        shouldClose: @escaping () -> Bool,
        backChannelHandlers: ViewerBackChannel.Handlers = ViewerBackChannel.Handlers(),
        microphone: MicrophoneCapturing? = nil,
        onVoiceReady: (@MainActor @Sendable (VoiceUplink) -> Void)? = nil,
        onBackChannelReady: (@Sendable (ViewerBackChannel) -> Void)? = nil,
        onAdmitted: (@Sendable (ScreenShareCaps) -> Void)? = nil,
        onAwaitingApproval: (@Sendable () -> Void)? = nil,
        onDeclined: (@Sendable () -> Void)? = nil,
        onEnded: (@Sendable (ViewerCloseReason, _ wasAdmitted: Bool) -> Void)? = nil,
        onDecoderResetNeeded: (@MainActor () -> Void)? = nil,
        onDecodeFatal: (@MainActor () -> Void)? = nil
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
        // Name the build and the path before anything else can go wrong. Both
        // are things a blank-viewer log was read without and should not have
        // been: the build because a stale binary and a missing fix look
        // identical, the path because a DERP-relayed session has loss and RTT
        // characteristics a direct one does not, and every packet-loss
        // conclusion in this file's history was drawn without knowing which
        // it was.
        logger.log("▶ Build \(buildIdentity ?? "unknown") — viewer session starting")
        // Best-effort, and deliberately not fatal: one status seed, matched
        // against whatever string we dialed. `try?` because a viewer that can
        // reach the sharer must not lose the session to a failed diagnostic.
        let dialed = config.hostname
        let seededPeers = (try? await discoverPeers()) ?? []
        if let peer = seededPeers.first(where: { $0.tailscaleIP == dialed || $0.hostname == dialed }) {
            logger.log("▶ Path to \(peer.hostname): \(Self.describe(peer.route))")
        }

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
        // Decode-recovery ladder opt-in. The session fires these synchronously
        // from `receiveRTP`, which the loop below only ever calls on this
        // actor — `assumeIsolated` names that contract (a hop would be wrong:
        // the reset must land before the next access unit is decoded).
        if let onDecoderResetNeeded {
            pipeline.session.onDecoderResetNeeded = {
                MainActor.assumeIsolated { onDecoderResetNeeded() }
            }
        }
        if let onDecodeFatal {
            pipeline.session.onDecodeFatal = {
                MainActor.assumeIsolated { onDecodeFatal() }
            }
        }

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

        // Inbound, genuinely off this actor. The socket is read by its own task
        // and handed over through a bounded queue the loop drains synchronously,
        // so how fast the UI gets back around the loop no longer decides how
        // many packets survive. See `DatagramInbox` for the measurements.
        //
        // `Task.detached`, NOT `Task` — and that is the entire difference
        // between this working and not. `Task { }` created in an actor-isolated
        // context INHERITS that isolation, so the first version of this ran its
        // `recv` loop on the MainActor, interleaving with the run loop on one
        // executor instead of escaping it. It measured 15.6 datagrams/s on the
        // Windows viewer — exactly the rate the one-datagram-per-pass loop had
        // before any of this, and 5× WORSE than the plain batched drain it
        // replaced, because the two now took turns on the same actor with a
        // 5 ms idle sleep between them.
        //
        // The `senderTask` above is not the precedent it looks like: it is
        // `Task { }` in this same @MainActor scope, so it never crossed an
        // isolation boundary either and proved nothing about `PacketListener`.
        // The real evidence is `TailscaleScreenShareServer` — `@unchecked
        // Sendable`, not actor-isolated — which captures its `PacketListener`
        // in a bare `Task { }` and sends from it. That closure is `@Sendable`,
        // so the type must be `Sendable` for shipped code to compile.
        let inbox = DatagramInbox()
        let receiveFailure = ReceiveFailureFlag()
        let receiveLogger = logger
        let receiverTask = Task.detached {
            var tally = TransportEndDecision.ReceiveFailureTally()
            while !Task.isCancelled {
                let recvStartNs = DispatchTime.now().uptimeNanoseconds
                do {
                    let (datagram, from) = try await listener.recv(timeout: 250)
                    tally.consecutiveErrors = 0
                    // Empty is how this wrapper reports "nothing arrived before
                    // the timeout" on some paths; a throw is how it reports it
                    // on others. Neither is an error.
                    guard !datagram.isEmpty else { continue }
                    inbox.push(DatagramInbox.Datagram(payload: datagram, from: from))
                } catch {
                    guard !Task.isCancelled else { break }
                    // `readFailed` covers both the benign poll timeout and a
                    // dead socket; errno never crosses the bridge but wall time
                    // does — a genuine timeout only returns after the full poll
                    // interval, a dead socket fails in microseconds (the same
                    // classification the macOS receive loop applies).
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds &- recvStartNs
                    var benignTimeout = false
                    if case TailscaleError.readFailed = error {
                        benignTimeout = !ReceiveLoopPolicy.classifyReadFailedAsError(
                            elapsedNs: elapsedNs)
                    }
                    let nowNs = DispatchTime.now().uptimeNanoseconds
                    if TransportEndDecision.receiveFailureIsFatal(
                        &tally, benignTimeout: benignTimeout, nowNs: nowNs)
                    {
                        // The loop reads the flag on its next pass and ends the
                        // session with `.connectionLost`; this task's job is
                        // over — a socket this sick has nothing left to read.
                        receiveLogger.log(
                            "⚠ receive gave up (consecutive=\(tally.consecutiveErrors), "
                                + "window=\(tally.errorStampsNs.count)): \(error)"
                        )
                        receiveFailure.raise()
                        break
                    }
                    if !benignTimeout {
                        try? await Task.sleep(
                            nanoseconds: ReceiveLoopPolicy.retryDelayNs(
                                consecutiveErrors: tally.consecutiveErrors))
                    }
                }
            }
        }
        defer {
            receiverTask.cancel()
            inbox.close()
        }

        // The viewer's own voice, out through the same ordered queue the
        // control bytes use — one socket, one send order.
        //
        // Built here rather than by the host because the two things it needs
        // are both in this scope and nowhere else: the outbound queue, and the
        // SSRC the sharer assigns on admission. Deliberately NOT started yet
        // (see the admission block below) — there is nothing to send audio to
        // until this viewer is let in, and opening the microphone before then
        // would light somebody's mic indicator while they wait at an approval
        // prompt they may be denied at.
        var voiceUplink: VoiceUplink?
        if let microphone {
            do {
                let uplink = try VoiceUplink(
                    microphone: microphone, encoder: OpusVoiceEncoder(),
                    send: { outboundContinuation.yield($0) })
                // Muted until the host says otherwise, matching the macOS
                // viewer: joining a share must never put you on the air.
                uplink.isMuted = true
                voiceUplink = uplink
                onVoiceReady?(uplink)
            } catch {
                logger.log("⚠ Voice uplink unavailable (\(error)) — continuing without a mic")
            }
        }
        defer { voiceUplink?.stop() }

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
        // Blank-viewer diagnostics. Everything between admission and a first
        // frame fails silently (see `ViewerSession.Diagnostics`), so while a
        // session is admitted and has decoded nothing, say what arrived and what
        // became of it on a slow cadence. Once a frame lands this goes quiet for
        // the rest of the session.
        var lastDiagnosticNs = DispatchTime.now().uptimeNanoseconds
        // Datagrams from something other than the dialed sharer, which the guard
        // below drops. Counted because "no video" and "video from an address
        // that doesn't string-match `dest`" look identical from the outside —
        // and the guard is a documented known limitation.
        var datagramsFromOthers = 0
        var lastOtherSender = ""
        // Receive passes that hit the per-pass drain cap. Reported below because
        // a socket-drain ceiling is exactly what produced a blank viewer once
        // already, and a non-zero value names the cap as a suspect instead of
        // leaving it to be re-derived from arrival rates.
        var saturatedPasses = 0
        // A transport-diagnosed ending (idle timeout / socket death). The
        // wire-side endings live in `session.closeReason`; these two are ours
        // to notice, because the session owns no socket and no clock source.
        var transportEndReason: ViewerCloseReason?
        // Clock reading of the last datagram accepted from the sharer, for the
        // idle timeout. Seeded at loop entry so a sharer that never answers at
        // all still times out instead of freezing the window forever.
        var lastDatagramNs = DispatchTime.now().uptimeNanoseconds
        while !pipeline.isStopped && !shouldClose() {
            pipeline.tick(nowNs: DispatchTime.now().uptimeNanoseconds)
            let session = pipeline.session
            // The receive task raised the dead-socket flag: repeated genuine
            // recv errors, past both `ReceiveLoopPolicy` thresholds. Nothing
            // more will ever arrive, so end the session rather than tick
            // against an inbox that can only stay empty.
            if receiveFailure.isRaised {
                logger.log("▶ Receive path died — ending the session.")
                transportEndReason = .connectionLost
                break
            }
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
                // Now there is an SSRC to speak under, and somebody to speak
                // to. A failure to open the device is not fatal to the session:
                // the host hears about it through `VoiceUplink.onStopped` and
                // withholds the mic control.
                if let voiceUplink {
                    voiceUplink.setSSRC(ssrc)
                    do { try voiceUplink.start() } catch {
                        logger.log("⚠ Microphone did not start (\(error))")
                    }
                }
                // Surface the sharer's caps so the host can gate its chrome
                // (the Request-Control button rides `.remoteControl`, the
                // annotation toolbar rides `.annotations`) — same gating the
                // mac viewer applies from the HELLO_ACK.
                onAdmitted?(session.serverCaps)
            }
            // Admitted, but nothing on screen yet — report what the wire and the
            // decoder are actually doing. Silent once a frame has landed.
            if loggedAdmitted {
                let diagnostics = session.diagnostics
                let nowNs = DispatchTime.now().uptimeNanoseconds
                let sinceLast = nowNs &- lastDiagnosticNs
                if diagnostics.framesDecoded == 0, sinceLast >= Self.blankViewerDiagnosticIntervalNs {
                    lastDiagnosticNs = nowNs
                    var line = "⚠ no video decoded yet — \(diagnostics.summary)"
                    if datagramsFromOthers > 0 {
                        // The `from == dest` guard fired. If this is climbing
                        // while `video=0`, the sharer's media is arriving from an
                        // address that does not string-match the dialed one and
                        // is being dropped here, not upstream.
                        line +=
                            " droppedFromOthers=\(datagramsFromOthers) (last: \(lastOtherSender), dialed: \(dest))"
                    }
                    if saturatedPasses > 0 {
                        line += " saturatedPasses=\(saturatedPasses)"
                    }
                    // Inbox overflow means this actor is not consuming as fast
                    // as the socket is delivering — a consumer problem, and a
                    // different one from the socket ceiling this loop used to
                    // have. Depth rides along so a backlog that is merely deep
                    // reads differently from one that is losing.
                    let inboxDropped = inbox.droppedCount
                    if inboxDropped > 0 {
                        line += " inboxDropped=\(inboxDropped) inboxDepth=\(inbox.depth)"
                    }
                    logger.log(line)
                }
            }
            // Take a batch from the inbox rather than reading the socket here.
            // The cap bounds how long `tick` (NACK/PLI/RR) and `shouldClose` can
            // be starved by a burst; it is not a throughput limit — anything
            // left over is still queued and goes out on the next pass, which
            // starts immediately because a non-empty drain skips the idle wait.
            let batch = inbox.drain(max: Self.maxDatagramsPerReceivePass)
            if batch.count >= Self.maxDatagramsPerReceivePass { saturatedPasses += 1 }
            for datagram in batch {
                // The sharer is the only expected sender (it learned our addr
                // from the HELLO); ignore anything else.
                // KNOWN LIMITATION (only affects the direct-host path; the
                // picker dials the resolved tailnet IP, which does match):
                // `dest` is the dialed string, so if `config.hostname` is a
                // Tailscale *hostname* rather than a tailnet IP, `from` (the
                // sharer's resolved IP) won't string-match and video is dropped.
                // Dial by tailnet IP until this matches on the resolved peer.
                guard datagram.from == dest else {
                    datagramsFromOthers += 1
                    lastOtherSender = datagram.from
                    continue
                }
                lastDatagramNs = DispatchTime.now().uptimeNanoseconds
                pipeline.receive(datagram.payload)
            }
            // Idle timeout: a sharer that has gone silent past the threshold is
            // gone (crashed, or its BYE was lost). Only datagrams accepted from
            // the sharer feed `lastDatagramNs` — same rule as the macOS loop —
            // and the wait at the approval prompt is exempt, since a sharer
            // deliberating over Accept/Deny legitimately sends nothing.
            if TransportEndDecision.idleTimedOut(
                nowNs: DispatchTime.now().uptimeNanoseconds,
                lastDatagramNs: lastDatagramNs,
                isPendingApproval: session.isPendingApproval)
            {
                logger.log("▶ Nothing from the sharer for >idle timeout — assuming it is gone.")
                transportEndReason = .timedOut
                break
            }
            // Pacing. `recv`'s timeout used to be what kept this loop from
            // spinning; with the socket on its own task, an empty inbox is the
            // idle signal and this sleep is the tick cadence. Only taken when
            // nothing arrived, so it costs a busy session nothing.
            //
            // Crude on purpose for a first cut: the loop still polls rather
            // than being woken by the receive task, which is worth replacing
            // with a proper signal — see the PR description.
            if batch.isEmpty {
                try? await Task.sleep(for: .milliseconds(Self.idlePollIntervalMs))
            }
        }
        // Resolve the ending. Wire-side causes come from the session
        // (`closeReason`: deny/kick, sharer stop), transport-side ones from the
        // loop above (idle timeout, socket death); a user-initiated close
        // (`shouldClose`) has neither and fires nothing — the person who
        // closed the window needs no explanation. `wasAdmitted` is how the
        // host words the single HELLO_DENY byte: no SSRC yet ⇒ declined at the
        // gate, SSRC assigned ⇒ kicked mid-watch.
        let wasAdmitted = pipeline.session.assignedSSRC != nil
        if pipeline.session.wasDenied {
            logger.log("▶ Sharer declined this viewer.")
            onDeclined?()
        } else if pipeline.isStopped {
            logger.log("▶ Sharer ended the session.")
        } else if transportEndReason == nil {
            logger.log("▶ Viewer window closed.")
        }
        if let reason = pipeline.closeReason ?? transportEndReason {
            onEnded?(reason, wasAdmitted)
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

    /// Surface an interactive-login URL: print it prominently on stderr, so it
    /// stands out from the `[tsnet]` log stream — the common case is a headless
    /// guest where the user copies it to a browser on another machine.
    ///
    /// Opening the URL locally is the HOST's job, via the `onLoginURL`
    /// callback that arrives alongside this banner (the GTK app shows it with
    /// an explicit open button; the Windows app opens via `cmd /c start`).
    /// This used to also spawn `xdg-open` behind a `DISPLAY` check — the one
    /// platform-specific process spawn in the package, a silent no-op on
    /// Windows, and a second unprompted browser open on a Linux desktop where
    /// the app was already presenting the URL. Same seam shape as
    /// `TailscaleAuth.onOpenAuthURL` / `TailscaleIPNWatcher.onBrowseToURL`.
    nonisolated static func surfaceLoginURL(_ url: URL) {
        let line = String(repeating: "─", count: 60)
        let banner = """

            \(line)
              Tailscale login required — open this URL in a browser:

                \(url.absoluteString)
            \(line)

            """
        FileHandle.standardError.write(Data(banner.utf8))
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
