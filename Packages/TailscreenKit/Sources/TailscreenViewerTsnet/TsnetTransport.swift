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
    ///
    /// `.tenBit` is deliberately absent from the default: `FFmpegKit`'s frame
    /// copy accepts only 8-bit planar 4:2:0, so the sharer must be told to
    /// encode 8-bit up front. A host with a 10-bit-capable decoder adds the bit.
    public var caps: ScreenShareCaps = [.nack, .receiverReport, .fec]

    /// What this node is *for*, deciding the hostname it registers under and
    /// so whether other peers can discover it. `isTailscreenServerHostname`
    /// admits `tailscreen-…` but excludes `tailscreen-client-…`.
    public enum NodeRole: Sendable {
        /// Ephemeral, undiscoverable — a viewer that only ever watches.
        case viewerOnly
        /// Discoverable, under `TailscreenInstance.serverHostnamePrefix +
        /// name` — appears in peers' lists even while idle; the "only screens
        /// being shared" filter distinguishes idle from sharing via the
        /// metadata probe.
        case shareCapable(name: String)
    }
    public var nodeRole: NodeRole = .viewerOnly

    /// Run the session over the **stream profile** (spec §2.2): the whole
    /// datagram plane rides the framed TCP back-channel as `.mediaDatagram`
    /// frames instead of UDP. NACK/FEC drop from advertised caps (TS-STM-005
    /// — dead weight on a lossless transport); RR stays. Against a
    /// pre-profile sharer the HELLO frames are silently skipped and the
    /// session times out like an unreachable sharer (TS-STM-007).
    ///
    /// Defaults to `TAILSCREEN_FORCE_STREAM=1` so any host picks it up free.
    public var useStreamTransport: Bool =
        ProcessInfo.processInfo.environment["TAILSCREEN_FORCE_STREAM"] == "1"

    /// A share-by-token connection token. When set, the session runs over
    /// the guest tunnel instead of the tailnet: no tsnet node, no sign-in —
    /// `hostname`/`authKey`/`controlURL`/`statePath`/`nodeRole` are ignored,
    /// and the sharer must approve this viewer (guest approval is mandatory).
    /// The TCP back-channel rides the same tunnel.
    public var guestToken: String?

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

    /// A guest (share-by-token) session: everything tailnet-related is
    /// inert, so only the token and capabilities matter.
    public init(guestToken: String, caps: ScreenShareCaps = [.nack, .receiverReport, .fec]) {
        self.hostname = ""
        self.statePath = ""
        self.caps = caps
        self.guestToken = guestToken
    }
}

/// A minimal `LogSink` that writes both the Swift wrapper's logs and the Go
/// backend's logs (`logFileHandle`) to stderr, keeping stdout clean for the
/// eventual data path.
///
/// Deliberately NOT `TailscreenTransport.PrintLogSink`: that writes to
/// stdout, and stderr here is the point — viewer executables reserve stdout
/// for data.
struct StderrLogger: LogSink {
    var logFileHandle: Int32? { STDERR_FILENO }

    /// stderr only — for a line naming the signed-in account, which
    /// redaction can't strip. Unlike `TailscaleAuth`'s whole-sink opt-out,
    /// this sink also carries node bring-up lines a bundle needs, so the
    /// exception is per-call.
    func logWithoutCapture(_ message: String) {
        writeToStderr(message)
    }

    private func writeToStderr(_ message: String) {
        FileHandle.standardError.write(Data("[tsnet] \(message)\n".utf8))
    }

    func log(_ message: String) {
        writeToStderr(message)
        // Teed into the process recorder exactly as `PrintLogSink` — without
        // this a Linux/Windows viewer bundle carried no package log lines.
        DiagnosticsCenter.shared.captureLog(source: "tsnet", message: message)
    }
}

/// A Tailscreen sharer discovered on the tailnet — the picker's row model.
/// A deliberately small value type (not `TailscreenPeer`) so the GTK app
/// depends only on `TailscreenViewerTsnet`. `tailscaleIP` is the dial target
/// (dialing by IP sidesteps the `from == dest` hostname-mismatch limitation).
public struct DiscoveredSharer: Sendable, Identifiable, Equatable {
    public let id: String
    public let hostname: String
    public let tailscaleIP: String
    public let isOnline: Bool
    /// Tailscale ACL tags ("tag:server"), off the netmap. Empty for untagged
    /// nodes, a filterable state (`includeUntagged`), not absent data.
    public let tags: [String]
    /// The path this peer's traffic is taking. Off the LocalAPI status seed,
    /// not the netmap — netmap ticks carry no path info, so
    /// `TailscalePeerDiscovery.publishMerged` preserves these fields.
    public let route: PeerRoute

    /// Row label: `hostname` minus the `tailscreen-` marker.
    public var displayName: String {
        TailscreenInstance.displayName(fromHostname: hostname)
    }

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
/// round trip took. Latency rides along because it's free — the metadata
/// fetch is already a TCP round trip, so timing it costs one clock read.
/// It's a dial+service estimate, not a wire ping, hence
/// `ConnectionQualityTier`'s generous thresholds.
///
/// Both fields independently optional: a peer can answer while timing is
/// discarded, and one that never answers has neither.
public struct PeerProbe: Sendable {
    public let metadata: TailscreenMetadata?
    public let latencyMs: Int?

    public init(metadata: TailscreenMetadata?, latencyMs: Int?) {
        self.metadata = metadata
        self.latencyMs = latencyMs
    }
}

/// tsnet-backed transport for the portable viewer: brings up an ephemeral
/// `TailscaleNode`, binds a `PacketListener`, ships outbound control bytes
/// over UDP, and pumps inbound datagrams into `ViewerSession.receiveRTP`
/// while ticking its clock. Mirrors the macOS client's connect path.
///
/// **This is the one piece that can't run in CI** — needs a real
/// tailnet/DERP path. Compile-gated by `linux-viewer`; a live run is
/// manual/local. All the logic it drives lives in the CI-tested
/// `ViewerSession` core.
///
/// MainActor-isolated: GTK/WinUI service this loop on their main thread, so
/// `recv`/`send`/`tick` and every sink call run on one executor, matching
/// `ViewerSession`'s non-`Sendable` contract. The socket read is deliberately
/// NOT on that actor — see `DatagramInbox` and `Task.detached` below, which
/// is load-bearing and easy to undo by accident.
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
    /// The loop used to take exactly ONE per pass, tying inbound rate to loop
    /// iteration rate — measured 15.6 datagrams/s against a stream sending
    /// hundreds, ~96% loss, torn access units, blank viewer on a
    /// healthy-looking wire.
    ///
    /// 256 clears a keyframe in a couple passes while keeping tick cadence
    /// inside the reorder buffer's gap hold — the cap exists so a flood can't
    /// starve `tick` (NACK/PLI/RR), not to limit throughput.
    private static let maxDatagramsPerReceivePass = 256

    /// `PeerRoute` for a log line, spelling out the relay region since
    /// "relayed via fra" vs. "lax" are different stories about the same symptom.
    private static func describe(_ route: PeerRoute) -> String {
        switch route {
        case .direct: return "direct"
        case .relay(let region): return "DERP relay (\(region))"
        case .unknown: return "unknown"
        }
    }

    /// How long the loop parks when the inbox came back empty. With the socket
    /// on its own task there's no blocking `recv` left to pace it; 5ms keeps
    /// tick cadence (NACK aging, RR, `shouldClose`) inside every deadline
    /// while costing an idle viewer almost nothing.
    private static let idlePollIntervalMs = 5

    /// The brought-up ephemeral node, retained between `prepare` and `run` so
    /// a picker flow can list sharers before choosing one to dial. `run`
    /// brings it up itself if a caller skips `prepare`.
    private var preparedNode: TailscaleNode?

    /// The live node, for a host that also SHARES.
    /// `TailscaleScreenShareServer.start(existingNode:)` takes this so the
    /// sharer runs on the same identity the user signed in with — the
    /// alternative needs a second state directory, i.e. a second machine and
    /// a second silent login. Pair with `retainsNodeAcrossSessions` and
    /// `.shareCapable`.
    public var sharedNode: TailscaleNode? { preparedNode }

    /// The Tailscale login/identity the prepared node authenticated as (e.g.
    /// "user@github"), resolved during `prepare`. nil before bring-up or after
    /// `teardown`. A GUI host uses it to label the active account.
    public private(set) var accountIdentity: String?

    /// The tailnet the prepared node joined (e.g. "example.org.github"),
    /// resolved during `prepare`. nil before bring-up, after `teardown`, or
    /// when the control plane reports none.
    ///
    /// Distinct from `accountIdentity`: the login says who you are, the
    /// tailnet says which namespace the screen list belongs to, explaining a
    /// missing expected machine. The macOS hub shows tailnet first, falling
    /// back to login when the control plane reports no name.
    public private(set) var tailnetName: String?

    public init() {}

    /// Keep the tsnet node up when a viewing session ends, instead of taking
    /// it down with the session. A viewer-only app wants the default. An app
    /// that also shares needs both halves on ONE node for a single tailnet
    /// identity. Set before `run`.
    public var retainsNodeAcrossSessions = false

    /// Which build the host is, e.g. `"a1b2c3d release"`. Logged once per
    /// session — without a build stamp, "the new counter isn't there" and
    /// "you're running last hour's exe" look identical in a bug report.
    public var buildIdentity: String?

    /// The tsnet hostname and ephemerality a role implies. Pure and
    /// `nonisolated` so the discovery-visibility contract can be tested
    /// without a tailnet: a viewer-only node MUST fail
    /// `isTailscreenServerHostname`; a share-capable one MUST pass it.
    nonisolated static func nodeIdentity(
        for role: ViewerConfig.NodeRole, uniqueSuffix: String
    ) -> (hostName: String, ephemeral: Bool) {
        switch role {
        case .viewerOnly:
            return ("\(TailscreenInstance.viewerHostnamePrefix)\(uniqueSuffix.prefix(8))", true)
        case .shareCapable(let name):
            // Non-ephemeral: it must not vanish from the tailnet the moment
            // it goes down, since a peer may come back to it.
            return ("\(TailscreenInstance.serverHostnamePrefix)\(name)", false)
        }
    }

    /// The live node, for a host that needs to lend it to something else —
    /// notably `TailscaleScreenShareServer(existingNode:)`. Non-nil only
    /// between `prepare` and `teardown`.
    public var liveNode: TailscaleNode? { preparedNode }

    /// Bring up the ephemeral tsnet node (interactive login supported) without
    /// starting a session. Idempotent. Lets a host bring the node up,
    /// discover sharers, and only then choose one to `run` against. Only the
    /// state/auth/control fields of `config` are used (not `hostname`).
    ///
    /// - Parameter onLoginURL: where an interactive-login URL is surfaced
    ///   (default: the stderr banner + best-effort `xdg-open`). A GUI host
    ///   passes its own to show the URL in-window.
    public func prepare(
        config: ViewerConfig,
        onLoginURL: (@Sendable (URL) -> Void)? = nil
    ) async throws {
        guard preparedNode == nil else { return }
        // Bring-up runs OFF this actor: `TsnetTransport` is `@MainActor`,
        // so a GUI host's `Task { try await prepare(...) }` would otherwise
        // run the whole bring-up on the UI thread — enough to hang the
        // Windows app outright, with the login URL it's waiting on never
        // shown. `nonisolated static` puts it on the global executor.
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
        // Two lines, not one, and the split is the whole point: `identity` is
        // the signed-in login name, so the line carrying it goes to stderr
        // ONLY. The half a bundle needs — which tailnet, which node, which
        // address — has no identity in it and is recorded normally. Tailnet and
        // device names are deliberately kept; a login is not one of those.
        logger.logWithoutCapture("▶ Connected as \(identity)")
        logger.log(
            "▶ Connected to \(namedTailnet ?? "an unnamed tailnet") "
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

    /// `fetchMetadata`, timed. The metadata fetch is already a TCP round
    /// trip, so latency is one clock read, not a second probe. A peer that
    /// doesn't answer reports neither status nor latency — never a latency
    /// for an incomplete round trip.
    public func probePeer(ip: String) async -> PeerProbe {
        guard let node = preparedNode else { return PeerProbe(metadata: nil, latencyMs: nil) }
        let startNs = DispatchTime.now().uptimeNanoseconds
        let metadata = await TailscreenMetadataClient.fetchMetadata(fromIP: ip, via: node)
        guard metadata != nil else { return PeerProbe(metadata: nil, latencyMs: nil) }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- startNs
        return PeerProbe(metadata: metadata, latencyMs: Int(elapsedNs / 1_000_000))
    }

    /// Ask a peer to share its screen, and park until it answers. Parks for
    /// up to `responseTimeout`, since the answer arrives on the connection
    /// the request went out on, never a dial-back — callers should hold this
    /// in a cancellable task, not await it inline.
    ///
    /// No node reads as `.noAnswer` rather than throwing, same as a peer on
    /// an older build: nothing refused, nothing going to happen.
    public func requestToShare(ip: String, from hostname: String) async -> ShareRequestOutcome {
        guard let node = preparedNode else { return .noAnswer }
        do {
            return try await TailscreenRequestToShareClient.requestToShare(
                toIP: ip, from: hostname, via: node)
        } catch {
            return .noAnswer
        }
    }

    /// Bring the current node down and clear it so a later `prepare` can bring
    /// up a fresh one (e.g. switching profiles). No-op if no node is up.
    /// The picker-idle teardown path; `run`'s own `defer` clears on session exit.
    public func teardown() async {
        if let node = preparedNode {
            try? await node.down()
        }
        preparedNode = nil
        accountIdentity = nil
        tailnetName = nil
    }

    /// Connect and run one viewing session to completion, until the sharer
    /// says goodbye or `shouldClose` fires.
    ///
    /// If `config.authKey` is nil, brings the node up via interactive browser
    /// login; otherwise the key joins headlessly.
    ///
    /// - Parameters:
    ///   - decoder: the concrete video decoder (FFmpeg on Linux).
    ///   - videoSink: where decoded frames go (the GTK GLArea).
    ///   - shouldClose: polled each loop; returning true ends the session.
    ///   - onBackChannelReady: hands the host a `ViewerBackChannel` once the
    ///     outbound TCP channel is dialing (nil ⇒ receive-only).
    ///   - onDecoderResetNeeded / onDecodeFatal: opt-in to the shared
    ///     decode-failure escalation ladder; both nil keeps the flat
    ///     decode-failure → PLI behavior.
    ///
    /// `onVoiceReady` is MainActor-isolated, unlike the other callbacks — the
    /// uplink is a session-scoped object every host holds in main-actor UI
    /// state, and this transport is already MainActor-isolated.
    ///
    /// `onEnded` fires once, before `run` returns, for every ending the USER
    /// did not ask for (sharer stop, deny/kick, idle timeout, socket death) —
    /// not when `shouldClose` ended it. `wasAdmitted` (an SSRC was assigned)
    /// distinguishes "declined" from "disconnected by sharer". `onDeclined`
    /// still fires for a deny, before `onEnded`, for existing callers.
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
        if let token = config.guestToken {
            // Guest (share-by-token) path: no tsnet node, no sign-in, no peer
            // discovery; `preparedNode` is untouched. Dial blocks for tunnel
            // bring-up: DERP connect, handshake, NAT traversal.
            logger.log("▶ Build \(buildIdentity ?? "unknown") — guest viewer session starting")
            let client = GuestClientNode(token: token, logger: logger)
            let listener = try await client.dialUDP(port: config.port)
            let dest = Self.formatAddr(host: try await client.serverAddr(), port: config.port)
            logger.log("Guest tunnel up; dialing \(dest) (share-by-token)")
            // The framed TCP back-channel through the guest tunnel —
            // best-effort with its own reconnect loop, since a sharer
            // predating this channel never accepts.
            let inbox = DatagramInbox()
            let backChannel = ViewerBackChannel(
                guest: client, port: config.port,
                handlers: Self.wiredHandlers(
                    backChannelHandlers, streamMode: config.useStreamTransport,
                    inbox: inbox, dest: dest),
                logger: logger)
            await backChannel.start()
            onBackChannelReady?(backChannel)
            return try await runSession(
                config: config,
                wiring: SessionWiring(
                    listener: listener, dest: dest, backChannel: backChannel,
                    tailnetNode: nil, guestClient: client,
                    inbox: inbox, streamMode: config.useStreamTransport),
                endpoints: SessionAV(
                    decoder: decoder, videoSink: videoSink, audioSink: audioSink,
                    microphone: microphone),
                shouldClose: shouldClose,
                callbacks: SessionCallbacks(
                    onVoiceReady: onVoiceReady, onAdmitted: onAdmitted,
                    onAwaitingApproval: onAwaitingApproval, onDeclined: onDeclined,
                    onEnded: onEnded, onDecoderResetNeeded: onDecoderResetNeeded,
                    onDecodeFatal: onDecodeFatal))
        }
        // Bring the node up if a caller skipped `prepare`; a picker host that
        // already called `prepare` + `discoverPeers` reuses the live node.
        try await prepare(config: config)
        guard let node = preparedNode else { throw TailscaleError.badInterfaceHandle }
        // Clear `preparedNode` on EVERY exit path, or a throw between here
        // and the tail would pin the node forever (its last reference never
        // drops, so `deinit`'s `tailscale_close` never runs).
        var retainedNode: TailscaleNode?
        defer { preparedNode = retainedNode }
        // Claim retention immediately, not at clean exit — a throw partway
        // through must not orphan a node a sharer on this host is still
        // serving from (else the next `prepare()` brings up a SECOND node).
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
        // Name the build and the path before anything else can go wrong —
        // a stale binary and a missing fix look identical otherwise, and a
        // DERP-relayed session has different loss/RTT characteristics.
        logger.log("▶ Build \(buildIdentity ?? "unknown") — viewer session starting")
        // Best-effort, and deliberately not fatal: one status seed, matched
        // against whatever string we dialed. `try?` because a viewer that can
        // reach the sharer must not lose the session to a failed diagnostic.
        let dialed = config.hostname
        let seededPeers = (try? await discoverPeers()) ?? []
        if let peer = seededPeers.first(where: { $0.tailscaleIP == dialed || $0.hostname == dialed }) {
            logger.log("▶ Path to \(peer.hostname): \(Self.describe(peer.route))")
        }

        // Outbound TCP back-channel (annotations/control), reusing the same
        // node handle. Dials/reconnects on its own task, so a dead
        // back-channel never blocks video.
        let inbox = DatagramInbox()
        let backChannel = ViewerBackChannel(
            tailscale: tailscale, host: config.hostname, port: config.port,
            handlers: Self.wiredHandlers(
                backChannelHandlers, streamMode: config.useStreamTransport,
                inbox: inbox, dest: dest),
            logger: logger)
        await backChannel.start()
        onBackChannelReady?(backChannel)

        return try await runSession(
            config: config,
            wiring: SessionWiring(
                listener: listener, dest: dest, backChannel: backChannel,
                tailnetNode: node, guestClient: nil,
                inbox: inbox, streamMode: config.useStreamTransport),
            endpoints: SessionAV(
                decoder: decoder, videoSink: videoSink, audioSink: audioSink,
                microphone: microphone),
            shouldClose: shouldClose,
            callbacks: SessionCallbacks(
                onVoiceReady: onVoiceReady, onAdmitted: onAdmitted,
                onAwaitingApproval: onAwaitingApproval, onDeclined: onDeclined,
                onEnded: onEnded, onDecoderResetNeeded: onDecoderResetNeeded,
                onDecodeFatal: onDecodeFatal))
    }

    /// The socket-and-node half of a session — what `run`'s two paths
    /// (tailnet, guest) differ in. Exactly one of `tailnetNode` /
    /// `guestClient` is non-nil and is torn down at exit.
    fileprivate struct SessionWiring {
        let listener: PacketListener
        let dest: String
        let backChannel: ViewerBackChannel?
        let tailnetNode: TailscaleNode?
        let guestClient: GuestClientNode?
        /// Where inbound datagrams land, whichever transport carried them.
        /// Created in `run` (rather than `runSession`) because in stream
        /// mode the back-channel's `.mediaDatagram` handler must feed it,
        /// and the handlers are fixed at the channel's construction.
        let inbox: DatagramInbox
        /// Stream (reliable-transport, spec §2.2) mode: the outbound queue
        /// goes to the back-channel as `.mediaDatagram` frames instead of
        /// the UDP socket, and the advertised caps drop NACK/FEC.
        let streamMode: Bool
    }

    /// The host's handlers, plus — in stream mode — this transport's own
    /// `.mediaDatagram` tap feeding the session inbox. Datagrams arrive
    /// tagged with `dest` so the loop's expected-sender guard passes: on
    /// the stream there is exactly one possible sender, the connection's
    /// far end.
    private nonisolated static func wiredHandlers(
        _ base: ViewerBackChannel.Handlers, streamMode: Bool, inbox: DatagramInbox, dest: String
    ) -> ViewerBackChannel.Handlers {
        guard streamMode else { return base }
        var handlers = base
        handlers.onMediaDatagram = { datagram in
            inbox.push(DatagramInbox.Datagram(payload: datagram, from: dest))
        }
        return handlers
    }

    /// The media endpoints a session decodes into and captures from.
    fileprivate struct SessionAV {
        let decoder: VideoDecoding
        let videoSink: VideoSink
        let audioSink: AudioSink?
        let microphone: MicrophoneCapturing?
    }

    /// The host-facing callbacks a session fires (the subset of `run`'s
    /// that outlives transport setup).
    fileprivate struct SessionCallbacks {
        let onVoiceReady: (@MainActor @Sendable (VoiceUplink) -> Void)?
        let onAdmitted: (@Sendable (ScreenShareCaps) -> Void)?
        let onAwaitingApproval: (@Sendable () -> Void)?
        let onDeclined: (@Sendable () -> Void)?
        let onEnded: (@Sendable (ViewerCloseReason, _ wasAdmitted: Bool) -> Void)?
        let onDecoderResetNeeded: (@MainActor () -> Void)?
        let onDecodeFatal: (@MainActor () -> Void)?
    }

    private func runSession(
        config: ViewerConfig,
        wiring: SessionWiring,
        endpoints: SessionAV,
        shouldClose: @escaping () -> Bool,
        callbacks: SessionCallbacks
    ) async throws {
        let listener = wiring.listener
        let dest = wiring.dest
        let backChannel = wiring.backChannel
        let decoder = endpoints.decoder
        let videoSink = endpoints.videoSink
        let audioSink = endpoints.audioSink
        let microphone = endpoints.microphone
        let onVoiceReady = callbacks.onVoiceReady
        let onAdmitted = callbacks.onAdmitted
        let onAwaitingApproval = callbacks.onAwaitingApproval
        let onDeclined = callbacks.onDeclined
        let onEnded = callbacks.onEnded
        let onDecoderResetNeeded = callbacks.onDecoderResetNeeded
        let onDecodeFatal = callbacks.onDecodeFatal
        // Teardown backstop for every exit path: cancel the back-channel's
        // loop + close its socket. Fire-and-forget — blocking on `stop()`'s
        // receive-poll wait would freeze the window close, and the
        // node/tunnel teardown below tears this fd down regardless.
        defer {
            if let backChannel { Task { await backChannel.stop() } }
        }

        // Ordered, non-blocking outbound queue: `onControlToSend` (a sync
        // closure the session calls on the receive thread) yields here, and a
        // single consumer task drains it through the actor's `send` in order.
        let (outbound, outboundContinuation) = AsyncStream<Data>.makeStream()
        // Wrap the caller's sink so the first decoded frame (and any later
        // resolution change) is announced — the "am I actually receiving
        // video?" signal.
        let loggingSink = StatusVideoSink(inner: videoSink, logger: logger)
        // TS-STM-005: on the stream profile the transport never loses a
        // packet, so NACK retransmission and FEC parity are dead weight —
        // a stream viewer must not advertise them. Receiver reports stay
        // (RTT, jitter, liveness), and any other bit (`.tenBit`) is about
        // the decoder, not the transport.
        let effectiveCaps =
            wiring.streamMode ? config.caps.subtracting([.nack, .fec]) : config.caps
        let pipeline = ViewerPipeline(
            caps: effectiveCaps,
            decoder: decoder,
            videoSink: loggingSink,
            audioSink: audioSink,
            onControlToSend: { data in outboundContinuation.yield(data) }
        )
        // The one recorder the host installed, if any. Unconditional, and
        // NOT nested inside the decode-recovery opt-in below — whether a
        // decoder reset is wired has nothing to do with whether the
        // handshake should be recorded.
        DiagnosticsCenter.shared.recorder?.beginSession()
        pipeline.session.recorder = DiagnosticsCenter.shared.recorder
        // Decode-recovery ladder opt-in. Fires synchronously from
        // `receiveRTP`, always on this actor — `assumeIsolated` names that
        // contract (a hop would be wrong: reset must land before the next AU).
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
        let streamMode = wiring.streamMode
        let streamChannel = backChannel
        let senderTask = Task {
            var loggedSendError = false
            for await datagram in outbound {
                // Stream mode: the whole outbound datagram plane (HELLO,
                // KEEPALIVE, PLI, RRs, voice RTP) rides the back-channel as
                // `.mediaDatagram` frames (TS-STM-002). One serial consumer,
                // so the channel's ordering contract holds.
                if streamMode, let streamChannel {
                    await streamChannel.sendMediaDatagram(datagram)
                    continue
                }
                do {
                    try await listener.send(datagram, to: dest)
                } catch {
                    // Surface the first failure rather than silently dropping
                    // every outbound packet.
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

        // Inbound, genuinely off this actor via a bounded queue the loop
        // drains synchronously, so UI responsiveness no longer decides how
        // many packets survive. See `DatagramInbox`.
        //
        // `Task.detached`, NOT `Task` — a plain `Task { }` here would inherit
        // MainActor isolation, running `recv` on the same executor as the run
        // loop and measuring 15.6 datagrams/s (5× worse than the batched
        // drain it replaced) because the two take turns with a 5ms idle sleep
        // between them.
        let inbox = wiring.inbox
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
                    // `readFailed` covers both benign poll timeout and dead
                    // socket; wall time distinguishes them (same
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
        // control bytes use. Built here (needs the outbound queue and the
        // admission SSRC) but deliberately NOT started yet — opening the mic
        // before admission would light the indicator while still at the
        // approval prompt.
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
        let transportLabel = wiring.streamMode ? "stream (framed TCP, §2.2)" : "UDP"
        logger.log(
            "HELLO queued to \(dest) via \(transportLabel) (caps=\(effectiveCaps.rawValue)) — awaiting HELLO_ACK…"
        )

        // Receive + tick loop. `recv`'s timeout gives a steady tick cadence
        // even with no inbound traffic. Session-state transitions are
        // announced once each so the user sees admission/pending-approval
        // rather than a silent window.
        var loggedPending = false
        var loggedAdmitted = false
        // Blank-viewer diagnostics: everything between admission and a first
        // frame fails silently, so report what arrived on a slow cadence
        // until a frame lands.
        var lastDiagnosticNs = DispatchTime.now().uptimeNanoseconds
        // Datagrams from something other than the dialed sharer (dropped by
        // the guard below) — "no video" and "video from a non-matching
        // address" look identical otherwise.
        var datagramsFromOthers = 0
        var lastOtherSender = ""
        // Receive passes that hit the per-pass drain cap — a non-zero value
        // names the cap as a suspect, since a drain ceiling once produced a
        // blank viewer.
        var saturatedPasses = 0
        // A transport-diagnosed ending (idle timeout/socket death). Wire-side
        // endings live in `session.closeReason`; these are ours to notice,
        // since the session owns no socket or clock.
        var transportEndReason: ViewerCloseReason?
        // Clock of the last datagram accepted from the sharer, for the idle
        // timeout. Seeded at loop entry so an unanswering sharer still times
        // out.
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
                // A failure to open the device is not fatal — the host hears
                // about it through `VoiceUplink.onStopped`.
                if let voiceUplink {
                    voiceUplink.setSSRC(ssrc)
                    do { try voiceUplink.start() } catch {
                        logger.log("⚠ Microphone did not start (\(error))")
                    }
                }
                // Surface the sharer's caps so the host can gate its chrome
                // (Request-Control on `.remoteControl`, toolbar on `.annotations`).
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
                        // Climbing while video=0 means the sharer's media is
                        // arriving from a non-matching address and being
                        // dropped here, not upstream.
                        line +=
                            " droppedFromOthers=\(datagramsFromOthers) (last: \(lastOtherSender), dialed: \(dest))"
                    }
                    if saturatedPasses > 0 {
                        line += " saturatedPasses=\(saturatedPasses)"
                    }
                    // Inbox overflow means this actor can't consume as fast as
                    // the socket delivers — a different problem from the old
                    // socket ceiling.
                    let inboxDropped = inbox.droppedCount
                    if inboxDropped > 0 {
                        line += " inboxDropped=\(inboxDropped) inboxDepth=\(inbox.depth)"
                    }
                    logger.log(line)
                }
            }
            // Take a batch from the inbox rather than reading the socket here;
            // the cap bounds how long `tick`/`shouldClose` can be starved by
            // a burst, not a throughput limit.
            let batch = inbox.drain(max: Self.maxDatagramsPerReceivePass)
            if batch.count >= Self.maxDatagramsPerReceivePass { saturatedPasses += 1 }
            for datagram in batch {
                // KNOWN LIMITATION (direct-host path only; the picker dials
                // the resolved IP, which matches): if `config.hostname` is a
                // hostname rather than a tailnet IP, `from` won't
                // string-match `dest` and video drops. Dial by IP until fixed.
                guard datagram.from == dest else {
                    datagramsFromOthers += 1
                    lastOtherSender = datagram.from
                    continue
                }
                lastDatagramNs = DispatchTime.now().uptimeNanoseconds
                pipeline.receive(datagram.payload)
            }
            // Idle timeout: a silent-too-long sharer is gone. Only datagrams
            // accepted from the sharer feed `lastDatagramNs`, and the
            // approval-prompt wait is exempt since a deliberating sharer
            // legitimately sends nothing.
            if TransportEndDecision.idleTimedOut(
                nowNs: DispatchTime.now().uptimeNanoseconds,
                lastDatagramNs: lastDatagramNs,
                isPendingApproval: session.isPendingApproval)
            {
                logger.log("▶ Nothing from the sharer for >idle timeout — assuming it is gone.")
                transportEndReason = .timedOut
                break
            }
            // Pacing: with the socket on its own task, an empty inbox is the
            // idle signal and this sleep is the tick cadence, costing a busy
            // session nothing. Still polls rather than being woken by the
            // receive task — worth replacing with a proper signal.
            if batch.isEmpty {
                try? await Task.sleep(for: .milliseconds(Self.idlePollIntervalMs))
            }
        }
        // Resolve the ending. Wire-side causes come from the session
        // (`closeReason`), transport-side from the loop above; a
        // user-initiated close has neither and fires nothing. `wasAdmitted`
        // (SSRC assigned or not) distinguishes declined-at-gate from
        // kicked-mid-watch.
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
        // down — `retainedNode` was claimed at entry.
        if let tailnetNode = wiring.tailnetNode, !retainsNodeAcrossSessions {
            try? await tailnetNode.down()
        }
        await wiring.guestClient?.close()
    }

    /// Surface an interactive-login URL: print it prominently on stderr,
    /// standing out from the `[tsnet]` stream — a headless guest typically
    /// copies it to a browser on another machine. Opening it locally is the
    /// HOST's job via `onLoginURL`.
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
