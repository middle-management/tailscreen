import Foundation
import TailscaleKit
import TailscreenProtocol
import TailscreenTransport

/// Screen-share server. Owns the UDP video path and registers handlers on
/// the long-lived `TailscreenControlListener` for the duration of a share:
///
///   - **UDP 7447**: RTP out, small control bytes (HELLO/KEEPALIVE/BYE/PLI)
///     back, one socket multiplexed by first byte (RTP V=2 → 0x80–0xBF,
///     control → 0x00–0x7F).
///   - **TCP 7447** shared with request-to-share via `TailscreenControlListener`
///     (owned by `AppState`); the server attaches annotation handlers in
///     `start()` and clears them in `stop()`, but the listener outlives cycles.
///
/// Viewers are tracked by UDP source address; a HELLO admits, and
/// `viewerIdleTimeout` seconds of silence drops silently. No accept queue,
/// no per-viewer send pipeline — a slow viewer just drops packets at the
/// network boundary instead of stalling this process.

/// Per-viewer connection health from the adaptive sweep's PLI rate and
/// throttle state.
///  - `good`: no meaningful loss.
///  - `degraded`: over the loss threshold this window (but not throttled).
///  - `throttled`: keyframe-only mode — its link is isolating the session.
public enum ViewerHealth: String, Sendable, Hashable {
    case good
    case degraded
    case throttled
}

/// Public-facing snapshot of one connected viewer, built from the server's
/// internal `Viewer` plus a netmap lookup translating the source IP into a
/// hostname. `hostname` is nil until the lookup completes (or the peer isn't
/// in the netmap); UI falls back to `tailscaleIP`.
public struct ViewerInfo: Sendable, Identifiable, Hashable {
    public let id: String  // matches the server's internal viewer key ("ip:port")
    public let tailscaleIP: String
    public var hostname: String?
    /// Connection health for the sharer's roster dot. Defaults to `good`
    /// at join; updated in place by the adaptive sweep.
    public var health: ViewerHealth = .good
    /// Tailscale StableNodeID, resolved from the same netmap lookup as
    /// `hostname`. The key the persistent allow/deny store uses — never key
    /// policy on hostname or any other wire-supplied claim.
    public var stableID: String?
    public let connectedAt: Date
    /// True when this viewer joined via the share-by-token (guest) tunnel.
    /// Guests have no StableNodeID; identity is the guest node key resolved
    /// from `GuestServerNode.peers()`.
    public let isGuest: Bool

    /// The resolved hostname minus the `tailscreen-` marker, falling back to
    /// the tailnet IP while the lookup is outstanding.
    public var displayName: String {
        hostname.map { TailscreenInstance.displayName(fromHostname: $0) } ?? tailscaleIP
    }

    /// Public so app targets' `--ui-preview` modes can seed a roster row with
    /// no server behind it (the struct's free memberwise init is `internal`).
    public init(
        id: String, tailscaleIP: String, hostname: String? = nil,
        health: ViewerHealth = .good, stableID: String? = nil, connectedAt: Date,
        isGuest: Bool = false
    ) {
        self.id = id
        self.tailscaleIP = tailscaleIP
        self.hostname = hostname
        self.health = health
        self.stableID = stableID
        self.connectedAt = connectedAt
        self.isGuest = isGuest
    }
}

/// A viewer that sent HELLO while `requireApproval` was on, waiting for
/// Accept/Deny. Distinct from `ViewerInfo` so the UI can show "wants to
/// view" prompts separately from the connected roster; `id` matches the
/// server's internal `"ip:port"` key.
public struct PendingViewerInfo: Sendable, Identifiable, Hashable {
    public let id: String  // "ip:port"
    public let tailscaleIP: String
    public var hostname: String?
    /// See `ViewerInfo.stableID` — lets "Always Allow"/"Deny & Block" persist
    /// under the spoof-resistant key.
    public var stableID: String?
    public let arrivedAt: Date
    /// See `ViewerInfo.isGuest`. Approval is mandatory for guests, so a
    /// pending guest row is the only way one ever reaches the roster.
    public var isGuest: Bool = false

    /// See `ViewerInfo.displayName`.
    public var displayName: String {
        hostname.map { TailscreenInstance.displayName(fromHostname: $0) } ?? tailscaleIP
    }
}

/// `@unchecked Sendable`: every mutable field lives behind a `Guarded` —
/// roster/policy/adaptive state each behind its own, lifecycle state (node,
/// listeners, capture backend, `isRunning`) behind one `lifecycle` lock —
/// except the public callback properties (`onViewersChanged`,
/// `onCaptureStopped`, `onAudioReceived`, …), bare stored vars whose contract
/// is **assign before `start()`, leave alone until after `stop()` returns**
/// (read from arbitrary threads with no lock).
public final class TailscaleScreenShareServer: @unchecked Sendable {
    private let port: UInt16

    // MARK: - Lifecycle state

    /// The share's lifecycle state, folded behind ONE lock: these fields
    /// change together at start/stop and capture (re)spawn, and are read
    /// from every concurrent context (UDP receive loop, capture backend's
    /// delivery/exit-callback threads, sweep tasks, restart chain, MainActor).
    ///
    /// Lock discipline: hold the lock only to read/copy/swap fields. Never
    /// invoke a callback, `await`, send, or take another lock inside
    /// `lifecycle.withLock` — copy out, then act.
    private struct Lifecycle {
        /// The tsnet node the share runs on (see `ownsNode`). nil'd by
        /// `stop()` after release/close.
        var node: TailscaleNode?
        /// True when this server created the tsnet node itself; false when
        /// borrowed from AppState. Controls whether `stop()` tears the node
        /// down or just releases the reference.
        var ownsNode: Bool = true
        /// External TCP listener (owned by AppState) for annotation
        /// handlers. nil when standalone — `start()` then falls back to its
        /// own listener.
        var controlListener: TailscreenControlListener?
        /// Backing listener when the server owns its own; mutually
        /// exclusive with `controlListener`.
        var ownedControlListener: TailscreenControlListener?
        /// The UDP media + control socket. `stop()` detaches it under this
        /// lock before closing, so fan-out/NACK/audio/denial sends observe
        /// nil and no-op rather than racing the close.
        var packetListener: PacketListener?
        /// The guest (share-by-token) UDP listener, when reachable by
        /// token. Same detach-then-close discipline; nil for tailnet-only.
        var guestPacketListener: PacketListener?
        /// The guest tunnel's framed TCP control channel, when wired. A
        /// SECOND `TailscreenControlListener` (different tunnel, connection
        /// UUIDs process-unique) — torn down with the guest packet
        /// listener.
        var guestControlListener: TailscreenControlListener?
        /// The share's master latch: true at the end of `start()`'s
        /// bring-up, false first thing in `stop()`/deinit. Every loop,
        /// guard, and (re)spawn path gates on a locked read.
        var isRunning = false
        /// The live capture+encode backend, built by `captureFactory` at
        /// start and rebuilt on every restart. Still named `helperCapture`
        /// since it wraps the macOS `--capture-helper` child process.
        /// Teardown paths detach it via `takeHelperCapture()` so two racing
        /// legs can't both stop, or both miss, the same instance.
        var helperCapture: (any CaptureEncoding)?
        /// Codec the helper's encoder produces, set on its first
        /// parameter-sets blob and read by `broadcast()` to pick the RTP
        /// payload type. Cleared by `stop()`, NOT by restarts — the fresh
        /// helper overwrites it before its first broadcast.
        var helperCodec: VideoCodec?
    }
    private let lifecycle = Guarded<Lifecycle>(Lifecycle())

    /// The tsnet node the share is running on (nil when stopped). Production
    /// callers only read (`server?.node`); the server installs/releases it
    /// in `start()`/`stop()`.
    public var node: TailscaleNode? {
        get { lifecycle.withLock { $0.node } }
        set { lifecycle.withLock { $0.node = newValue } }
    }

    // Locked snapshots of the hot lifecycle fields — a getter copies out
    // under the lock, and whatever runs on the result runs OUTSIDE it. A
    // check-then-act here is a snapshot race by construction: benign for
    // keyframe/ping/sweep paths (tolerate acting on a just-stopped share);
    // paths that must not lose the race (restart chain, `stop()`'s teardown)
    // do their read-and-clear inside a single `lifecycle.withLock` instead.
    private var isRunning: Bool { lifecycle.withLock { $0.isRunning } }
    private var controlListener: TailscreenControlListener? {
        lifecycle.withLock { $0.controlListener }
    }
    /// Every live framed-TCP channel — tailnet, guest, or both. Outbound
    /// control traffic loops over this so a message reaches its connection
    /// whichever tunnel carried it; a by-ID send on the wrong listener is a
    /// no-op.
    private var controlChannels: [TailscreenControlListener] {
        lifecycle.withLock { [$0.controlListener, $0.guestControlListener].compactMap { $0 } }
    }
    /// Routed send facade over the tailnet + guest listeners (nil when
    /// stopped); `MediaSockets.send` picks the socket by addr.
    private var media: MediaSockets? {
        lifecycle.withLock { lc in
            // At least one socket, or nil, so every send site no-ops instead
            // of holding an empty pair.
            guard lc.packetListener != nil || lc.guestPacketListener != nil else { return nil }
            // Captures self weakly: a snapshot outliving the server then
            // routes to primary, failing the same way it always has.
            return MediaSockets(
                primary: lc.packetListener,
                guest: lc.guestPacketListener,
                isGuestAddr: { [weak self] addr in self?.isGuestAddr(addr) ?? false },
                sendViaStream: { [weak self] data, addr in
                    await self?.sendStreamDatagram(data, to: addr) ?? false
                })
        }
    }
    private var helperCapture: (any CaptureEncoding)? { lifecycle.withLock { $0.helperCapture } }
    private var helperCodec: VideoCodec? { lifecycle.withLock { $0.helperCodec } }

    /// Atomically detach and return the current capture backend (nil when
    /// none) — the single point every teardown leg claims it through, so two
    /// racing legs can never both stop, or both miss, the same instance.
    private func takeHelperCapture() -> (any CaptureEncoding)? {
        lifecycle.withLock { lc -> (any CaptureEncoding)? in
            let capture = lc.helperCapture
            lc.helperCapture = nil
            return capture
        }
    }

    private let logger: PrintLogSink

    /// Wall-clock anchor used to derive the 90 kHz RTP timestamp. Stays
    /// fixed for the lifetime of the server so the timestamp space is
    /// monotonic across encoder restarts.
    private let rtpTimestampOriginNs: UInt64

    // MARK: - Viewer roster & transport state

    /// Per-viewer state, keyed by the UDP source address ("ip:port") the
    /// HELLO arrived from (also the echo destination). `pliTimestampsNs` is a
    /// ring the adaptive-bitrate sweep reads — losing more than a couple of
    /// frames in 5s is the signal to step bitrate down.
    private struct Viewer {
        let addr: String
        let ssrc: UInt32
        /// SSRC assigned to this viewer for audio (sent in HELLO_ACK),
        /// distinct from video's `ssrc` above.
        let audioSSRC: UInt32
        var nextSequence: UInt16
        var lastSeenNs: UInt64
        var pliTimestampsNs: [UInt64] = []
        /// Latest RR "fraction lost" (Q8) and RTT, fed to
        /// `nextCongestionDecision`. Legacy (non-RR) viewers leave these at 0.
        var lossFractionQ8: Int = 0
        var rttNs: UInt64 = 0
        /// Uptime-ns of the most recent receiver report. The sweep decays a
        /// stale `lossFractionQ8` to 0 past one window, so a viewer that
        /// reports high loss then goes silent doesn't pin the global input.
        var lastRRAtNs: UInt64 = 0
        /// Uptime-ns this viewer was admitted — the clock the *absence* of a
        /// receiver report is measured against (a viewer with no report yet
        /// has no `lastRRAtNs` to age). Grace period only; see
        /// `CongestionControl.feedbackIsStale`.
        let admittedAtNs: UInt64
        /// Retransmits served this sweep window, reset each window.
        /// NACK-recovered loss softens the congestion cut.
        var nackServedThisWindow: Int = 0
        /// Packets recovered via FEC this window (extended RR's
        /// `fecRecovered`, reset each window). Recovered + residual
        /// reconstructs raw link loss for the FEC arm — residual alone would
        /// oscillate.
        var fecRecoveredThisWindow: Int = 0
        /// Packets recovered via NACK this window (extended RR's
        /// `nackRecovered`). Folded into raw loss like
        /// `fecRecoveredThisWindow` — a served retransmit masks loss too.
        var nackRecoveredThisWindow: Int = 0
        /// Video packets planned for THIS viewer this window — its own
        /// expected count, so the FEC arm's loss fraction uses the right
        /// denominator (a shared one would inflate multi-viewer sums and
        /// deflate throttled viewers').
        var packetsSentThisWindow: Int = 0
        /// Audio RTP packets accepted from this viewer this window. Without
        /// this, "the sharer cannot hear me" had nothing in a bundle —
        /// a muted mic, dead audio, and rejected audio all looked identical.
        var audioPacketsThisWindow: Int = 0
        /// Audio RTP packets REJECTED this window by the source-SSRC gate
        /// (`audioRelayDecision`) — counted apart because it's the one case
        /// that looks like silence here while the viewer's bundle shows it
        /// sending.
        var audioRejectedThisWindow: Int = 0
        /// Per-viewer token bucket for the retransmit rate limit.
        var retransmitBudget = RetransmitBuffer.BudgetState(tokens: 0, lastRefillNs: 0)
        /// While `DispatchTime.now() < throttledUntilNs`, keyframe-only mode:
        /// `broadcast` sends only IDR frames, skipping inter frames without
        /// reserving their sequence numbers. Set/renewed by
        /// `fairnessDecision`; expires by not being renewed (asymmetric
        /// hysteresis for free).
        var throttledUntilNs: UInt64 = 0
        /// The Sendable, UI-facing projection of this same admitted viewer,
        /// kept on the entry (not a second mutex) so there's no admitted
        /// viewer without its projection, and removal is atomic.
        var info: ViewerInfo
    }

    private let viewers = Guarded<[String: Viewer]>([:])
    private let parameterSets = Guarded<CodecParameterSets?>(nil)
    /// Per-connection set of annotation UUIDs the viewer has produced.
    /// Keyed by the control-listener's connection UUID; the value is every
    /// annotation `.id` that's still considered live on this viewer's
    /// behalf (mid-drag entries the viewer never finished count too —
    /// they've already been added to the sharer's overlay via in-progress
    /// `.add` ops). Cleared incrementally as the viewer's own `.undo` /
    /// `.clearAll` ops arrive, wholesale (every connection's set) whenever
    /// any `.clearAll` is broadcast — see `broadcastAnnotation` — and en
    /// masse when the control listener reports the connection closed — we
    /// fire `.undo` for each remaining
    /// UUID so the sharer's overlay (and every other viewer, via
    /// `broadcastAnnotation`) stops showing strokes nobody is around to
    /// clean up.
    private let annotationsByConnection = Guarded<[UUID: Set<UUID>]>([:])

    /// Maps a TCP annotation connection's `UUID` to the peer IP it dialed
    /// from (stripped of the ephemeral port). Populated on the first
    /// annotation seen on a connection and cleared when it closes. Lets the
    /// inbound-annotation gate check the connection's peer against the
    /// admitted-viewer set (the video path's admission gate covers only
    /// UDP, so without this a pending/denied/blocked peer could still inject
    /// annotations over TCP), and lets `expelViewer` sever a blocked peer's
    /// back-channel by IP.
    private let annotationConnectionIP = Guarded<[UUID: String]>([:])

    /// One annotation fan-out, and the ordered outbox in front of it.
    ///
    /// Annotation ops are a SEQUENCE about one stroke, not independent
    /// events: `.undo(X)` only means anything to a peer that already has
    /// `.add(X)`, and `.clearAll` only clears what arrived before it. Every
    /// fan-out site used to be its own `Task { await broadcastAnnotation(…) }`
    /// — one per relayed viewer op, one per disconnect-cleanup undo, one per
    /// sharer stroke on each of the three hosts — and separately-created
    /// tasks reach a shared await point in whatever order the runtime picks.
    /// Invert one `add`/`undo` pair and the undo lands on an id the peer has
    /// never seen, is dropped as unknown, and the stroke stays on every other
    /// viewer's screen for the rest of the share with nothing left to remove
    /// it.
    ///
    /// So ordering is established where it can be: `enqueueAnnotationBroadcast`
    /// is **synchronous**, so the order calls reach it in IS the order, and
    /// one consumer drains the outbox awaiting each fan-out in turn. Hosts
    /// call that instead of spawning a task per op.
    private struct AnnotationBroadcast: Sendable {
        let op: AnnotationOp
        let excludingConnection: UUID?
    }
    private let annotationOutbox: AsyncStream<AnnotationBroadcast>
    private let annotationOutboxContinuation: AsyncStream<AnnotationBroadcast>.Continuation
    private let annotationDrain = Guarded<Task<Void, Never>?>(nil)

    /// Test-only: fires for each op as the drain takes it, in fan-out order,
    /// before the (listener-less, and so no-op) broadcast. Lets a test assert
    /// the outbox's ordering guarantee with no tsnet node — which is the only
    /// way to catch a reintroduced `Task { await broadcastAnnotation(…) }`,
    /// since that bug is a race that passes most runs.
    var onAnnotationBroadcastForTesting: ((AnnotationOp) -> Void)?

    // MARK: - Remote control

    /// The single live remote-control grant, or nil when nobody holds control.
    /// The input-event gate matches purely on `connectionID` (see
    /// `RemoteControlPolicy.shouldInject`), so a NAT rebind can't inherit it
    /// and a non-grantee can't inject. At most one grant exists — granting a
    /// new viewer implicitly revokes the old.
    private let controlGrant = Guarded<GrantState>(GrantState())

    /// `TAILSCREEN_DEBUG_INPUT=1` arrival statistics: the gap since the
    /// previous input event, and a 1 Hz summary. The far end of the viewer's
    /// send-duration readout — steady small gaps are a healthy path, while one
    /// long gap followed by a burst of near-zero ones is a stalled sender seen
    /// from here. Behind the same lock discipline as the rest of this file
    /// because the gate fires on each connection's receive task.
    private struct InputArrivalState {
        var lastNs: UInt64?
        var sampler = InputDebugLog.Sampler()
    }
    private let inputArrival = Guarded<InputArrivalState>(InputArrivalState())

    /// Grant + a monotonic mutation counter, mutated under one lock so
    /// `notifyControlGrantChanged` hands callbacks a consistent
    /// `(generation, snapshot)` pair. Lets `AppState` discard stale
    /// notifications when two race (e.g. a disconnect-revoke vs. a fresh
    /// grant landing out of order via its MainActor hop).
    private struct GrantState {
        var grant: ControlGrant?
        var generation: UInt64 = 0
    }
    /// Viewers that asked for control and are awaiting the sharer's Grant /
    /// Deny, keyed by their TCP control connection's `UUID`.
    private let controlRequests = Guarded<[UUID: ControlRequestInfo]>([:])
    /// Per-share event-rate ceiling on injected input (defense against a
    /// malicious grantee flooding the injector). Reset in `stop()`.
    private let inputRateLimiter = Guarded<EventRateLimiter>(EventRateLimiter())
    /// Injects the grantee's events on this host, if this host can inject at
    /// all. Supplied by the embedder (macOS passes its `CGEvent` injector);
    /// `nil` means no remote control — the `.remoteControl` capability is then
    /// withheld from HELLO_ACK, so viewers hide Request Control rather than
    /// sending requests nothing can serve.
    private let remoteControlInjector: (any InputInjecting)?
    /// Log a dropped (non-grantee) input event at most once per share.
    private let droppedInputLogged = Guarded<Bool>(false)
    /// Sharer preference gate on `.controlRequest` (see
    /// `setAllowControlRequests`). Defaults on; when off, requests are
    /// declined immediately with `.controlRevoked` so the viewer's UI clears.
    private let controlRequestsAllowed = Guarded<Bool>(true)

    /// Links viewers sent with `.openLink`, awaiting the sharer's Open /
    /// Dismiss. Bounded by `LinkOfferQueue`.
    private let linkOffers = Guarded(LinkOfferQueue())
    /// Fires whenever the pending link offers change. Snapshot, oldest
    /// first; runs on any thread — bounce to MainActor.
    public var onLinkOffersChanged: (@Sendable ([LinkOfferInfo]) -> Void)?

    /// Fires whenever the set of pending control requests changes. Snapshot;
    /// replace the UI list wholesale. Runs on any thread — bounce to MainActor.
    public var onControlRequestsChanged: (@Sendable ([ControlRequestInfo]) -> Void)?
    /// Fires whenever the live grant changes (granted, revoked, auto-revoked);
    /// `nil` means nobody holds control. The `UInt64` generation is captured
    /// atomically with the snapshot — consumers that hop actors MUST drop
    /// notifications below the last generation they applied (see `GrantState`).
    public var onControlGrantChanged: (@Sendable (UInt64, ControlGrantInfo?) -> Void)?
    /// Fires when a grant is refused because the process lacks the
    /// Accessibility TCC grant `CGEvent` injection needs. AppState surfaces
    /// the prompt + deep-link to Privacy → Accessibility.
    public var onControlAccessibilityRequired: (@Sendable () -> Void)?
    /// Test-only: fires with every input event that passes the grant gate,
    /// before injection. Lets an E2E test assert the gate admits the grantee's
    /// events and drops non-grantee ones without a real `CGEventPost`.
    var onInputEventForTesting: ((InputEvent) -> Void)?
    /// Test-only: skip the Accessibility-TCC precondition in `grantControl`.
    /// xctest can't hold the Accessibility grant, and with `filterData: nil`
    /// the injector has no selection so it no-ops anyway — this lets an E2E
    /// test exercise the grant gate without real `CGEvent` posting. Never set
    /// in production. Internal (not private) so `@testable import` reaches it.
    var grantBypassesAccessibilityForTesting = false

    /// Per-pending-viewer state for the approval gate. Kept separate from
    /// `viewers` so a pending viewer can't accidentally join fan-out.
    private struct PendingViewer {
        let addr: String
        let audioSSRC: UInt32
        var lastSeenNs: UInt64
        /// Sendable, UI-facing projection — kept here, not a parallel map,
        /// for the same atomicity reason as `Viewer.info`.
        var info: PendingViewerInfo
    }
    private let pendingViewers = Guarded<[String: PendingViewer]>([:])
    /// Hard cap on the pending-approval set. A peer that HELLOs while the
    /// gate is on pins server state (and a LocalAPI resolver) until the
    /// sharer answers or the 60 s sweep collects it; without a cap a flood
    /// of spoofed HELLO source addresses could exhaust memory and amplify
    /// LocalAPI traffic. New HELLOs past the cap are dropped (logged once).
    public static let maxPendingViewers = 32
    /// One-shot latch so the "pending set full" line logs at most once per
    /// saturation episode instead of on every dropped HELLO.
    private let pendingCapLogged = Guarded<Bool>(false)

    /// When true, a HELLO from a previously-unseen viewer parks them in
    /// `pendingViewers` and fires `onPendingViewersChanged` instead of
    /// joining them immediately. The sharer must call `approveViewer` /
    /// `denyViewer` to resolve the request. Set via `setRequireApproval`
    /// while a share is live; defaults off so test fixtures and existing
    /// callers see unchanged behavior.
    private let requireApproval = Guarded<Bool>(false)
    /// Pending viewers go stale eventually too — pruned by the same idle
    /// sweep as connected viewers, using a longer timeout so the sharer
    /// has plausibly enough time to react. Matches the typical macOS
    /// notification banner dwell + a few seconds of user attention.
    private let pendingApprovalTimeoutNs = TransportTuning.pendingApprovalTimeoutNs

    /// IP → hostname cache. Filled lazily by the resolve tasks from the
    /// LocalAPI backend status. Avoids re-querying tsnet on every
    /// reconnect / KEEPALIVE storm. Cleared in `stop()`.
    private let peerNameCache = Guarded<[String: String]>([:])
    /// IP → StableNodeID cache, filled alongside `peerNameCache`. Lets
    /// `registerOrRefresh` apply remembered allow/deny synchronously on a
    /// re-HELLO instead of the async LocalAPI lookup. Cleared in `stop()`.
    ///
    /// KNOWN LIMITATION: freezes the IP→StableNodeID binding for the share's
    /// lifetime — if an IP is reassigned to a different node mid-share, that
    /// node inherits the previous occupant's decision (rare consent-bypass,
    /// accepted for now).
    private let peerStableIDCache = Guarded<[String: String]>([:])

    /// Remembered per-peer policies, keyed by StableNodeID. The server is
    /// `@unchecked Sendable` and must never reach `UserDefaults`/`@MainActor`
    /// state, so AppState pushes snapshots via `setAccessPolicies`. Empty
    /// degrades every path to pre-policy behavior.
    private let accessPolicies = Guarded<[String: PeerPolicy]>([:])

    /// One-time admit list keyed by peer IP: after the sharer accepts a
    /// named request-to-share, AppState pre-approves the requester's IP so
    /// their HELLO joins without a second prompt. Consumed on first match.
    /// A remembered `deny` still outranks it.
    private let preApprovedIPs = Guarded<Set<String>>([])

    /// Addrs whose datagrams arrive on the guest (share-by-token) listener.
    /// Consulted by send routing, admission (guests always require
    /// approval), and eviction. Cleared by `stop()`.
    private let guestAddrs = Guarded<Set<String>>([])

    private func isGuestAddr(_ addr: String) -> Bool {
        guestAddrs.withLock { $0.contains(addr) }
    }

    /// One stream (reliable-transport, spec §2.2) viewer's send route: the
    /// framed TCP connection its HELLO arrived on IS its media transport
    /// (TS-STM-002), so every datagram the send sites address to its
    /// synthetic addr is wrapped in a `.mediaDatagram` frame on this
    /// connection instead of hitting a UDP socket.
    private struct StreamRoute {
        let listener: TailscreenControlListener
        let connectionID: UUID
    }

    /// Synthetic viewer addr (`Self.streamViewerAddr`) → its framed route.
    /// Populated on the first `.mediaDatagram` frame of a connection,
    /// cleared when that connection closes (TS-STM-004: close is BYE) and
    /// by `stop()`.
    private let streamRoutes = Guarded<[String: StreamRoute]>([:])
    /// Reverse index for the close path: connection UUID → synthetic addr.
    private let streamAddrByConnection = Guarded<[UUID: String]>([:])

    /// Fired (with the guest's tunnel IP, no port) when a guest viewer is
    /// denied or expelled by remembered-deny, so the host can map the IP to
    /// the guest's node key and evict it at the tunnel. A plain disconnect
    /// ("✕", idle sweep, voluntary BYE) does NOT fire this — the guest may
    /// reconnect through the approval gate again.
    public var onGuestViewerDenied: (@Sendable (String) -> Void)?

    /// Addrs kicked by `expelViewer`, with expel time. A straggler
    /// KEEPALIVE/PLI from a kicked client must not re-register through
    /// `registerOrRefresh` — only a fresh HELLO clears the entry and reruns
    /// the gate. Entries age out after `expelledQuietNs`.
    private let expelledAddrs = Guarded<[String: UInt64]>([:])

    /// How long a kicked addr's KEEPALIVEs are ignored before the entry ages
    /// out. Generous vs. viewer teardown-on-HELLO_DENY latency, tiny vs.
    /// share lifetime.
    private let expelledQuietNs: UInt64 = 30_000_000_000

    /// Quality knobs snapshotted at `start()` and reused for **every** helper
    /// respawn, so a crash-restart can't silently pick up different settings.
    /// Exception: bandwidth ceiling live-applies via `updateQualityCeiling`,
    /// which also folds into this snapshot.
    private let sessionQuality = Guarded<QualitySettings>(.default)

    /// Raw encoder-formula baseline (`w × h × bpp × fpsCap`), anchored per
    /// parameter-sets emit, before the user ceiling. Separate from
    /// `baselineBitrate` so a ceiling change mid-share recomputes without
    /// waiting for the next encoder reinit.
    private let anchoredBaselineBitrate = Guarded<Int>(0)

    /// Inputs that produced the current adaptive-bitrate anchor. Parameter
    /// sets re-emit on every IDR (~2s under PLI-driven keyframes), so the
    /// anchor handler compares against this and resets sweep state only when
    /// the encoder config genuinely changed — else every cut/recovery step
    /// within one hysteresis window would be wiped. Cleared per helper
    /// spawn; updated by `updateQualityCeiling`.
    private struct AnchorInputs: Equatable {
        let width: Int
        let height: Int
        let codec: VideoCodec
        let fpsCap: Int
        var ceilingBps: Int?
    }
    private let lastAnchorInputs = Guarded<AnchorInputs?>(nil)

    /// Effective adaptive-sweep ceiling: the anchored formula baseline
    /// clamped by the user's bandwidth ceiling. The sweep never raises
    /// above it. Recomputed on every encoder reinit (resolution change)
    /// and on `updateQualityCeiling`.
    private let baselineBitrate = Guarded<Int>(0)
    /// Current applied bitrate. Set equal to baseline at encoder setup,
    /// then cut/raised by the adaptive sweep.
    private let currentBitrate = Guarded<Int>(0)
    /// Last time the sweep changed the bitrate. Used for hysteresis so we
    /// don't oscillate.
    private let lastBitrateChangeNs = Guarded<UInt64>(0)

    /// Per-viewer video send chain: the tail send `Task` plus queued-frame
    /// count. Frame N+1 awaits only its own frame N, so a slow viewer's
    /// blocked socketpair write throttles only its own stream, not the
    /// global frame rate (the head-of-line blocking a shared chain caused).
    /// See `broadcast`.
    private struct ViewerSendChain {
        var task: Task<Void, Never>?
        var queuedFrames: Int = 0
        /// Cumulative frames/packets dropped when the queue was full behind
        /// a stalled send. Video and audio each keep their own chain/count.
        var droppedFrames: Int = 0
    }
    /// Keyed by viewer addr; pruned to the live viewer set on each broadcast.
    private let videoSendTails = Guarded<[String: ViewerSendChain]>([:])
    /// Drop a viewer's frame once this many are queued behind a stalled send
    /// — UDP video tolerates loss (a PLI recovers) better than unbounded
    /// latency/memory.
    private static let maxQueuedVideoFramesPerViewer = TransportTuning.maxQueuedVideoFramesPerViewer

    /// Per-viewer audio send chains, mirroring `videoSendTails`. Unlike
    /// video, audio has multiple producers (sharer-mic fan-out, viewer relay)
    /// addressing different recipient subsets, so chains are NOT rebuilt to
    /// prune (that would break a live non-recipient's order) — pruned only at
    /// viewer-removal points instead.
    private let audioSendTails = Guarded<[String: ViewerSendChain]>([:])
    /// Drop a viewer's audio packet once this many are queued behind a
    /// stalled send (drop-newest, matching video). ~0.5s at one AU/21.3ms.
    private static let maxQueuedAudioPacketsPerViewer = TransportTuning.maxQueuedAudioPacketsPerViewer

    /// Drop viewers silent this long. Must absorb a run of consecutive
    /// KEEPALIVE losses plus scheduler jitter — too tight and a brief stall
    /// drops a healthy viewer, which then trips its own "no video" disconnect.
    /// KEEPALIVE is every 500ms, so 15s tolerates ~30 misses. Must equal the
    /// client's idle disconnect (both live in `TransportTuning`).
    private let viewerIdleTimeoutNs = TransportTuning.viewerIdleTimeoutNs

    public var onCaptureStopped: ((Error?) -> Void)?
    /// A preview thumbnail for the sharer's own UI, as the capture backend's
    /// **encoded bytes** (JPEG from the macOS helper). Kept opaque so this
    /// tier needs no image type; the host decodes at the point of display.
    public var onPreviewImage: ((Data) -> Void)?

    /// JSON-encoded `PickerSelection` — set by `start()`, replaced by the
    /// most recent `changeSource`. Cached so `restartCapture()` can rebuild
    /// against the same content without the caller tracking that state.
    /// Kept as raw `Data` so this process never needs the schema.
    private let lastFilterData = Guarded<Data?>(nil)

    // (`helperCapture` lives in `Lifecycle` above — detached via
    // `takeHelperCapture()` by every teardown leg.)

    /// Builds a fresh capture backend per share and per restart. `nil` means
    /// this host has no backend wired (headless tests, viewer-only builds).
    ///
    /// A *factory*, not an instance: on macOS, process death is the only
    /// reliable way to clear `replayd`'s per-bundle slot, so reusing one
    /// object across restarts would defeat the helper architecture.
    ///
    /// Locked and mutable because not every backend can be retargeted by
    /// `filterData` alone — Windows/portal backends are constructed against
    /// an already-picked target (a `WGC.CaptureItem`, a PipeWire node), so
    /// `changeSource` hands over a new factory along with new data.
    private let captureFactory = Guarded<(@Sendable () -> any CaptureEncoding)?>(nil)

    // (`helperCodec` lives in `Lifecycle` above.)

    /// Latched on when a viewer reports (via CODEC_NO) that it can't decode
    /// the current stream. Forces the helper's encoder to H.264 — the
    /// lowest-common-denominator codec every Mac can decode — on the next
    /// (re)spawn. We default to HEVC for its efficiency, but a single viewer
    /// that can't decode HEVC (e.g. an older Intel Mac) would otherwise sit
    /// on a black screen forever; falling the *whole* share back to H.264 is
    /// the safe recovery. Locked: read in `startHelperCapture` on the
    /// cooperative pool, written from the control-receive loop.
    private let forceH264 = Guarded<Bool>(false)

    /// Latched on when a viewer reports (via PROFILE_NO) that it can decode
    /// the codec but not its bit depth — a 10-bit HEVC Main 10 stream reaching
    /// a viewer whose hardware only decodes 8-bit HEVC. Passes
    /// `TAILSCREEN_FORCE_8BIT=1` to the helper on the next (re)spawn so the
    /// capture-helper pins its `ColorInfo` to 8-bit (staying on HEVC). A
    /// lighter fallback than `forceH264`: we keep HEVC's efficiency, just drop
    /// the extra two bits. Locked for the same reason as `forceH264`.
    private let force8bit = Guarded<Bool>(false)

    /// Whether the host asked for the 10-bit capture path at all (macOS
    /// Settings → Color; every other sharer leaves it false). Set through
    /// `setTenBitCaptureRequested`, the same latch-and-re-push discipline as
    /// `shareSystemAudio`.
    ///
    /// Load-bearing for the capability gate below, not just bookkeeping: the
    /// gate must not respawn the helper for a viewer that can't decode 10-bit
    /// when the share was never going to send 10-bit in the first place. An
    /// 8-bit share is the overwhelmingly common case and every libavcodec
    /// viewer joining one would otherwise cost everybody a capture restart.
    private let tenBitRequested = Guarded<Bool>(false)

    /// Whether the sharer is sharing system/computer audio to viewers. Gates
    /// *emission* in the helper (the audio SCStream output is always configured
    /// when the share starts with audio available). Locked: written from the
    /// MainActor via `setShareSystemAudio`, read in `startHelperCapture` to
    /// re-send the latch after each (re)spawn — mirrors the `forceH264` pattern
    /// so helper restarts preserve the toggle.
    private let shareSystemAudio = Guarded<Bool>(false)

    /// Packetizes helper-produced system-audio AUs into RTP with the reserved
    /// system SSRC + PT 99. Not thread-safe; the helper's reader thread is the
    /// only caller (via `broadcastSystemAudio`), satisfying the serialization
    /// contract the same way `VoiceChannel` confines its own packetizer.
    private let systemAudioPacketizer = AudioRTPPacketizer(
        ssrc: RTPHeader.systemAudioSSRC, payloadType: RTPHeader.systemAudioPayloadType)

    /// Stateful per-codec packetizers. Held across `broadcast()` calls so
    /// each call can recycle the previous batch's buffer storage instead
    /// of allocating a fresh `Data` per packet. See `RTPPacketBufferPool`
    /// for the COW-based safety argument. Cheap when unused (no codec yet
    /// settled): each holds an empty pool array.
    private let h264Packetizer = H264Packetizer()
    private let h265Packetizer = H265Packetizer()

    /// Send-side ring of recently broadcast packets, for answering viewer
    /// NACKs with byte-identical retransmits. Shared across viewers (payloads
    /// are identical — only the header bytes `rewriteRTPHeader` rewrites
    /// differ); each NACK-capable viewer's reserved seq range is registered per
    /// broadcast. Reset on `stop()`.
    private let retransmitBuffer = RetransmitBuffer()

    /// Capabilities each viewer advertised in its (extended) HELLO, keyed by
    /// addr so it survives the pending→approve promotion. Governs whether the
    /// server sends an extended HELLO_ACK, records retransmit ranges for it,
    /// and pings it for RTT. Empty (legacy 1-byte HELLO) keeps the PLI path.
    private let viewerCaps = Guarded<[String: ScreenShareCaps]>([:])

    /// Transport capabilities every build advertises back to cap-aware
    /// viewers. Platform-independent: all three ride the portable
    /// loss-recovery core.
    private static let baseServerCaps: ScreenShareCaps = [.nack, .receiverReport, .fec]

    /// What *this* server advertises. `.remoteControl` is added only when the
    /// host supplied an ``InputInjecting`` backend — a static "can inject at
    /// all" signal; runtime gates still decline a live request with
    /// `.controlRevoked`.
    private var serverCaps: ScreenShareCaps {
        var caps = Self.baseServerCaps
        if remoteControlInjector != nil { caps.insert(.remoteControl) }
        if rendersAnnotations { caps.insert(.annotations) }
        if promptsForLinks { caps.insert(.openLink) }
        return caps
    }

    /// Whether this host DISPLAYS the annotations viewers draw. Conditional
    /// like `.remoteControl` — a host without an overlay must withhold the
    /// bit, or a viewer's toolbar draws confidently at nobody watching.
    public let rendersAnnotations: Bool

    /// Whether this host shows `onLinkOffersChanged` to its user with an
    /// Open action. Same fail-safe default as `rendersAnnotations`.
    public let promptsForLinks: Bool

    /// Adaptive FEC state (group size + off-gate hysteresis), stepped once
    /// per sweep window by `fecSweepDecision`. `groupSize == 0` means FEC
    /// is off (clean links pay zero overhead). Locked: written by the sweep,
    /// read by `broadcast` and `applyAdaptiveBitrate`.
    private let fecState = Guarded<FECState>(FECState())

    /// Viewers currently gated for parity delivery: `.fec`-negotiated AND
    /// their own decayed loss/RTT pass the on-gate this window. Per-viewer so
    /// a clean-link viewer pays zero overhead even mid-share with a lossy
    /// peer — the same isolate-don't-globalize stance as `congestionInputs`.
    /// Rebuilt by every sweep; read by `broadcast`.
    private let fecGatedAddrs = Guarded<Set<String>>([])

    /// Current capture frame-rate tier (60 / 30 / 15), the second congestion
    /// lever below the bitrate floor. Seeded from the session fps cap at
    /// `start()`; stepped by the adaptive sweep's `nextCongestionDecision`.
    private let currentFpsTier = Guarded<Int>(60)

    /// Total non-timeout receive-loop errors survived this session. Feeds
    /// the give-up log line and `stop()`'s summary. Locked: bumped from the
    /// receive task, read from `stop()`.
    private let receiveLoopErrorTotal = Guarded<Int>(0)

    /// Sliding-window restart counter for helper-process crashes: 3 exits
    /// within 30s and we give up, surfacing the failure as a normal capture
    /// stop. Locked — mutated from both the helper's termination queue and
    /// the restart `Task`.
    private let helperCrashTimestampsNs = Guarded<[UInt64]>([])

    /// Uptime-ns of the last message received from the capture helper (AUs,
    /// params, logs, or the ~1Hz heartbeat), for the hung-helper watchdog.
    /// Seeded to "now" on spawn so SCStream bring-up gets a grace window; 0
    /// means no helper running.
    private let lastHelperActivityNs = Guarded<UInt64>(0)
    /// If the helper emits nothing this long while live, the watchdog
    /// assumes wedged capture and restarts it — process-death detection
    /// alone can't catch a stream that stopped delivering. Generous, since
    /// even a static screen's `.idle` frames keep the ~1Hz heartbeat alive.
    private let helperLivenessTimeoutNs = TransportTuning.helperLivenessTimeoutNs
    /// `TAILSCREEN_DISABLE_HELPER_WATCHDOG=1` escape hatch for hardware that
    /// delivers idle frames too sparsely, which would otherwise false-restart.
    private let helperWatchdogEnabled =
        ProcessInfo.processInfo.environment["TAILSCREEN_DISABLE_HELPER_WATCHDOG"] != "1"

    /// `TAILSCREEN_DEBUG_FEC=1` logs per-viewer FEC sweep inputs and the
    /// resulting arm decision every 5s window — e.g. RTT staying 0 means
    /// receiver reports/ping echoes aren't landing, so the gate can never trip.
    private let debugFEC =
        ProcessInfo.processInfo.environment["TAILSCREEN_DEBUG_FEC"] == "1"

    /// In-flight `restartCapture()` work. `stop()` awaits this before tearing
    /// down `helperCapture`, else a concurrent restart can spawn a new helper
    /// after `stop()` already nulled it — an orphaned child process holding
    /// replayd's slot (the stuck screen-recording badge).
    private let restartTask = Guarded<Task<Error?, Never>?>(nil)

    /// Fires when a viewer sends an annotation op over the back-channel.
    /// AppState routes these into the sharer's overlay window; the drawings
    /// get captured into the video stream and distributed to every viewer.
    public var onAnnotationReceived: ((AnnotationOp) -> Void)?

    /// Fires whenever the connected-viewer set changes — join, BYE, idle
    /// timeout, hostname resolved, or `stop()`. The argument is a snapshot
    /// of the current roster; replace the UI's list wholesale rather than
    /// diffing. Callback may run on any thread; bounce to `@MainActor`.
    public var onViewersChanged: (@Sendable ([ViewerInfo]) -> Void)?

    /// Fires whenever the pending-approval set changes — new HELLO under
    /// `requireApproval`, `approveViewer` / `denyViewer`, idle sweep, or
    /// `stop()`. Same shape and bounce rules as `onViewersChanged`.
    public var onPendingViewersChanged: (@Sendable ([PendingViewerInfo]) -> Void)?

    /// Fires on every inbound audio RTP packet from any viewer. AppState
    /// pipes these into the local VoiceChannel so the sharer can hear
    /// viewers.
    public var onAudioReceived: ((Data) -> Void)?

    /// Where this share records its handshakes and admission decisions.
    /// Host-installed and optional: nil means no recording (stable-release
    /// default). Records only decisions — who asked, what was negotiated, who
    /// was admitted — never per-packet paths, which run hundreds of times a
    /// second and are summarized by counters instead.
    public var recorder: DiagnosticsRecorder?

    /// Test-only: fires with the viewer's address each time a PLI is recorded
    /// — lets a test confirm the viewer→server PLI path with no capture
    /// helper attached.
    var onPLIRecordedForTesting: ((String) -> Void)?

    /// Test-only: fires with viewer address + packets served on each honored
    /// NACK.
    var onNACKServedForTesting: ((String, Int) -> Void)?

    /// Test-only: fires with viewer address + parity datagrams appended on
    /// each FEC fan-out.
    var onFECParitySentForTesting: ((String, Int) -> Void)?

    /// Invoked once the `TailscaleNode` exists but **before** `node.up()` —
    /// AppState subscribes an IPN-bus watcher here to open the login URL in
    /// the browser, since `up()` otherwise blocks on a login the user can't see.
    public var nodeReadyBeforeUp: (@Sendable (TailscaleNode) async -> Void)?

    // MARK: - Init

    /// - Parameters:
    ///   - captureFactory: builds a fresh capture+encode backend for each
    ///     share/restart. `nil` runs headless (admission/audio/control work,
    ///     no video) — the mode network tests use.
    ///   - inputInjector: the host's remote-control injector, or `nil`.
    ///     Supplying one adds `.remoteControl` to the advertised caps.
    ///   - rendersAnnotations: whether this host displays viewers' strokes.
    ///     Adds `.annotations` to the advertised caps.
    ///   - promptsForLinks: whether this host offers viewers' links to its
    ///     user. Adds `.openLink` to the advertised caps.
    ///
    /// Both backends are required with no defaults, deliberately: a host must
    /// say it lacks capture/injection rather than get that by omission.
    /// `rendersAnnotations` defaults to **false** for the same reason — it
    /// used to default true, and two Linux hosts with no overlay silently
    /// advertised drawing support that went nowhere. Claiming a capability
    /// you lack breaks the peer's UI silently; omitting one you have just
    /// costs a disabled toolbar.
    public init(
        port: UInt16 = NetworkConfig.tailscreenPort,
        captureFactory: (@Sendable () -> any CaptureEncoding)?,
        inputInjector: (any InputInjecting)?,
        rendersAnnotations: Bool = false,
        promptsForLinks: Bool = false
    ) {
        self.port = port
        self.captureFactory.withLock { $0 = captureFactory }
        self.remoteControlInjector = inputInjector
        self.rendersAnnotations = rendersAnnotations
        self.promptsForLinks = promptsForLinks
        self.logger = PrintLogSink(prefix: "Tailscale", dropListeningNoise: true)
        self.rtpTimestampOriginNs = DispatchTime.now().uptimeNanoseconds
        // Unbounded: dropping the oldest could drop the `.add` a later `.undo`
        // refers to, which is the exact failure the outbox exists to prevent.
        // Annotation ops are drag-paced and tiny, so the queue stays short.
        let (outbox, outboxContinuation) = AsyncStream<AnnotationBroadcast>.makeStream(
            bufferingPolicy: .unbounded)
        self.annotationOutbox = outbox
        self.annotationOutboxContinuation = outboxContinuation
        startAnnotationDrain()
    }

    /// Start the outbox's single consumer. `[weak self]` so a dropped,
    /// never-started server isn't kept alive by its own drain; `deinit`
    /// finishes the stream to end the loop.
    private func startAnnotationDrain() {
        let outbox = annotationOutbox
        let task = Task { [weak self] in
            for await item in outbox {
                self?.onAnnotationBroadcastForTesting?(item.op)
                await self?.broadcastAnnotation(item.op, excludingConnection: item.excludingConnection)
            }
        }
        annotationDrain.withLock { $0 = task }
    }

    /// Queue an annotation op for fan-out, preserving call order on the wire.
    /// Synchronous by design (see ``annotationOutbox``) — wrapping in a
    /// `Task` would reintroduce the race it exists to close.
    ///
    /// Safe before `start()` and after `stop()`: fan-out no-ops without a
    /// control listener, and `stop()` drops whatever is still queued.
    public func enqueueAnnotationBroadcast(_ op: AnnotationOp, excludingConnection: UUID? = nil) {
        annotationOutboxContinuation.yield(
            AnnotationBroadcast(op: op, excludingConnection: excludingConnection))
    }

    // MARK: - Start

    /// Bring the server up. `filterData` is the JSON-encoded
    /// `PickerSelection` the picker subprocess produced; `nil` only from
    /// tests that don't want the capture-helper to spawn. `quality` is
    /// snapshotted for the whole share (see `sessionQuality`).
    public func start(
        hostname: String = "tailscreen-server",
        authKey: String? = nil,
        path: String? = nil,
        controlURL: String = kDefaultControlURL,
        filterData: Data?,
        quality: QualitySettings = .default,
        existingNode: TailscaleNode? = nil,
        controlListener: TailscreenControlListener? = nil,
        guestPacketListener: PacketListener? = nil
    ) async throws {
        guard !isRunning else { return }

        let normalizedQuality = quality.normalized()
        sessionQuality.withLock { $0 = normalizedQuality }
        currentFpsTier.withLock { $0 = normalizedQuality.fpsCap }

        let node: TailscaleNode
        if let existing = existingNode {
            // Reuse the AppState-owned node — avoids a second tsnet machine
            // needing its own browser login.
            node = existing
            lifecycle.withLock { lc in
                lc.node = existing
                lc.ownsNode = false
            }
            logger.log("Screen-share server reusing existing Tailscale node")
        } else {
            let statePath =
                path
                ?? {
                    // `.first`, not a force-unwrap: non-empty is only
                    // guaranteed on Apple platforms, not everywhere this
                    // portable file now runs.
                    let appSupport =
                        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
                    return appSupport.appendingPathComponent("Tailscreen/tailscale\(TailscreenInstance.stateSuffix)")
                        .path
                }()
            logger.log("Starting Tailscale server…")

            // Ephemeral: a server-owned node exists only for the share (apps
            // pass `existingNode` for durable identity). `up()` is bounded
            // only with an auth key present; otherwise unbounded so an
            // interactive browser login isn't cut off (see
            // AppState.getOrCreateNode). `nodeReadyBeforeUp` rides the
            // factory's `beforeUp` window, before `up()` can block on login.
            let newNode = try await TsnetNodeFactory.bringUp(
                spec: TsnetNodeFactory.Spec(
                    hostName: hostname,
                    ephemeral: true,
                    statePath: statePath,
                    authKey: authKey,
                    controlURL: controlURL),
                logger: logger,
                timeout: .boundedWhenAuthKeyed(seconds: 60),
                beforeUp: { newNode in
                    self.lifecycle.withLock { lc in
                        lc.node = newNode
                        lc.ownsNode = true
                    }
                    if let ready = self.nodeReadyBeforeUp {
                        await ready(newNode)
                    }
                })
            node = newNode
        }

        let ips = try await node.addrs()
        logger.log("Tailscale connected — ip4=\(ips.ip4 ?? "-") ip6=\(ips.ip6 ?? "-")")

        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        // TCP control listener. AppState owns the long-lived one (so
        // request-to-share works whether or not we're sharing); standalone
        // callers (tests) pass nil and we create one bound to the lifetime
        // of this share.
        if let provided = controlListener {
            lifecycle.withLock { $0.controlListener = provided }
            logger.log("Screen-share server attaching to shared control listener")
        } else {
            let owned = TailscreenControlListener(port: port)
            try await owned.start(node: node)
            lifecycle.withLock { lc in
                lc.ownedControlListener = owned
                lc.controlListener = owned
            }
            logger.log("Screen-share server started owned control listener on :\(port)")
        }
        installControlHandlers()

        // tsnet's ListenPacket requires an explicit tailnet IP — 0.0.0.0
        // binds, but tsnet won't actually route inbound datagrams to it.
        // Use the node's tailnet IPv4 (preferred) or IPv6 instead.
        let bindIP = ips.ip4 ?? ips.ip6 ?? "0.0.0.0"
        let bindAddr = ips.ip4 != nil ? "\(bindIP):\(port)" : "[\(bindIP)]:\(port)"
        let packetListener = try await PacketListener(
            tailscale: tailscaleHandle,
            address: bindAddr,
            logger: logger
        )
        lifecycle.withLock { $0.packetListener = packetListener }
        logger.log("UDP video stream listening on \(bindAddr)")

        // Guest (share-by-token) listener: same wire protocol, second
        // socket, viewers arriving through the token tunnel. Its datagrams
        // feed the same handleIncoming; its addrs are tagged as guests.
        if let guestPacketListener {
            lifecycle.withLock { $0.guestPacketListener = guestPacketListener }
            logger.log("Guest UDP stream attached (share-by-token)")
        }

        lifecycle.withLock { $0.isRunning = true }

        Task { [weak self] in await self?.receiveControlLoop(pl: packetListener, isGuest: false) }
        if let guestPacketListener {
            Task { [weak self] in
                await self?.receiveControlLoop(pl: guestPacketListener, isGuest: true)
            }
        }
        Task { [weak self] in await self?.sweepIdleViewers() }
        Task { [weak self] in await self?.adaptiveBitrateSweep() }

        lastFilterData.withLock { $0 = filterData }
        remoteControlInjector?.setSelection(decodedSelection())
        if let filterData {
            try startHelperCapture(filterData: filterData)
        } else {
            logger.log("Screen-share server: no filterData — skipping helper-capture spawn (test mode)")
        }
    }

    /// Bring the server up with the guest (share-by-token) listener as its
    /// ONLY socket — a link-only share, no Tailscale sign-in. No tsnet node,
    /// no TCP control listener, no LocalAPI identity resolution — every
    /// viewer arrives on the guest listener, a guest by construction, at the
    /// mandatory approval gate. Everything else (capture, fan-out, loss
    /// recovery, sweeps, voice relay) runs exactly as in a tailnet share.
    public func startGuestOnly(
        filterData: Data?,
        quality: QualitySettings = .default,
        guestPacketListener: PacketListener,
        guestControlListener: TailscreenControlListener? = nil
    ) async throws {
        guard !isRunning else { return }

        let normalizedQuality = quality.normalized()
        sessionQuality.withLock { $0 = normalizedQuality }
        currentFpsTier.withLock { $0 = normalizedQuality.fpsCap }

        lifecycle.withLock { lc in
            lc.guestPacketListener = guestPacketListener
            lc.guestControlListener = guestControlListener
            lc.isRunning = true
        }
        if let guestControlListener {
            installControlHandlers(on: guestControlListener)
            logger.log("Guest-only share: guest TCP control channel installed")
        }
        logger.log("Guest-only share: guest UDP stream is the only socket (no tsnet node)")

        Task { [weak self] in
            await self?.receiveControlLoop(pl: guestPacketListener, isGuest: true)
        }
        Task { [weak self] in await self?.sweepIdleViewers() }
        Task { [weak self] in await self?.adaptiveBitrateSweep() }

        lastFilterData.withLock { $0 = filterData }
        remoteControlInjector?.setSelection(decodedSelection())
        if let filterData {
            try startHelperCapture(filterData: filterData)
        } else {
            logger.log("Screen-share server: no filterData — skipping helper-capture spawn (test mode)")
        }
    }

    // MARK: - Capture supervision (helper spawn / restart / crash budget)

    private func startHelperCapture(filterData: Data) throws {
        guard let factory = captureFactory.withLock({ $0 }) else {
            throw ScreenShareServerError.noCaptureBackend
        }
        let helper = factory()
        // Fresh helper ⇒ fresh anchor state: its encoder restarts at the
        // formula/ceiling bitrate, so the first parameter-sets emit must
        // re-anchor even if resolution/codec are unchanged.
        lastAnchorInputs.withLock { $0 = nil }
        // Seed the liveness clock so SCStream bring-up gets a grace window
        // before the watchdog can fire, then tick it on every message.
        lastHelperActivityNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        helper.onActivity = { [weak self] in
            self?.lastHelperActivityNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        }
        helper.onAccessUnit = { [weak self] avcc, isKeyframe in
            self?.handleHelperAccessUnit(avcc, isKeyframe: isKeyframe)
        }
        helper.onAudioAccessUnit = { [weak self] au in
            self?.broadcastSystemAudio(au: au)
        }
        helper.onParameterSets = { [weak self] params in
            self?.parameterSets.withLock { $0 = params }
            switch params {
            case .h264: self?.lifecycle.withLock { $0.helperCodec = .h264 }
            case .hevc: self?.lifecycle.withLock { $0.helperCodec = .hevc }
            }
        }
        helper.onEncoderResolution = { [weak self] width, height in
            guard let self else { return }
            // Anchor the adaptive-bitrate ceiling. Re-emits on every IDR, so
            // re-anchor only when inputs actually changed — else the sweep's
            // hysteresis state resets every couple seconds, defeating cuts
            // and recovery. `helperCodec` is already set (onParameterSets
            // fires first); HEVC default is a fallback only.
            let codec: VideoCodec = self.helperCodec ?? .hevc
            let quality = self.sessionQuality.withLock { $0 }
            let inputs = AnchorInputs(
                width: width, height: height, codec: codec,
                fpsCap: quality.fpsCap, ceilingBps: quality.maxBitrateBps)
            let changed = self.lastAnchorInputs.withLock { last -> Bool in
                guard last != inputs else { return false }
                last = inputs
                return true
            }
            guard changed else { return }
            let bpp = EncoderTuning.defaultBitsPerPixel(for: codec)
            let anchor = EncoderTuning.computeBitrate(
                width: width, height: height, fps: quality.fpsCap, bitsPerPixel: bpp)
            self.anchoredBaselineBitrate.withLock { $0 = anchor }
            let baseline = quality.cappedBitrate(anchorBps: anchor)
            self.baselineBitrate.withLock { $0 = baseline }
            self.currentBitrate.withLock { $0 = baseline }
            self.lastBitrateChangeNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
            self.logger.log(
                "CaptureEncoding: anchored baseline bitrate \(baseline / 1000) kbps for "
                    + "\(width)x\(height) \(codec) @\(quality.fpsCap)fps"
            )
            // The one place codec, resolution and rate ceiling are all known
            // at once — the `changed` guard keeps this from firing every IDR.
            // This row is what every later `encode.bitrate.changed` reads
            // against.
            var selected: [String: DiagnosticValue] = [
                "codec": .string(codec.rawValue),
                "size": .string("\(width)x\(height)"),
                "fps": DiagnosticValue(quality.fpsCap),
                "anchor_kbps": DiagnosticValue(anchor / 1000),
                "baseline_kbps": DiagnosticValue(baseline / 1000)
            ]
            if let ceiling = quality.maxBitrateBps {
                selected["ceiling_kbps"] = DiagnosticValue(ceiling / 1000)
            }
            self.recorder?.record(.encodeCodecSelected, role: .sharer, fields: selected)
        }
        helper.onPreviewImage = { [weak self] image in
            self?.onPreviewImage?(image)
        }
        helper.onUserStopped = { [weak self] in
            self?.logger.log("CaptureEncoding: user stopped capture out-of-app")
            // Detach only (no stop() — the backend already ended itself).
            // Fires on the backend's callback thread; the write is guarded.
            _ = self?.takeHelperCapture()
            // Surface a userStopped error so the host's
            // `isUserInitiatedCaptureStop` branch tears the share
            // down quietly instead of trying to recover.
            let err = NSError(
                domain: Self.userStoppedErrorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "User stopped capture"]
            )
            self?.onCaptureStopped?(err)
        }
        helper.onUnexpectedExit = { [weak self] reason in
            guard let self else { return }
            self.logger.log("HelperScreenCapture: unexpected exit (\(reason))")
            // Detach only (the process is already dead). Fires on the
            // backend's callback thread; the write is guarded.
            _ = self.takeHelperCapture()
            switch Self.classifyHelperExit(reason: reason) {
            case .slotRefused:
                let err = NSError(
                    domain: Self.helperUnrecoverableErrorDomain,
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Another Tailscreen instance on this Mac is already capturing — replayd refused the slot. Stop sharing on the other instance and try again."
                    ]
                )
                self.onCaptureStopped?(err)
                return
            case .sourceGone:
                let err = NSError(
                    domain: Self.helperSourceGoneErrorDomain,
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: reason]
                )
                self.onCaptureStopped?(err)
                return
            case .permanent:
                let err = NSError(
                    domain: Self.helperUnrecoverableErrorDomain,
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: reason]
                )
                self.onCaptureStopped?(err)
                return
            case .retryable:
                break
            }
            // Sliding-window restart: tolerate ≤3 crashes in 30s. Each crash
            // invalidates replayd's slot for that PID, so respawn gets a
            // fresh process with no inherited state.
            let now = DispatchTime.now().uptimeNanoseconds
            let crashCount = self.helperCrashTimestampsNs.withLock { stamps in
                Self.slidingWindowCrashCount(&stamps, appending: now)
            }
            if crashCount > Self.maxHelperCrashesPerWindow || !self.isRunning {
                let err = NSError(
                    domain: "Tailscreen.HelperScreenCapture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: reason])
                self.onCaptureStopped?(err)
                return
            }
            self.logger.log("HelperScreenCapture: restarting (crash #\(crashCount) in window)")
            // Route through the same tracked Task `stop()` awaits, which
            // re-checks `isRunning` after the spawn — a synchronous restart
            // here could leave a freshly-spawned child orphaned if
            // Stop-Sharing raced this callback (the stuck recording-badge bug).
            let work = self.scheduleHelperRestart(resetCrashBudget: false)
            Task { [weak self] in
                guard let err = await work.value, let self, self.isRunning else { return }
                self.onCaptureStopped?(
                    NSError(
                        domain: "Tailscreen.HelperScreenCapture", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "respawn failed: \(err)"]))
            }
        }
        // Quality knobs travel as env vars (the framed contentFilter payload
        // stays schema-stable). Reading the session snapshot here means
        // crash-restart respawns reuse the same fps/codec/ceiling automatically.
        var qualityEnv = sessionQuality.withLock { $0 }.helperEnvironment()
        // A viewer's 8-bit fallback (PROFILE_NO) rides the same env-var
        // channel so a respawn inherits it.
        if force8bit.withLock({ $0 }) {
            qualityEnv["TAILSCREEN_FORCE_8BIT"] = "1"
        }
        try helper.start(
            selectionData: filterData, forceH264: forceH264.withLock { $0 }, qualityEnv: qualityEnv)
        lifecycle.withLock { $0.helperCapture = helper }
        // Re-send the system-audio latch after every (re)spawn (mirrors
        // forceH264 handling).
        helper.setAudioEnabled(shareSystemAudio.withLock { $0 })
        // Re-push the adaptive rate (with FEC compensation) after every
        // (re)spawn — else a crash-restart with FEC steady-on would run at
        // full rate PLUS parity overhead until the next sweep step.
        let adaptiveRate = currentBitrate.withLock { $0 }
        if adaptiveRate > 0 {
            helper.setBitrate(Self.fecCompensatedBitrate(adaptiveRate, groupSize: fecEncoderGroupSize()))
        }
        logger.log("HelperScreenCapture started (filter=\(filterData.count)B)")
    }

    private func handleHelperAccessUnit(_ avcc: Data, isKeyframe: Bool) {
        guard isRunning else { return }
        broadcast(avccData: avcc, isKeyframe: isKeyframe)
    }

    /// Called by the host after the helper-process capture died mid-flight.
    /// Spawns a fresh helper on the same display without disturbing
    /// listeners or the viewer roster. On failure, the caller falls back to
    /// `stop()` and surfaces the error.
    ///
    /// The helper self-restarts up to 3 times in 30s via `onUnexpectedExit`;
    /// this is the AppState-driven path after that budget is exhausted, and
    /// resets it so the user gets a fresh run of auto-restarts.
    public func restartCapture() async throws {
        guard isRunning else { return }
        if let result = await scheduleHelperRestart(resetCrashBudget: true).value {
            throw result
        }
    }

    /// Retarget capture to a new `PickerSelection` without touching
    /// listeners, roster, approval state, or annotations. Swaps the cached
    /// selection then rides `scheduleHelperRestart` (never spawns directly),
    /// inheriting its orphan safety. Crash budget resets for the new target.
    ///
    /// A crash-triggered auto-restart racing this call is benign either
    /// order: both funnel through `scheduleHelperRestart`, and
    /// `lastFilterData` already holds the new bytes.
    ///
    /// Returns `false` (no-op) when the server isn't running — lets a caller
    /// racing `stop()` distinguish that from success. Throws
    /// `CancellationError` if the share stops mid-restart.
    ///
    /// `forceH264` stays latched (decode capability didn't change);
    /// `parameterSets`/`helperCodec` stay in place — the fresh helper
    /// overwrites them before its first broadcast.
    /// - Parameter captureFactory: replacement backend builder for hosts
    ///   whose backend can't retarget via `filterData` alone. Nil keeps the
    ///   existing one (macOS: its helper reads the selection from the data).
    public func changeSource(
        filterData: Data,
        captureFactory: (@Sendable () -> any CaptureEncoding)? = nil
    ) async throws -> Bool {
        guard isRunning else { return false }
        lastFilterData.withLock { $0 = filterData }
        // Swapped BEFORE the restart is scheduled, so the respawn below builds
        // the new source rather than one more copy of the old one.
        if let captureFactory {
            self.captureFactory.withLock { $0 = captureFactory }
        }
        // Keep the injector's coordinate mapping in step with the new source
        // so a live control grant keeps landing events on the right region.
        remoteControlInjector?.setSelection(decodedSelection())
        // Schedule directly (rather than via `restartCapture()`) so a stop
        // racing this call surfaces as the restart task's CancellationError
        // instead of silently succeeding past restartCapture's own guard.
        if let result = await scheduleHelperRestart(resetCrashBudget: true).value {
            throw result
        }
        return true
    }

    /// Spawn a fresh helper against the cached filter, wrapped in a tracked
    /// `Task` stored in `restartTask` so `stop()` can await it. Shared by the
    /// AppState-driven `restartCapture()` / `changeSource(filterData:)` and
    /// the helper's own `onUnexpectedExit` auto-restart, so *every* respawn
    /// path goes through the same guard. Three properties make it orphan-safe:
    ///
    ///   1. Restarts are strictly serialized: the slot swap below is atomic
    ///      (snapshot the previous occupant and install the new task under a
    ///      single lock hold), and each new task's first act is to await its
    ///      predecessor. Two overlapping restarts could otherwise both spawn
    ///      helpers and clobber each other — orphaning a live
    ///      `--capture-helper` holding replayd's recording slot.
    ///   2. `stop()` drains `restartTask` and awaits the in-flight work before
    ///      detaching `helperCapture` — the slot always holds the newest
    ///      restart, so awaiting it drains the whole chain.
    ///   3. The Task re-checks `isRunning` after `startHelperCapture` assigns
    ///      `helperCapture`, tearing the new helper back down if the share
    ///      stopped meanwhile — this is what prevents a racing Stop-Sharing
    ///      from orphaning a process holding replayd's slot.
    ///
    /// `resetCrashBudget` clears the sliding crash-window for the
    /// AppState-driven recovery path; auto-restart passes `false` to keep
    /// counting toward the 3-in-30s cap.
    ///
    /// The slot is deliberately not cleared on completion — harmless, and
    /// clearing it risks a clobber race with a restart that just populated it.
    @discardableResult
    private func scheduleHelperRestart(resetCrashBudget: Bool) -> Task<Error?, Never> {
        // Snapshot-and-install under one lock hold: any concurrent call
        // serializes here, so each new task chains onto its true predecessor.
        return restartTask.withLock { slot in
            let previous = slot
            let work = Task { [weak self] () -> Error? in
                // Serialize restarts strictly: let the previous one finish
                // (normally, or by unwinding from a stop-induced
                // CancellationError) before touching `helperCapture`.
                _ = await previous?.value
                guard let self else { return nil }
                // Claim the outgoing backend atomically, stop it outside
                // the lock (stop() awaits — never inside a lock hold).
                if let existing = self.takeHelperCapture() {
                    await existing.stop()
                }
                if resetCrashBudget {
                    self.helperCrashTimestampsNs.withLock { $0.removeAll() }
                }
                do {
                    guard self.isRunning else { throw CancellationError() }
                    let cachedFilter = self.lastFilterData.withLock { $0 }
                    guard let filterData = cachedFilter else {
                        throw NSError(
                            domain: "Tailscreen.HelperScreenCapture", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "no cached filter to restart against"])
                    }
                    try self.startHelperCapture(filterData: filterData)
                } catch {
                    if !self.isRunning {
                        await self.takeHelperCapture()?.stop()
                    }
                    return error
                }
                if !self.isRunning {
                    await self.takeHelperCapture()?.stop()
                }
                return nil
            }
            slot = work
            return work
        }
    }

    // MARK: - Control channel (annotations, remote control)

    /// True when some admitted viewer's UDP source shares `ip` (viewer keys
    /// are `ip:port`; TCP dials from the same IP but a different ephemeral
    /// port, so we match on IP). The trust anchor for the annotation gate.
    private func isAdmittedViewerIP(_ ip: String) -> Bool {
        viewers.withLock { state in state.keys.contains { Self.ipFromAddr($0) == ip } }
    }

    /// Log a dropped (ungated) annotation at most once per share so a peer
    /// spamming the back-channel can't flood the log.
    private let droppedAnnotationLogged = Guarded<Bool>(false)
    private func logDroppedAnnotation(peerAddress: String?) {
        let firstTime = droppedAnnotationLogged.withLock { logged -> Bool in
            if logged { return false }
            logged = true
            return true
        }
        guard firstTime else { return }
        logger.log("Dropped annotation from non-admitted peer \(peerAddress ?? "unknown")")
    }

    /// Log the "pending set full" drop at most once per saturation episode.
    private func logPendingCapReached(addr: String) {
        let firstTime = pendingCapLogged.withLock { logged -> Bool in
            if logged { return false }
            logged = true
            return true
        }
        guard firstTime else { return }
        logger.log("Pending-approval set full (\(Self.maxPendingViewers)) — dropping HELLO from \(addr)")
    }

    /// Log a dropped (non-grantee) input event at most once per share so a
    /// peer spamming the input channel can't flood the log.
    private func logDroppedInput() {
        let firstTime = droppedInputLogged.withLock { logged -> Bool in
            if logged { return false }
            logged = true
            return true
        }
        guard firstTime else { return }
        logger.log("Dropped input event from a connection that doesn't hold the control grant")
    }

    // MARK: - Remote-control grant

    /// Decode the cached `PickerSelection` so the injector can map normalized
    /// coordinates onto the shared region. Safe anywhere — it's just IDs, not
    /// an `SCContentFilter`.
    private func decodedSelection() -> PickerSelection? {
        guard let data = lastFilterData.withLock({ $0 }) else { return nil }
        return try? JSONDecoder().decode(PickerSelection.self, from: data)
    }

    /// Record (or refresh) a viewer's control request and surface it to the
    /// sharer UI. Resolves a cached hostname if we have one.
    private func recordControlRequest(connectionID: UUID, ip: String) {
        let hostname = peerNameCache.withLock { $0[ip] }
        controlRequests.withLock { state in
            if var existing = state[connectionID] {
                existing.hostname = existing.hostname ?? hostname
                state[connectionID] = existing
            } else {
                state[connectionID] = ControlRequestInfo(
                    id: connectionID, viewerIP: ip, hostname: hostname, arrivedAt: Date())
            }
        }
        logger.log("Remote-control request from \(ip)")
        notifyControlRequestsChanged()
    }

    private func removeControlRequest(connectionID: UUID) {
        let removed = controlRequests.withLock { $0.removeValue(forKey: connectionID) != nil }
        if removed { notifyControlRequestsChanged() }
    }

    /// Deny a pending control request (sharer clicked Deny): drop it and tell
    /// the requester via `.controlRevoked` so its UI leaves the "requested"
    /// state. No-op for an unknown connection.
    public func declineControlRequest(connectionID: UUID) {
        let existed = controlRequests.withLock { $0.removeValue(forKey: connectionID) != nil }
        guard existed else { return }
        notifyControlRequestsChanged()
        sendControlRevoked(to: connectionID, reason: "request declined")
        logger.log("Declined remote-control request on \(connectionID)")
    }

    /// Grant remote control to the pending request on `connectionID`. Refuses
    /// (returns false) when the process lacks Accessibility TCC — firing
    /// `onControlAccessibilityRequired` — rather than installing a grant
    /// `CGEventPost` would silently ignore. Implicitly revokes any previous
    /// grantee (single-holder invariant).
    @discardableResult
    public func grantControl(toConnectionID connectionID: UUID) -> Bool {
        guard isRunning else { return false }
        guard grantBypassesAccessibilityForTesting || (remoteControlInjector?.isTrusted() ?? false) else {
            // No injector, or permission missing: trigger the platform
            // permission prompt rather than install a grant injection would
            // silently ignore.
            remoteControlInjector?.promptForAccess()
            onControlAccessibilityRequired?()
            return false
        }
        let request = controlRequests.withLock { $0.removeValue(forKey: connectionID) }
        guard let request else { return false }
        notifyControlRequestsChanged()

        // Revoke a previous grantee before installing the new one.
        let previous = controlGrant.withLock { $0.grant }
        if let previous, previous.connectionID != connectionID {
            sendControlRevoked(to: previous.connectionID, reason: "granted to another viewer")
        }

        let stableID = peerStableIDCache.withLock { $0[request.viewerIP] }
        let grant = ControlGrant(
            connectionID: connectionID, viewerIP: request.viewerIP, stableID: stableID,
            hostname: request.hostname, grantedAt: Date())
        controlGrant.withLock { state in
            state.grant = grant
            state.generation += 1
        }
        droppedInputLogged.withLock { $0 = false }
        // Fresh grantee gets a clean rate window and an armed injector.
        inputRateLimiter.withLock { $0 = EventRateLimiter() }
        remoteControlInjector?.activate(selection: decodedSelection())
        Task { [weak self] in
            guard let self else { return }
            for channel in self.controlChannels {
                await channel.send(.controlGranted, to: connectionID)
            }
        }
        logger.log("Granted remote control to \(request.viewerIP)")
        notifyControlGrantChanged()
        return true
    }

    /// Revoke the live grant (if any): tell the grantee, drop any queued
    /// input, and clear the sharer UI. `reason` is a short English tag for
    /// logs — the viewer shows its own localized message.
    public func revokeControl(reason: String) {
        let previous = controlGrant.withLock { state -> ControlGrant? in
            let value = state.grant
            if value != nil {
                state.grant = nil
                state.generation += 1
            }
            return value
        }
        guard let previous else { return }
        remoteControlInjector?.deactivate()
        sendControlRevoked(to: previous.connectionID, reason: reason)
        logger.log("Revoked remote control from \(previous.viewerIP) (\(reason))")
        notifyControlGrantChanged()
    }

    /// Revoke the grant only when `connectionID` holds it. Used by the
    /// connection-close hook (the reliable auto-revoke-on-disconnect signal).
    private func revokeControlIfHeld(byConnection connectionID: UUID, reason: String) {
        let held = controlGrant.withLock { $0.grant?.connectionID == connectionID }
        if held { revokeControl(reason: reason) }
    }

    /// Revoke the grant only when the peer at `ip` holds it. Belt-and-braces
    /// for the UDP-side disconnect signals (BYE / idle sweep / expel), which
    /// don't carry the TCP connection UUID.
    private func revokeControlIfHeld(byIP ip: String, reason: String) {
        let held = controlGrant.withLock { $0.grant?.viewerIP == ip }
        if held { revokeControl(reason: reason) }
    }

    private func sendControlRevoked(to connectionID: UUID, reason: String) {
        Task { [weak self] in
            guard let self else { return }
            for channel in self.controlChannels {
                await channel.send(.controlRevoked(reason: reason), to: connectionID)
            }
        }
    }

    /// Hand the sharer the offer they clicked Open on, removing it. The host
    /// opens `url` in its browser; nil means it's gone (viewer left).
    public func takeLinkOffer(id: UUID) -> LinkOfferInfo? {
        let offer = linkOffers.withLock { $0.take(id: id) }
        if offer != nil { notifyLinkOffersChanged() }
        return offer
    }

    public func dismissLinkOffer(id: UUID) {
        let removed = linkOffers.withLock { $0.take(id: id) } != nil
        if removed { notifyLinkOffersChanged() }
    }

    private func recordLinkOffer(url: String, connectionID: UUID, ip: String) {
        let hostname = peerNameCache.withLock { $0[ip] }
        let offer = LinkOfferInfo(
            connectionID: connectionID, viewerIP: ip, hostname: hostname, url: url, arrivedAt: Date())
        linkOffers.withLock { $0.add(offer) }
        logger.log("Link offered by \(ip)")
        notifyLinkOffersChanged()
    }

    private func removeLinkOffers(connectionID: UUID) {
        let removed = linkOffers.withLock { $0.removeAll(connectionID: connectionID) }
        if removed { notifyLinkOffersChanged() }
    }

    private func notifyLinkOffersChanged() {
        guard let cb = onLinkOffersChanged else { return }
        cb(linkOffers.withLock { $0.offers })
    }

    private func notifyControlRequestsChanged() {
        guard let cb = onControlRequestsChanged else { return }
        let snapshot = controlRequests.withLock { state -> [ControlRequestInfo] in
            state.values.sorted { $0.arrivedAt < $1.arrivedAt }
        }
        cb(snapshot)
    }

    private func notifyControlGrantChanged() {
        guard let cb = onControlGrantChanged else { return }
        // Snapshot + generation read atomically: two racing notifies may
        // both observe the final state, but neither can pair a stale
        // snapshot with a newer generation (or vice versa).
        let (generation, info) = controlGrant.withLock { state -> (UInt64, ControlGrantInfo?) in
            guard let grant = state.grant else { return (state.generation, nil) }
            let snapshot = ControlGrantInfo(
                connectionID: grant.connectionID, viewerIP: grant.viewerIP, hostname: grant.hostname)
            return (state.generation, snapshot)
        }
        cb(generation, info)
    }

    /// Wire annotation + connection-close callbacks onto the
    /// `TailscreenControlListener`. The listener handles the framed-TCP
    /// accept loop and dispatch; we only see decoded
    /// `ScreenShareMessage.annotation` ops and per-connection close
    /// notifications here.
    private func installControlHandlers() {
        for channel in controlChannels { installControlHandlers(on: channel) }
    }

    /// One listener's worth of the wiring above. Called for the tailnet
    /// listener and (when live) the guest one — closures are identical on
    /// purpose: a guest connection passes the same admitted-viewer gate,
    /// single-grantee gate, and annotation bookkeeping. Only who can DIAL
    /// each tunnel differs, and that was decided at admission.
    private func installControlHandlers(on listener: TailscreenControlListener) {
        listener.onAnnotation = { [weak self] op, connectionID, peerAddress in
            guard let self else { return }
            // The TCP back-channel accepts from any peer that can dial 7447,
            // so an op is honoured only when its peer IP is an ADMITTED
            // viewer; pending/denied/blocked/expelled peers' ops are dropped.
            let peerIP = peerAddress.map { Self.ipFromAddr($0) }
            guard let peerIP, self.isAdmittedViewerIP(peerIP) else {
                self.annotationCounters.withLock { $0.dropped += 1 }
                self.logDroppedAnnotation(peerAddress: peerAddress)
                return
            }
            // Remember this connection's peer IP so `expelViewer` can sever
            // the back-channel by IP when the peer turns out to be blocked.
            self.annotationConnectionIP.withLock { $0[connectionID] = peerIP }
            // Lazily seed the per-connection tracking set on the first
            // annotation from a viewer so we have somewhere to retire
            // stroke UUIDs on disconnect.
            self.annotationsByConnection.withLock { state in
                if state[connectionID] == nil { state[connectionID] = [] }
            }
            self.annotationCounters.withLock { $0.applied += 1 }
            self.trackAnnotationOp(op, connectionID: connectionID)
            self.onAnnotationReceived?(op)
            // Fan out to every OTHER viewer so window / application share
            // modes can carry annotations peer-to-peer instead of relying
            // on SCStream catching the sharer's overlay panel. Queued rather
            // than spawned: this viewer's ops must reach the others in the
            // order it drew them.
            self.annotationCounters.withLock { $0.relayed += 1 }
            self.enqueueAnnotationBroadcast(op, excludingConnection: connectionID)
        }
        listener.onControlRequest = { [weak self] connectionID, peerAddress in
            guard let self else { return }
            // Only an admitted viewer may even ask for control — the TCP
            // channel accepts a dial from any peer, so gate on the same
            // admitted-viewer-IP anchor the annotation path uses.
            let peerIP = peerAddress.map { Self.ipFromAddr($0) }
            guard let peerIP, self.isAdmittedViewerIP(peerIP) else {
                self.logger.log("Dropped control request from non-admitted peer \(peerAddress ?? "unknown")")
                return
            }
            // Sharer preference: control requests disabled entirely. Reply
            // with `.controlRevoked` on the same connection (rather than
            // minting a new message type) so the viewer's UI leaves its
            // "requested" state immediately instead of waiting forever —
            // old viewers already handle it.
            guard self.controlRequestsAllowed.withLock({ $0 }) else {
                self.sendControlRevoked(to: connectionID, reason: "control requests disabled")
                self.logger.log("Declined control request from \(peerIP) (control requests disabled)")
                return
            }
            self.recordControlRequest(connectionID: connectionID, ip: peerIP)
        }
        listener.onOpenLink = { [weak self] url, connectionID, peerAddress in
            guard let self else { return }
            // A host that doesn't prompt never advertised `.openLink`, and
            // has no safe thing to do with the link.
            guard self.promptsForLinks else { return }
            let peerIP = peerAddress.map { Self.ipFromAddr($0) }
            guard let peerIP, self.isAdmittedViewerIP(peerIP) else {
                self.logger.log("Dropped link from non-admitted peer \(peerAddress ?? "unknown")")
                return
            }
            self.recordLinkOffer(url: url, connectionID: connectionID, ip: peerIP)
        }
        listener.onInputEvent = { [weak self] event, connectionID, _ in
            guard let self else { return }
            // Authoritative gate: inject only from the current grantee's
            // connection. Everything else is dropped and counted.
            let grant = self.controlGrant.withLock { $0.grant }
            guard RemoteControlPolicy.shouldInject(grant: grant, connectionID: connectionID) else {
                self.logDroppedInput()
                return
            }
            // Hard per-share rate ceiling on top of the viewer-side throttle.
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let allowed = self.inputRateLimiter.withLock { $0.allow(nowNs: nowNs) }
            guard allowed else { return }
            self.noteInputArrival(nowNs: nowNs)
            self.onInputEventForTesting?(event)
            self.remoteControlInjector?.apply(event)
        }
        listener.onControlReleased = { [weak self] connectionID in
            guard let self else { return }
            // The grantee is voluntarily giving up control — clear any pending
            // request on this connection and revoke if it holds the grant, so
            // the sharer UI and the gate release together.
            self.removeControlRequest(connectionID: connectionID)
            self.revokeControlIfHeld(byConnection: connectionID, reason: "viewer released")
        }
        listener.onMediaDatagram = { [weak self, weak listener] datagram, connectionID, peerAddress in
            guard let self, let listener else { return }
            self.handleStreamDatagram(
                datagram, connectionID: connectionID, peerAddress: peerAddress, listener: listener)
        }
        listener.onConnectionClosed = { [weak self] connectionID in
            guard let self else { return }
            // A stream (reliable-transport) viewer's connection closing IS
            // its BYE (TS-STM-004): drop the route first so no send site
            // re-routes to a dead connection, then retire the viewer like
            // any BYE would.
            if let streamAddr = self.streamAddrByConnection.withLock({ $0.removeValue(forKey: connectionID) }) {
                self.streamRoutes.withLock { _ = $0.removeValue(forKey: streamAddr) }
                self.removeViewer(addr: streamAddr)
                self.removePendingViewer(addr: streamAddr)
            }
            self.annotationConnectionIP.withLock { _ = $0.removeValue(forKey: connectionID) }
            // A closed connection can't hold a grant or a pending request.
            self.removeControlRequest(connectionID: connectionID)
            self.removeLinkOffers(connectionID: connectionID)
            self.revokeControlIfHeld(byConnection: connectionID, reason: "viewer disconnected")
            let outstanding = self.annotationsByConnection.withLock {
                $0.removeValue(forKey: connectionID) ?? []
            }
            guard !outstanding.isEmpty else { return }
            // Fire `.undo` for every UUID this viewer was on the hook for, so
            // their strokes don't outlive them on any overlay.
            let cb = self.onAnnotationReceived
            for uuid in outstanding {
                let op: AnnotationOp = .undo(uuid)
                cb?(op)
                // Same outbox as the relay above — a departing viewer's last
                // `.add` may still be queued, and an undo that overtakes it
                // would strand the stroke it was meant to remove.
                self.enqueueAnnotationBroadcast(op, excludingConnection: connectionID)
            }
        }
    }

    /// Detach this share's annotation handlers from the shared control
    /// listener so a subsequent share (or just request-to-share traffic)
    /// can attach its own without observing this share's stale closures.
    /// `onRequestToShare` is owned by AppState and intentionally untouched.
    private func uninstallControlHandlers() {
        for channel in controlChannels {
            channel.onAnnotation = nil
            channel.onConnectionClosed = nil
            channel.onControlRequest = nil
            channel.onOpenLink = nil
            channel.onInputEvent = nil
            channel.onControlReleased = nil
            channel.onMediaDatagram = nil
        }
    }

    /// Inbound half of the stream (reliable-transport, spec §2.2) profile:
    /// one `.mediaDatagram` frame's payload, processed exactly as the UDP
    /// receive loop would (TS-STM-001). The first frame mints the viewer's
    /// synthetic addr and installs its send route, so the HELLO's answer
    /// rides the connection it arrived on (TS-STM-002).
    private func handleStreamDatagram(
        _ datagram: Data, connectionID: UUID, peerAddress: String?, listener: TailscreenControlListener
    ) {
        // No share running: drop, same silence a UDP HELLO meets (TS-STM-007).
        guard isRunning else { return }
        let peerIP = peerAddress.map { Self.ipFromAddr($0) }
        let addr = streamAddrByConnection.withLock { state -> String in
            if let existing = state[connectionID] { return existing }
            let minted = Self.streamViewerAddr(peerIP: peerIP, connectionID: connectionID)
            state[connectionID] = minted
            return minted
        }
        streamRoutes.withLock {
            $0[addr] = StreamRoute(listener: listener, connectionID: connectionID)
        }
        // Guest classification mirrors the UDP receive loop: an addr is a
        // guest iff arriving on the guest control listener. Recorded BEFORE
        // handleIncoming so admission sees it on the first HELLO.
        let isGuestChannel = lifecycle.withLock { $0.guestControlListener === listener }
        if isGuestChannel {
            guestAddrs.withLock { _ = $0.insert(addr) }
        }
        // So `expelViewer` can sever the media connection by IP too — for a
        // stream viewer they're the same connection.
        if let peerIP {
            annotationConnectionIP.withLock { $0[connectionID] = peerIP }
        }
        handleIncoming(data: datagram, from: addr, transport: .stream)
    }

    /// Outbound half: `MediaSockets.send` calls this first for every
    /// datagram. True means addr is a stream viewer and the datagram was
    /// handed to its framed connection; false lets the send fall through
    /// to the UDP listeners.
    private func sendStreamDatagram(_ data: Data, to addr: String) async -> Bool {
        guard let route = streamRoutes.withLock({ $0[addr] }) else { return false }
        await route.listener.send(.mediaDatagram(data), to: route.connectionID)
        return true
    }

    /// Broadcast a framed `AnnotationOp` to every connection on the shared
    /// control listener, optionally skipping the one that originated the op
    /// (to avoid echoing a viewer's stroke back to them). Used both for
    /// sharer-painted strokes (no exclusion — sharer has no annotation
    /// connection) and viewer-to-viewer fan-out (exclude the source).
    public func broadcastAnnotation(_ op: AnnotationOp, excludingConnection: UUID? = nil) async {
        // A `.clearAll` wipes every stroke on every canvas — retire every
        // per-connection tracked UUID with it, or a later disconnect replays
        // spurious `.undo`s that resurrect an already-torn-down overlay.
        if case .clearAll = op {
            annotationsByConnection.withLock { state in
                state = state.mapValues { _ in [] }
            }
        }
        // Both tunnels: a tailnet viewer's stroke must reach guest viewers
        // and vice versa. `excluding` only matches on the origin's own
        // listener; on the other one it excludes nothing, which is right.
        for channel in controlChannels {
            await channel.broadcast(.annotation(op), excluding: excludingConnection)
        }
    }

    /// `TAILSCREEN_DEBUG_INPUT=1`: record time since the previous admitted
    /// input event. A gap far larger than capture cadence means events were
    /// held up en route, measured independently at the receiving end.
    private func noteInputArrival(nowNs: UInt64) {
        guard InputDebugLog.isEnabled else { return }
        let (gapNs, summary) = inputArrival.withLock { state -> (UInt64?, String?) in
            let gap = state.lastNs.map { nowNs &- $0 }
            state.lastNs = nowNs
            return (gap, state.sampler.note(gap ?? 0, nowNs: nowNs))
        }
        if let gapNs, gapNs >= Self.longInputGapNs {
            InputDebugLog.log("sharer arrival GAP \(InputDebugLog.ms(gapNs))")
        }
        if let summary {
            InputDebugLog.log("sharer arrivals \(summary) (gap between events)")
        }
    }

    /// A gap larger than this gets its own line. A controlling viewer emits
    /// moves at ~90 Hz, so a quarter second of silence mid-gesture is already
    /// far outside anything the capture side produces.
    private static let longInputGapNs: UInt64 = 250_000_000

    /// Update the per-connection annotation-UUID set in response to an
    /// inbound op: `.add` registers (idempotent for mid-drag updates),
    /// `.undo` retires, `.clearAll` empties.
    private func trackAnnotationOp(_ op: AnnotationOp, connectionID: UUID) {
        annotationsByConnection.withLock { state in
            switch op {
            case .add(let annotation):
                state[connectionID, default: []].insert(annotation.id)
            case .undo(let annotationID):
                state[connectionID]?.remove(annotationID)
            case .clearAll:
                state[connectionID] = []
            }
        }
    }

    // MARK: - Receive loop

    /// `NSError` domain marking a dead UDP receive loop. AppState treats
    /// this domain as non-recoverable: respawning the capture helper can't
    /// fix a socket loop that can no longer read, so it goes straight to
    /// `stopSharing` instead of the capture-restart path.
    public static let receiveLoopErrorDomain = "Tailscreen.ReceiveLoop"

    /// `NSError` domain marking a helper failure classified non-retryable
    /// (`classifyHelperExit` → `.slotRefused`/`.permanent`). AppState goes
    /// straight to `stopSharing`, never `restartCapture()` — without this a
    /// closed single-window share would respawn into `windowNotFound` forever.
    public static let helperUnrecoverableErrorDomain = "Tailscreen.HelperUnrecoverable"

    /// `NSError` domain for the one *expected* non-retryable exit: the
    /// captured window/display/app was closed (`.sourceGone`). Tears down
    /// like `helperUnrecoverableErrorDomain` but reports a gentle notice
    /// instead of an error alert.
    public static let helperSourceGoneErrorDomain = "Tailscreen.HelperSourceGone"

    /// `NSError` domain for capture stopped by the user through a platform
    /// affordance outside the app (Control Center's Stop button, a portal
    /// revoke). Torn down quietly, not as a failure. Named ourselves (rather
    /// than `SCStreamError.userStopped`) so a non-Apple backend can raise it too.
    public static let userStoppedErrorDomain = "Tailscreen.CaptureUserStopped"

    /// Error surfaced through `onCaptureStopped` when the control-receive
    /// loop gives up — `ReceiveLoopPolicy.maxConsecutiveErrors` in a row, or
    /// the `maxErrorsPerWindow` windowed backstop.
    private static func receiveLoopDeadError(underlying: Error) -> NSError {
        NSError(
            domain: receiveLoopErrorDomain,
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "UDP receive loop gave up after repeated receive errors: \(underlying)"
            ]
        )
    }

    /// Drains UDP datagrams and routes control bytes (HELLO/KEEPALIVE/BYE/PLI).
    /// RTP packets shouldn't arrive here; if they do (a confused client),
    /// they're dropped (identified by V=2 in byte 0).
    ///
    /// A non-timeout receive error retries after capped exponential backoff
    /// (`ReceiveLoopPolicy`); `maxConsecutiveErrors` in a row, or
    /// `maxErrorsPerWindow` in the trailing window, means the socket is dead
    /// and the share tears down via `onCaptureStopped`.
    ///
    /// `TailscaleError.readFailed` is ambiguous — the benign 1s poll timeout
    /// and a dead fd (POLLHUP → instant return) both surface as it — so
    /// elapsed-time classification below tells them apart.
    private func receiveControlLoop(pl: PacketListener, isGuest: Bool) async {
        var consecutiveErrors = 0
        var errorStampsNs: [UInt64] = []
        while isRunning {
            let recvStartNs = DispatchTime.now().uptimeNanoseconds
            do {
                let (data, from) = try await pl.recv(timeout: 1_000)
                consecutiveErrors = 0
                if isGuest {
                    // Decided here, once, for the share's life — everything
                    // downstream keys off this set.
                    guestAddrs.withLock { _ = $0.insert(from) }
                }
                handleIncoming(data: data, from: from)
            } catch {
                guard isRunning else { break }
                // A detached guest listener errors its own loop out — the
                // intended shutdown, not a dead socket to log.
                if isGuest, lifecycle.withLock({ $0.guestPacketListener !== pl }) { break }
                if case TailscaleError.readFailed = error {
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds &- recvStartNs
                    if !ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: elapsedNs) {
                        consecutiveErrors = 0
                        continue  // poll timeout, just keep polling
                    }
                    // Near-instant readFailed = dead fd; count as an error.
                }
                consecutiveErrors += 1
                let nowNs = DispatchTime.now().uptimeNanoseconds
                let windowCount = ReceiveLoopPolicy.slidingWindowErrorCount(&errorStampsNs, appending: nowNs)
                let total = receiveLoopErrorTotal.withLock { count -> Int in
                    count += 1
                    return count
                }
                logger.log(
                    "Server: receive error #\(consecutiveErrors) (\(windowCount) in window, total \(total)): \(error)"
                )
                let deadConsecutive = consecutiveErrors >= ReceiveLoopPolicy.maxConsecutiveErrors
                let deadWindowed = windowCount >= ReceiveLoopPolicy.maxErrorsPerWindow
                if deadConsecutive || deadWindowed {
                    let detail = "\(consecutiveErrors) consecutive, \(windowCount) in window, \(total) total"
                    // In a guest-ONLY share the guest listener is the only
                    // socket there is, so its death is the share's — read the
                    // live lifecycle rather than a spawn-time flag, because a
                    // share can gain/lose its tailnet half over its life.
                    let tailnetAlive = lifecycle.withLock { $0.packetListener != nil }
                    if isGuest && tailnetAlive {
                        // Guests losing their socket must not tear down the
                        // tailnet share; the token side just goes dark.
                        logger.log("Server: guest receive loop dead (\(detail)) — token share offline")
                    } else {
                        logger.log("Server: receive loop dead (\(detail)) — stopping share")
                        onCaptureStopped?(Self.receiveLoopDeadError(underlying: error))
                    }
                    break
                }
                try? await Task.sleep(
                    nanoseconds: ReceiveLoopPolicy.retryDelayNs(consecutiveErrors: consecutiveErrors))
            }
        }
    }

    /// How a datagram reached the server: its own UDP socket, or framed
    /// over a stream viewer's TCP connection (spec §2.2). Everything
    /// downstream is transport-agnostic; the one divergence is the HELLO
    /// caps mask below (TS-STM-005).
    enum DatagramTransport {
        case udp
        case stream
    }

    private func handleIncoming(data: Data, from addr: String, transport: DatagramTransport = .udp) {
        guard !data.isEmpty else { return }
        if !ScreenShareControlMessage.looksLikeControl(data) {
            // RTP from a viewer is only allowed for audio (PT=98). Anything
            // else (video PTs) is dropped.
            if let (header, _) = RTPHeader.decode(from: data),
                header.payloadType == RTPHeader.voicePayloadType
            {
                handleInboundAudioRTP(data, header: header, from: addr)
            }
            return
        }
        guard let kind = ScreenShareControlMessage.decode(data) else { return }

        switch kind {
        case .hello:
            // Re-ack on every HELLO, not just first registration — a viewer
            // that lost its SSRC (process restart, NAT rebind) needs the ack
            // again to send audio. Pending viewers never get an ack — the
            // sharer hasn't said yes yet.
            var caps = ScreenShareControlMessage.decodeHelloCaps(data)
            if transport == .stream {
                // TS-STM-005: NACK/FEC are dead weight on a lossless
                // transport; mask here so a non-conforming stream viewer
                // doesn't get them either.
                caps = Self.streamHelloCaps(caps)
            }
            viewerCaps.withLock { $0[addr] = caps }
            // Sampled BEFORE `registerOrRefresh`, which is what parks a new
            // viewer: afterwards every arrival looks like it was already
            // pending, and the "newly parked" test below would never fire.
            let wasAlreadyPending = pendingViewers.withLock { $0[addr] != nil }
            recorder?.record(
                .helloReceived,
                role: .sharer,
                fields: [
                    "addr": .string(addr),
                    "caps": .string(caps.diagnosticDescription),
                    "transport": .string(transport == .stream ? "stream" : "datagram"),
                    "guest": .bool(isGuestAddr(addr))
                ])
            registerOrRefresh(addr: addr, isNew: true)
            if let assignedSSRC = (viewers.withLock { $0[addr]?.audioSSRC }) {
                let ack = helloAckDatagram(for: addr, ssrc: assignedSSRC)
                // `ssrc` is what `DiagnosticsMerge` pairs this event with the
                // viewer's `hello.ack.received` on for clock alignment.
                // Recorded here (not inside the send Task) so the stamp is
                // the sharer's decision moment, not an async hop later.
                recorder?.record(
                    .helloAckSent,
                    role: .sharer,
                    fields: [
                        "addr": .string(addr),
                        "ssrc": DiagnosticValue(assignedSSRC),
                        // Mirrors `helloAckDatagram`'s branch: a legacy HELLO
                        // gets a caps-less 5-byte ack, so reporting the full
                        // `serverCaps` here would misstate what went out.
                        "server_caps": .string(
                            caps.isEmpty ? "none (legacy ack)" : serverCaps.diagnosticDescription),
                        "deferred": .bool(false)
                    ])
                Task { [weak self] in
                    guard let pl = self?.media else { return }
                    try? await pl.send(ack, to: addr)
                }
            } else if (pendingViewers.withLock { $0[addr] != nil }) {
                // Only on the transition into pending — a per-retry event
                // would push the rest of the session out of the buffer.
                if !wasAlreadyPending {
                    recorder?.record(
                        .helloPendingSent, role: .sharer, fields: ["addr": .string(addr)])
                }
                // Echo HELLO_PENDING so the viewer flips to "Waiting for
                // approval"; resend on every retry in case one was lost.
                Task { [weak self] in
                    guard let pl = self?.media else { return }
                    let pending = ScreenShareControlMessage.encode(.helloPending)
                    try? await pl.send(pending, to: addr)
                }
            }
        case .keepalive:
            registerOrRefresh(addr: addr, isNew: false)
        case .bye:
            removeViewer(addr: addr)
            removePendingViewer(addr: addr)
        case .pli:
            registerOrRefresh(addr: addr, isNew: false)
            recordPLI(from: addr)
            helperCapture?.requestKeyframe()
        case .helloAck:
            // Server never receives HELLO_ACK from a viewer; ignore.
            break
        case .serverBye:
            // SERVER_BYE is server→viewer only. A viewer sending it is
            // either confused or malicious; drop the packet on the floor.
            return
        case .helloPending:
            // HELLO_PENDING is server→viewer only. Ignore from viewers.
            return
        case .helloDenied:
            // HELLO_DENY is server→viewer only. Ignore from viewers.
            return
        case .codecUnsupported:
            registerOrRefresh(addr: addr, isNew: false)
            handleCodecUnsupported(from: addr)
        case .profileUnsupported:
            registerOrRefresh(addr: addr, isNew: false)
            handleProfileUnsupported(from: addr)
        case .nack:
            registerOrRefresh(addr: addr, isNew: false)
            handleNACK(data: data, from: addr)
        case .receiverReport:
            registerOrRefresh(addr: addr, isNew: false)
            handleReceiverReport(data: data, from: addr)
        case .ping:
            // PING is server→viewer only. Ignore from viewers.
            return
        case .fec:
            // FEC parity is server→viewer only. Ignore from viewers.
            return
        }
    }

    /// Build the HELLO_ACK for `addr`: the 6-byte extended form (carrying the
    /// server's caps) when the viewer advertised any capability, else the
    /// legacy 5-byte ack a pre-NACK viewer's strict decoder expects.
    private func helloAckDatagram(for addr: String, ssrc: UInt32) -> Data {
        let caps = viewerCaps.withLock { $0[addr] } ?? []
        if caps.isEmpty {
            return ScreenShareControlMessage.encodeHelloAck(ssrc: ssrc)
        }
        return ScreenShareControlMessage.encodeHelloAck(ssrc: ssrc, caps: serverCaps)
    }

    /// Serve a viewer NACK from the retransmit ring, subject to the per-viewer
    /// token budget. Sequence numbers still in the ring and within budget are
    /// resent byte-identically (header rewritten to the requested seq + the
    /// viewer's SSRC); anything evicted or over budget converts to the existing
    /// PLI path so recovery is never worse than today's keyframe.
    private func handleNACK(data: Data, from addr: String) {
        guard isRunning else { return }
        let entries = ScreenShareControlMessage.decodeNACK(data)
        guard !entries.isEmpty else { return }

        var requested: [UInt16] = []
        for entry in entries {
            requested.append(entry.pid)
            var blp = entry.blp
            var bit: UInt16 = 1
            while blp != 0 {
                if blp & 1 != 0 { requested.append(entry.pid &+ bit) }
                blp >>= 1
                bit &+= 1
            }
        }
        guard !requested.isEmpty else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let snapshot = viewers.withLock { state -> (RetransmitBuffer.BudgetState, UInt32)? in
            guard let viewer = state[addr] else { return nil }
            return (viewer.retransmitBudget, viewer.ssrc)
        }
        guard let (budget0, ssrc) = snapshot else { return }
        var budget = budget0
        let current = currentBitrate.withLock { $0 }
        // Budget: 25 % of the current bitrate, expressed in packets/sec.
        let bytesPerSec = Double(max(current, TransportTuning.adaptiveFloorMinBps)) / 8.0 * 0.25
        let tokensPerSecond = max(10.0, bytesPerSec / Double(H264Packetizer.maxPayloadBytes))
        let config = RetransmitBuffer.BudgetConfig(
            tokensPerSecond: tokensPerSecond, maxTokens: max(20.0, tokensPerSecond / 2))
        let decision = RetransmitBuffer.retransmitDecision(
            requested: requested,
            ringHas: { self.retransmitBuffer.has(addr: addr, seq: $0) },
            state: &budget,
            config: config,
            nowNs: now)

        // Copy the mutated budget into a `let` — the `withLock` closure is
        // @Sendable and can't capture the outer `var budget`.
        let updatedBudget = budget
        let servedCount = decision.serve.count
        viewers.withLock { state in
            guard var viewer = state[addr] else { return }
            viewer.retransmitBudget = updatedBudget
            viewer.nackServedThisWindow += servedCount
            state[addr] = viewer
        }

        if !decision.serve.isEmpty, let pl = media {
            let served = decision.serve
            Task { [weak self] in
                guard let self else { return }
                var sent = 0
                var evictedMidFlight = false
                for seq in served {
                    // TOCTOU: `has()` said yes when we budgeted, but a batch can
                    // be evicted between then and now. A missing template here
                    // must fall back to the keyframe path — otherwise the viewer
                    // gets neither the packet nor a PLI.
                    guard var pkt = self.retransmitBuffer.template(addr: addr, seq: seq) else {
                        evictedMidFlight = true
                        continue
                    }
                    Self.rewriteRTPHeader(&pkt, sequence: seq, ssrc: ssrc)
                    try? await pl.send(pkt, to: addr)
                    sent += 1
                }
                if evictedMidFlight {
                    self.recordPLI(from: addr)
                    self.helperCapture?.requestKeyframe()
                }
                self.onNACKServedForTesting?(addr, sent)
            }
        }
        if decision.fallbackPLI {
            // Gap too old for the ring or over budget — recover via a keyframe.
            recordPLI(from: addr)
            helperCapture?.requestKeyframe()
        }
    }

    /// Fold a viewer's receiver report into its congestion inputs: record the
    /// RR loss fraction and derive RTT from the echoed ping (RTT = now −
    /// lastPingTs − the viewer's own reporting delay).
    private func handleReceiverReport(data: Data, from addr: String) {
        guard let report = ScreenShareControlMessage.decodeReceiverReport(data) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        var computedRTT: UInt64 = 0
        if report.lastPingTs != 0, now > report.lastPingTs {
            let raw = now &- report.lastPingTs
            let delayNs = UInt64(report.delaySincePingMs) &* 1_000_000
            computedRTT = raw > delayNs ? raw &- delayNs : raw
        }
        // `let` copies — the @Sendable `withLock` closure can't capture the
        // outer mutable `computedRTT`.
        let rttNs = computedRTT
        let lossQ8 = Int(report.fracLostQ8)
        // A non-FEC peer can't legitimately have recovered anything, so a
        // stray/forged trailing field must not feed the FEC arm.
        let viewerHasFEC = viewerCaps.withLock { $0[addr]?.contains(.fec) ?? false }
        let fecRecovered = viewerHasFEC ? Int(report.fecRecovered) : 0
        let nackRecovered = viewerHasFEC ? Int(report.nackRecovered) : 0
        viewers.withLock { state in
            guard var viewer = state[addr] else { return }
            viewer.lossFractionQ8 = lossQ8
            viewer.lastRRAtNs = now
            if rttNs > 0 { viewer.rttNs = rttNs }
            viewer.fecRecoveredThisWindow += fecRecovered
            viewer.nackRecoveredThisWindow += nackRecovered
            state[addr] = viewer
        }
    }

    /// A viewer reported it can't decode the current codec. Latch to H.264
    /// and respawn. Idempotent via `forceH264` — a CODEC_NO storm from a
    /// still-black-screened viewer triggers at most one restart.
    private func handleCodecUnsupported(from addr: String) {
        guard isRunning else { return }
        // Explicit HEVC preference: the user opted out of the H.264 safety
        // net knowingly, so an incapable viewer stays unserved instead of
        // downgrading the whole share.
        guard sessionQuality.withLock({ $0 }).codecPreference != .hevc else {
            logger.log(
                "Viewer \(addr) can't decode HEVC — ignoring CODEC_NO (explicit HEVC preference)")
            return
        }
        let shouldFallback = forceH264.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard shouldFallback else { return }
        logger.log("Viewer \(addr) can't decode the current stream — falling back to H.264")
        Task { [weak self] in
            try? await self?.restartCapture()
        }
    }

    /// A viewer reported it can decode the codec but not its bit depth (10-bit
    /// HEVC Main 10 on 8-bit-only hardware). Catches a decoder that surprises
    /// its own viewer, after `.tenBit` in the HELLO already failed to prevent it.
    private func handleProfileUnsupported(from addr: String) {
        guard isRunning else { return }
        latchEightBit(reason: "viewer \(addr) can't decode the current bit depth (PROFILE_NO)")
    }

    /// Latch to 8-bit and respawn. Idempotent, so a PROFILE_NO storm or a
    /// burst of non-`.tenBit` joins costs at most one restart.
    private func latchEightBit(reason: String) {
        let shouldFallback = force8bit.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard shouldFallback else { return }
        logger.log("Falling back to 8-bit — \(reason)")
        Task { [weak self] in
            try? await self?.restartCapture()
        }
    }

    /// Pure: must a share that wants 10-bit drop to 8-bit for this set of
    /// admitted viewers? True when the host asked for 10-bit, we haven't
    /// already latched down, and at least one admitted viewer did not
    /// advertise `.tenBit`.
    ///
    /// The three guards are each load-bearing. `tenBitRequested` keeps an
    /// ordinary 8-bit share from restarting capture for a viewer whose
    /// capability was never going to matter. `alreadyEightBit` makes the
    /// decision idempotent so a second incapable viewer costs nothing. And an
    /// EMPTY viewer list is not a downgrade: a share starts before anyone
    /// connects, and treating "nobody yet" as "somebody can't" would pin every
    /// share to 8-bit forever, since the latch never lifts.
    ///
    /// Absence of the bit is read as "can't decode 10-bit", never as unknown
    /// (TS-CAP-006): a legacy viewer sends a capability-less HELLO and has no
    /// way to say otherwise, and guessing generously there is precisely the
    /// blank screen this gate exists to prevent.
    public static func tenBitDowngradeNeeded(
        tenBitRequested: Bool,
        alreadyEightBit: Bool,
        viewerCaps: [ScreenShareCaps]
    ) -> Bool {
        guard tenBitRequested, !alreadyEightBit, !viewerCaps.isEmpty else { return false }
        return viewerCaps.contains { !$0.contains(.tenBit) }
    }

    /// Apply `tenBitDowngradeNeeded` to the live admitted set. Called when a
    /// viewer joins and when the host turns the 10-bit setting on; the helper
    /// picks the resulting latch up through `TAILSCREEN_FORCE_8BIT` on the
    /// respawn `latchEightBit` schedules.
    private func enforceBitDepthCapability(trigger: String) {
        guard isRunning else { return }
        let addrs = viewers.withLock { Array($0.keys) }
        // Admitted viewers only: a pending viewer has its caps recorded at
        // HELLO but receives no video until it is approved, and restarting
        // capture for someone the sharer may yet decline would spend a
        // visible interruption on a non-viewer.
        let capsByAddr = viewerCaps.withLock { $0 }
        let caps = addrs.map { capsByAddr[$0] ?? [] }
        guard
            Self.tenBitDowngradeNeeded(
                tenBitRequested: tenBitRequested.withLock { $0 },
                alreadyEightBit: force8bit.withLock { $0 },
                viewerCaps: caps)
        else { return }
        latchEightBit(reason: "a viewer without 10-bit decode is watching (\(trigger))")
    }

    /// Enqueue one audio packet onto each recipient's own send chain, so a
    /// stalled recipient's audio doesn't delay everyone else's. Drop-newest
    /// at the cap (audio is loss-tolerant); chains are mutated in place, not
    /// rebuilt, since audio has multiple producers addressing different
    /// subsets — stale chains are pruned at viewer-removal points.
    private func enqueueAudioPackets(_ packet: Data, to recipients: [String], on pl: MediaSockets) {
        guard !recipients.isEmpty else { return }
        audioSendTails.withLock { tails in
            for addr in recipients {
                var chain = tails[addr] ?? ViewerSendChain()
                let cap = Self.maxQueuedAudioPacketsPerViewer
                guard Self.shouldEnqueue(queued: chain.queuedFrames, cap: cap) else {
                    chain.droppedFrames += 1
                    tails[addr] = chain
                    continue
                }
                let prev = chain.task
                chain.queuedFrames += 1
                let job = Task { [weak self] in
                    await prev?.value
                    try? await pl.send(packet, to: addr)
                    self?.audioSendTails.withLock { $0[addr]?.queuedFrames -= 1 }
                }
                chain.task = job
                tails[addr] = chain
            }
        }
    }

    /// Relay one inbound audio RTP packet to all other viewers and pass a
    /// copy to the local VoiceChannel. Forwarded byte-for-byte (no
    /// transcode) so recipients see the original sender's SSRC.
    private func handleInboundAudioRTP(_ packet: Data, header: RTPHeader, from sender: String) {
        let validated = viewers.withLock { state -> (valid: Bool, recipients: [String]) in
            let decision = Self.audioRelayDecision(
                viewerAudioSSRCs: state.mapValues { $0.audioSSRC },
                sender: sender,
                headerSSRC: header.ssrc
            )
            // Counted under the same lock that judged it, so accepted/
            // rejected tallies can never disagree about one packet.
            if var viewer = state[sender] {
                if decision.valid {
                    viewer.audioPacketsThisWindow += 1
                } else {
                    viewer.audioRejectedThisWindow += 1
                }
                state[sender] = viewer
            }
            return decision
        }
        guard validated.valid else { return }
        if let pl = media {
            enqueueAudioPackets(packet, to: validated.recipients, on: pl)
        }
        onAudioReceived?(packet)
    }

    /// Append a PLI timestamp to the viewer's ring; the adaptive sweep
    /// (every 5s) reads these for the bitrate-cut decision. Drop past 32 —
    /// comfortably more than a 5s window can observe.
    private func recordPLI(from addr: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        let recorded = viewers.withLock { state -> Bool in
            guard var viewer = state[addr] else { return false }
            viewer.pliTimestampsNs = Self.appendingPLI(viewer.pliTimestampsNs, timestampNs: now)
            state[addr] = viewer
            return true
        }
        if recorded { onPLIRecordedForTesting?(addr) }
    }

    // MARK: - Admission bookkeeping & roster maintenance

    private func registerOrRefresh(addr: String, isNew: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds

        // If this addr is already pending, just refresh its lastSeen and
        // bail — don't promote it, don't add to `viewers`. Only
        // `approveViewer` does the promotion.
        let wasPending = pendingViewers.withLock { state -> Bool in
            guard var existing = state[addr] else { return false }
            existing.lastSeenNs = now
            state[addr] = existing
            return true
        }
        if wasPending { return }

        // Kicked-viewer quiet window: a straggler from an addr `expelViewer`
        // just removed must not re-run admission (see `expelledAddrs`);
        // re-send the denial. A fresh HELLO is a deliberate reconnect —
        // clear the entry and let it through normally.
        if isNew {
            expelledAddrs.withLock { _ = $0.removeValue(forKey: addr) }
        } else {
            let recentlyExpelled = expelledAddrs.withLock { state -> Bool in
                let decision = Self.expelledQuietDecision(
                    expelledAtNs: state, addr: addr, nowNs: now, quietNs: expelledQuietNs)
                state = decision.remaining
                return decision.isQuieted
            }
            if recentlyExpelled {
                // Deliberately NOT recorded, unlike the remembered-deny branch
                // below — this fires per straggler KEEPALIVE across the 30s
                // quiet window and would push the buffer out saying nothing
                // `viewer.expelled` didn't already say.
                sendDenialDatagrams(to: addr)
                return
            }
        }

        let approvalRequired = requireApproval.withLock { $0 }
        let alreadyKnown = viewers.withLock { $0[addr] != nil }
        let ip = Self.ipFromAddr(addr)

        // A re-HELLO with a cached StableNodeID applies its remembered
        // policy synchronously; a fresh/uncached peer passes `nil`, so
        // `admissionDecision` degrades to the plain approval gate. Resolution
        // for a fresh peer happens async below, applied post-resolution.
        let guest = isGuestAddr(addr)
        let cachedStableID = alreadyKnown ? nil : peerStableIDCache.withLock({ $0[ip] })
        let cachedPolicy = cachedStableID.flatMap { id in accessPolicies.withLock { $0[id] } }
        var admission = Self.admissionDecision(
            policy: cachedPolicy, requireApproval: approvalRequired, isGuest: guest)
        // A one-time pre-approval (from accepting this peer's request-to-share)
        // admits it straight away — but never overrides a remembered deny,
        // and never applies to guests (their approval is per-join, always).
        if !alreadyKnown && admission != .reject && !guest {
            let preApproved = preApprovedIPs.withLock { $0.remove(ip) != nil }
            if preApproved { admission = .admit }
        }
        if !alreadyKnown && admission == .reject {
            logger.log("Viewer \(addr) rejected (remembered deny)")
            // Recorded here (not only in `denyViewer`): this path never
            // reaches `denyViewer`, so a remembered "Deny & Block" needs its
            // own record.
            recorder?.record(
                .viewerDenied,
                role: .sharer,
                fields: [
                    "addr": .string(addr),
                    "guest": .bool(guest),
                    "reason": .string("remembered deny")
                ])
            recorder?.record(
                .helloDeniedSent, role: .sharer, fields: ["addr": .string(addr)])
            sendDenialDatagrams(to: addr)
            return
        }

        // Brand new addr waiting for the sharer: park in pending, allocating
        // the audio SSRC up front so the eventual HELLO_ACK can reuse it.
        if admission == .park && !alreadyKnown {
            let cachedName = peerNameCache.withLock { $0[ip] }
            let cachedStableID = peerStableIDCache.withLock { $0[ip] }
            let info = PendingViewerInfo(
                id: addr, tailscaleIP: ip, hostname: cachedName, stableID: cachedStableID,
                arrivedAt: Date(), isGuest: guest)
            let accepted = pendingViewers.withLock { state -> Bool in
                guard Self.canAcceptPending(currentCount: state.count, isExisting: state[addr] != nil) else {
                    return false
                }
                var ssrc: UInt32
                repeat {
                    // Sharer voice owns 0, system audio owns 1 (see RTPHeader).
                    ssrc = UInt32.random(in: RTPHeader.firstViewerSSRC...UInt32.max)
                } while state.values.contains(where: { $0.audioSSRC == ssrc })
                state[addr] = PendingViewer(
                    addr: addr, audioSSRC: ssrc, lastSeenNs: now, info: info)
                return true
            }
            guard accepted else {
                logPendingCapReached(addr: addr)
                return
            }
            logger.log("Viewer pending approval \(addr)")
            notifyPendingViewersChanged()
            if cachedName == nil || cachedStableID == nil {
                scheduleIdentityResolve()
            }
            // Close the toggle-off race: if the queue drained between our
            // gate read and this insert, self-promote through the same gate
            // (so a remembered deny still wins) rather than stranding the
            // viewer.
            if !requireApproval.withLock({ $0 }) {
                applyRememberedPolicyToPending(addr: addr, stableID: cachedStableID)
            }
            return
        }

        let cachedName = peerNameCache.withLock { $0[ip] }
        let newInfo = ViewerInfo(
            id: addr,
            tailscaleIP: ip,
            hostname: cachedName,
            stableID: cachedStableID,
            connectedAt: Date(),
            isGuest: guest
        )
        let (added, viewerCount, audioSSRC) = viewers.withLock { state -> (Bool, Int, UInt32) in
            if var existing = state[addr] {
                existing.lastSeenNs = now
                state[addr] = existing
                return (false, state.count, existing.audioSSRC)
            }
            var newAudioSSRC: UInt32
            repeat {
                // Sharer voice owns 0, system audio owns 1 (see RTPHeader).
                newAudioSSRC = UInt32.random(in: RTPHeader.firstViewerSSRC...UInt32.max)
            } while state.values.contains(where: { $0.audioSSRC == newAudioSSRC })
            let v = Viewer(
                addr: addr,
                ssrc: UInt32.random(in: RTPHeader.firstViewerSSRC...UInt32.max),
                audioSSRC: newAudioSSRC,
                nextSequence: UInt16.random(in: 0...UInt16.max),
                lastSeenNs: now,
                admittedAtNs: now,
                info: newInfo
            )
            state[addr] = v
            return (true, state.count, newAudioSSRC)
        }

        if added && !isNew {
            // Proactively ACK a viewer newly ADDED without a fresh HELLO —
            // one whose source address changed under a NAT/DERP path
            // migration and re-registered via KEEPALIVE. Without this it
            // never learns its new SSRC and its mic audio drops silently.
            //
            // `!isNew`: the HELLO path sends its own ack right after, and two
            // acks for one join would desync the recorded handshake timestamps
            // (`t3`/`t4` from different datagrams), producing a bogus negative
            // RTT.
            let ack = helloAckDatagram(for: addr, ssrc: audioSSRC)
            Task { [weak self] in
                guard let pl = self?.media else { return }
                try? await pl.send(ack, to: addr)
            }
            publishAddedViewer(addr: addr)
        }

        if added || isNew {
            logger.log("Viewer \(added ? "joined" : "refreshed") \(addr) (total=\(viewerCount))")
            // Force a keyframe so a new/re-helloed viewer gets something
            // decodable immediately (SPS/PPS travel in-band on the IDR).
            helperCapture?.requestKeyframe()
        }
    }

    /// Toggle the per-session approval gate. Called by AppState when the
    /// user flips the "Require approval for new viewers" toggle; safe to
    /// call before, during, or after `start()`. Turning the toggle off
    /// auto-approves anyone currently waiting.
    public func setRequireApproval(_ enabled: Bool) {
        let prev = requireApproval.withLock { existing -> Bool in
            let p = existing
            existing = enabled
            return p
        }
        guard prev != enabled else { return }
        logger.log("requireApproval \(prev ? "on" : "off") → \(enabled ? "on" : "off")")
        if !enabled {
            // Drain whatever's been parked — the sharer just opted into
            // open-door mode, so admit everyone in the pending queue —
            // except remembered-deny peers, who get denied instead
            // ("Deny & block" outranks the gate).
            let pendingStableIDs = pendingViewers.withLock { state in
                state.mapValues { $0.info.stableID }
            }
            let policies = accessPolicies.withLock { $0 }
            let decision = Self.drainDecision(
                pendingStableIDs: pendingStableIDs, policies: policies,
                guestAddrs: guestAddrs.withLock { $0 })
            for addr in decision.deny {
                denyViewer(addr: addr)
            }
            for addr in decision.approve {
                approveViewer(addr: addr)
            }
        }
    }

    /// Replace the remembered per-peer policy snapshot. Called by AppState
    /// at share start and whenever the persistent store changes. Safe on
    /// any thread. Re-evaluates viewers already parked pending whose
    /// StableNodeID has resolved, so an "Always allow" / "Deny & block"
    /// issued while someone is waiting acts on them immediately.
    public func setAccessPolicies(_ policies: [String: PeerPolicy]) {
        accessPolicies.withLock { $0 = policies }
        let resolved = pendingViewers.withLock { state in
            state.compactMap { (addr, viewer) in viewer.info.stableID.map { (addr, $0) } }
        }
        for (addr, stableID) in resolved {
            applyRememberedPolicyToPending(addr: addr, stableID: stableID)
        }
        // Sweep the CONNECTED roster too: a "Deny & Block" applied to an
        // already-connected peer must expel it here, not merely block its
        // future HELLOs (which never come — it's already in the fan-out).
        let connectedStableIDs = viewers.withLock { state in
            state.mapValues { $0.info.stableID }
        }
        for addr in Self.connectedDenyList(viewerStableIDs: connectedStableIDs, policies: policies) {
            logger.log("Expelling connected viewer \(addr): policy changed to deny")
            expelViewer(addr: addr, reason: "remembered deny")
        }
    }

    /// One-time pre-approve a peer by IP so its next HELLO joins the
    /// fan-out immediately, bypassing the approval gate — but NOT a
    /// remembered `deny` (a blocked peer stays blocked). Called after the
    /// sharer accepts that peer's request-to-share, so their connect doesn't
    /// hit a second consent prompt.
    public func preApproveViewer(ip: String) {
        preApprovedIPs.withLock { _ = $0.insert(ip) }
    }

    /// Run the admission gate for a viewer currently parked in
    /// `pendingViewers` and act on the outcome. `.park` leaves them
    /// waiting on the sharer's manual Accept / Deny. No-op for addresses
    /// that are no longer pending (`approveViewer` / `denyViewer` both
    /// tolerate unknown addrs).
    private func applyRememberedPolicyToPending(addr: String, stableID: String?) {
        let policy = stableID.flatMap { id in accessPolicies.withLock { $0[id] } }
        let gate = requireApproval.withLock { $0 }
        switch Self.admissionDecision(policy: policy, requireApproval: gate, isGuest: isGuestAddr(addr)) {
        case .admit:
            logger.log("Pending viewer \(addr) auto-admitted (remembered allow or gate off)")
            approveViewer(addr: addr)
        case .reject:
            logger.log("Pending viewer \(addr) rejected (remembered deny)")
            denyViewer(addr: addr)
        case .park:
            break
        }
    }

    /// Publish a freshly-added connected viewer, then kick the shared
    /// resolver if either the hostname or StableNodeID is still uncached.
    /// The `ViewerInfo` now lives on the `Viewer` entry and is inserted
    /// atomically with it; this is the shared notify → resolve-if-uncached
    /// tail used by `registerOrRefresh` and `approveViewer`.
    private func publishAddedViewer(addr: String) {
        let identityMissing = viewers.withLock { state in
            guard let info = state[addr]?.info else { return false }
            return info.hostname == nil || info.stableID == nil
        }
        notifyViewersChanged()
        if identityMissing {
            scheduleIdentityResolve()
        }
        // Recorded here rather than at each caller, so a third admission
        // route added later isn't silently unrecorded.
        recorder?.record(
            .viewerAdmitted,
            role: .sharer,
            fields: [
                "addr": .string(addr),
                "guest": .bool(isGuestAddr(addr)),
                "identity_pending": .bool(identityMissing)
            ])
        // Where a 10-bit share checks whether its newest viewer can decode
        // 10-bit — caps were recorded at HELLO, before promotion, so the
        // lookup is already populated.
        enforceBitDepthCapability(trigger: "viewer \(addr) joined")
    }

    /// Move a pending viewer into the active set: emit the HELLO_ACK
    /// we suppressed at HELLO time, force a keyframe, and surface them
    /// in the connected-viewer roster. Safe to call for a viewer who's
    /// already approved (no-op).
    public func approveViewer(addr: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        let pending = pendingViewers.withLock { state -> PendingViewer? in
            state.removeValue(forKey: addr)
        }
        notifyPendingViewersChanged()
        guard let pending else { return }

        let (added, viewerCount) = viewers.withLock { state -> (Bool, Int) in
            if state[addr] != nil { return (false, state.count) }
            let v = Viewer(
                addr: pending.addr,
                ssrc: UInt32.random(in: 2...UInt32.max),
                audioSSRC: pending.audioSSRC,
                nextSequence: UInt16.random(in: 0...UInt16.max),
                lastSeenNs: now,
                // Admission, not arrival: a viewer parked at the approval
                // gate for a minute has not been failing to report, so its
                // wait must not count against the first-report grace period.
                admittedAtNs: now,
                info: ViewerInfo(
                    id: pending.info.id,
                    tailscaleIP: pending.info.tailscaleIP,
                    hostname: pending.info.hostname,
                    stableID: pending.info.stableID,
                    connectedAt: Date(),
                    isGuest: pending.info.isGuest
                )
            )
            state[addr] = v
            return (true, state.count)
        }
        if added {
            publishAddedViewer(addr: addr)
        }
        logger.log("Viewer approved \(addr) (total=\(viewerCount))")
        // Send the deferred HELLO_ACK and request a keyframe. Recorded like
        // the immediate-ack branch — approval is on by default, so most
        // sessions take this path, and without it `DiagnosticsMerge`'s clock
        // alignment silently never ran for them.
        let ackCaps = viewerCaps.withLock { $0[addr] } ?? []
        recorder?.record(
            .helloAckSent,
            role: .sharer,
            fields: [
                "addr": .string(addr),
                "ssrc": DiagnosticValue(pending.audioSSRC),
                "server_caps": .string(
                    ackCaps.isEmpty ? "none (legacy ack)" : serverCaps.diagnosticDescription),
                "deferred": .bool(true)
            ])
        let ack = helloAckDatagram(for: addr, ssrc: pending.audioSSRC)
        Task { [weak self] in
            guard let pl = self?.media else { return }
            try? await pl.send(ack, to: addr)
        }
        helperCapture?.requestKeyframe()
    }

    /// Reject a pending viewer: send HELLO_DENY + SERVER_BYE so they tear
    /// down immediately (and can tell "declined" from "sharer stopped"),
    /// and drop them from the pending set. Safe to call for an unknown
    /// addr (no-op).
    public func denyViewer(addr: String) {
        let existed = pendingViewers.withLock { state -> Bool in
            state.removeValue(forKey: addr) != nil
        }
        guard existed else { return }
        notifyPendingViewersChanged()
        logger.log("Viewer denied \(addr)")
        recorder?.record(
            .viewerDenied,
            role: .sharer,
            fields: ["addr": .string(addr), "guest": .bool(isGuestAddr(addr))])
        recorder?.record(.helloDeniedSent, role: .sharer, fields: ["addr": .string(addr)])
        sendDenialDatagrams(to: addr)
        if isGuestAddr(addr) {
            onGuestViewerDenied?(Self.ipFromAddr(addr))
        }
    }

    /// Sharer-initiated one-time disconnect of a connected viewer — the
    /// per-row ✕ in the SharingCard's viewer list. Same symmetric teardown
    /// as the blocked-peer expel, but nothing is remembered: the peer's
    /// next HELLO goes back through the normal admission gate (approval
    /// prompt, or straight in with the gate off). Safe to call for an
    /// unknown addr (no-op).
    public func disconnectViewer(addr: String) {
        expelViewer(addr: addr, reason: "disconnected by sharer")
    }

    /// Attach a guest (share-by-token) listener to an already-running share
    /// — same effect as passing `guestPacketListener` to `start()`. Returns
    /// false (caller keeps ownership) when not running or already attached.
    public func attachGuestPacketListener(_ pl: PacketListener) -> Bool {
        let attached = lifecycle.withLock { lc -> Bool in
            guard lc.isRunning, lc.guestPacketListener == nil else { return false }
            lc.guestPacketListener = pl
            return true
        }
        guard attached else { return false }
        logger.log("Guest UDP stream attached (share-by-token)")
        Task { [weak self] in await self?.receiveControlLoop(pl: pl, isGuest: true) }
        return true
    }

    /// Adopt the guest tunnel's framed TCP control channel (annotations +
    /// remote control for guests). Installs the share's handlers and routes
    /// outbound control traffic through it. Returns false (caller keeps
    /// ownership) when not running or already attached — else a channel
    /// behind a raced stop would leak with nothing to stop it.
    public func attachGuestControlListener(_ listener: TailscreenControlListener) -> Bool {
        let attached = lifecycle.withLock { lc -> Bool in
            guard lc.isRunning, lc.guestControlListener == nil else { return false }
            lc.guestControlListener = listener
            return true
        }
        guard attached else { return false }
        installControlHandlers(on: listener)
        logger.log("Guest TCP control channel attached (share-by-token)")
        return true
    }

    /// Detach and close the guest listener — the toggle flipping off, or a
    /// New Link rotation. Every guest is disconnected first so each gets
    /// HELLO_DENY + SERVER_BYE *through the guest socket* before it closes;
    /// the token dies with the host's guest node afterward. No-op when
    /// unattached.
    public func detachGuestPacketListener() async {
        let guestPending = pendingViewers.withLock { Array($0.keys) }.filter { isGuestAddr($0) }
        let guestConnected = viewers.withLock { Array($0.keys) }.filter { isGuestAddr($0) }
        for addr in guestPending { denyViewer(addr: addr) }
        for addr in guestConnected { expelViewer(addr: addr, reason: "link sharing turned off") }
        // The denial datagrams above ride fire-and-forget tasks through the
        // `media` snapshot; give them a beat to reach the socket before it
        // goes away. Best-effort by nature — UDP semantics apply anyway.
        if !(guestPending.isEmpty && guestConnected.isEmpty) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        typealias GuestPair = (PacketListener?, TailscreenControlListener?)
        let (listenerToClose, controlToStop) = lifecycle.withLock { lc -> GuestPair in
            let pair = (lc.guestPacketListener, lc.guestControlListener)
            lc.guestPacketListener = nil
            lc.guestControlListener = nil
            return pair
        }
        // Stop the guest control channel AFTER the expels above: the expel
        // path severs each guest's annotation connection by IP through the
        // still-registered channel, which is what fires onConnectionClosed
        // and retires their strokes. stop() then closes any stragglers.
        await controlToStop?.stop()
        await listenerToClose?.close()
        guestAddrs.withLock { $0.removeAll() }
        if listenerToClose != nil {
            logger.log("Guest UDP stream detached (share-by-token)")
        }
    }

    /// Kick an already-connected viewer: a blocked peer pulled back out
    /// (open-door admits before async StableNodeID resolution completes), or
    /// the sharer's one-time `disconnectViewer`. No-op for unknown addrs.
    private func expelViewer(addr: String, reason: String) {
        // Open the kicked-viewer quiet window BEFORE removing the addr so
        // a KEEPALIVE racing this teardown can't re-register it in the
        // gap between the roster removal and the window opening.
        let now = DispatchTime.now().uptimeNanoseconds
        expelledAddrs.withLock { $0[addr] = now }
        let removed = viewers.withLock { state -> Bool in
            state.removeValue(forKey: addr) != nil
        }
        guard removed else {
            // Unknown addr: no expel happened, so don't leave a quiet
            // window that would eat this peer's next keepalives.
            expelledAddrs.withLock { _ = $0.removeValue(forKey: addr) }
            return
        }
        // Symmetric teardown: drop the send chain and sever the TCP
        // annotation channel by IP, so a blocked peer loses both video and
        // annotation access; closing fires onConnectionClosed which retires
        // its tracked strokes.
        videoSendTails.withLock { _ = $0.removeValue(forKey: addr) }
        audioSendTails.withLock { _ = $0.removeValue(forKey: addr) }
        viewerCaps.withLock { _ = $0.removeValue(forKey: addr) }
        retransmitBuffer.removeViewer(addr: addr)
        fecGatedAddrs.withLock { _ = $0.remove(addr) }
        closeAnnotationChannels(forIP: Self.ipFromAddr(addr))
        revokeControlIfHeld(byIP: Self.ipFromAddr(addr), reason: reason)
        notifyViewersChanged()
        logger.log("Viewer expelled (\(reason)) \(addr)")
        recorder?.record(
            .viewerExpelled,
            role: .sharer,
            fields: [
                "addr": .string(addr),
                "reason": .string(reason),
                "guest": .bool(isGuestAddr(addr))
            ])
        sendDenialDatagrams(to: addr)
        // A policy-driven expel is a standing rejection: close the guest
        // tunnel too. A one-time disconnect is not — the guest may knock
        // again through the approval gate.
        if reason == "remembered deny", isGuestAddr(addr) {
            onGuestViewerDenied?(Self.ipFromAddr(addr))
        }
    }

    /// Close every TCP annotation connection whose peer dialed from `ip`.
    /// The listener's close path fires `onConnectionClosed`, which clears the
    /// per-connection tracking maps and emits the `.undo`s that make the
    /// peer's strokes vanish from every overlay.
    private func closeAnnotationChannels(forIP ip: String) {
        let connectionIDs = annotationConnectionIP.withLock { state in
            state.filter { $0.value == ip }.map { $0.key }
        }
        let channels = controlChannels
        guard !connectionIDs.isEmpty, !channels.isEmpty else { return }
        Task {
            for channel in channels {
                for id in connectionIDs { await channel.close(connectionID: id) }
            }
        }
    }

    /// One HELLO_DENY (so the viewer can show "the sharer declined your
    /// request" instead of the generic peer-closed teardown; old viewers
    /// ignore the unknown control byte) followed by three redundant
    /// SERVER_BYE datagrams to mitigate single-packet UDP loss — same
    /// template as `stop()`'s teardown path.
    private func sendDenialDatagrams(to addr: String) {
        let denied = ScreenShareControlMessage.encode(.helloDenied)
        let bye = ScreenShareControlMessage.encode(.serverBye)
        Task { [weak self] in
            guard let pl = self?.media else { return }
            try? await pl.send(denied, to: addr)
            for _ in 0..<3 {
                try? await pl.send(bye, to: addr)
            }
        }
    }

    private func removePendingViewer(addr: String) {
        let removed = pendingViewers.withLock { state -> Bool in
            state.removeValue(forKey: addr) != nil
        }
        if removed {
            notifyPendingViewersChanged()
            logger.log("Pending viewer disconnected \(addr)")
        }
    }

    private func removeViewer(addr: String) {
        let removedInfo = viewers.withLock { state -> ViewerInfo? in
            state.removeValue(forKey: addr)?.info
        }
        if let removedInfo {
            // The viewer said BYE — the orderly ending. The idle sweep records
            // the other one (`reason=idle_timeout`); together with
            // `viewer.expelled` every way out of the admitted set is named.
            recorder?.record(
                .viewerDisconnected,
                role: .sharer,
                fields: [
                    "addr": .string(addr),
                    "guest": .bool(isGuestAddr(addr)),
                    "reason": .string("bye"),
                    "connected_ms": DiagnosticValue(
                        max(0, Int(Date().timeIntervalSince(removedInfo.connectedAt) * 1000)))
                ])
            // Prune the departed viewer's audio send chain (video chains
            // self-prune on the next broadcast's rebuild).
            audioSendTails.withLock { _ = $0.removeValue(forKey: addr) }
            viewerCaps.withLock { _ = $0.removeValue(forKey: addr) }
            retransmitBuffer.removeViewer(addr: addr)
            fecGatedAddrs.withLock { _ = $0.remove(addr) }
            notifyViewersChanged()
            // A viewer that BYE'd/left surrenders any control grant. The TCP
            // close usually beats this via `revokeControlIfHeld(byConnection:)`;
            // this covers a UDP BYE that outruns the TCP FIN.
            revokeControlIfHeld(byIP: Self.ipFromAddr(addr), reason: "viewer disconnected")
            logger.log("Viewer disconnected \(addr)")
        }
    }

    /// Snapshot the current roster (sorted by connection time so the UI
    /// list is stable) and hand it to `onViewersChanged`. Cheap enough to
    /// call on every join/leave — the lock window is tiny and the roster
    /// is at most a handful of entries.
    private func notifyViewersChanged() {
        guard let cb = onViewersChanged else { return }
        let snapshot = viewers.withLock { state -> [ViewerInfo] in
            state.values.map(\.info).sorted { $0.connectedAt < $1.connectedAt }
        }
        cb(snapshot)
    }

    /// Mirror of `notifyViewersChanged` for the pending-approval set.
    private func notifyPendingViewersChanged() {
        guard let cb = onPendingViewersChanged else { return }
        let snapshot = pendingViewers.withLock { state -> [PendingViewerInfo] in
            state.values.map(\.info).sorted { $0.arrivedAt < $1.arrivedAt }
        }
        cb(snapshot)
    }

    /// Reduce a peer address to the bare IP the admission gates compare on.
    ///
    /// Two producers disagree about format: a viewer's UDP source is
    /// `ip:port`, while the TCP control channel's `tailscale_getremoteaddr`
    /// strips the port but **keeps IPv6 brackets** — `[fd7a::1]:33509` vs.
    /// `[fd7a::1]`. Both must reduce identically or `isAdmittedViewerIP`'s
    /// `==` drops an admitted viewer's control requests as "non-admitted".
    ///
    /// Brackets are matched FIRST; splitting on the last colon instead (the
    /// old bug) eats the final hextet of a portless IPv6 literal. IPv4
    /// survived that bug; only IPv6-only addressing (the guest tunnel) hit it.
    public static func ipFromAddr(_ addr: String) -> String {
        // Bracketed IPv6, with or without a `:port`. The colons before `]`
        // belong to the address, so stop there rather than scanning for a port.
        if addr.hasPrefix("["), let close = addr.firstIndex(of: "]") {
            return String(addr[addr.index(after: addr.startIndex)..<close])
        }
        // IPv4 or a bare host: one colon is a port separator. Several mean an
        // unbracketed IPv6 literal, which carries no port to strip — and
        // chopping at its last colon is exactly the bug above.
        guard let lastColon = addr.lastIndex(of: ":"),
            addr.firstIndex(of: ":") == lastColon
        else { return addr }
        return String(addr[..<lastColon])
    }

    // MARK: - Identity resolution

    /// How many times the shared resolver re-queries LocalAPI, one second
    /// apart. A freshly-joined peer can HELLO before its netmap entry lands;
    /// a couple retries turn a permanent IP-only row into a short delay.
    private static let peerResolveAttempts = 5

    /// Coordinates the single shared identity resolver: every park/join with
    /// an uncached identity coalesces onto ONE in-flight loop resolving all
    /// outstanding addrs from a single `backendStatus` snapshot per tick,
    /// instead of N fetches × 5 retries. `requested` bumps on every schedule
    /// call so a park landing mid-pass isn't missed.
    private let resolveGeneration =
        Guarded<(running: Bool, requested: UInt64)>((false, 0))

    private func cachePeer(ip: String, hostname: String?, stableID: String?) {
        if let hostname, !hostname.isEmpty {
            peerNameCache.withLock { $0[ip] = hostname }
        }
        if let stableID, !stableID.isEmpty {
            peerStableIDCache.withLock { $0[ip] = stableID }
        }
    }

    /// Kick the shared identity resolver. Bumps the generation so a park that
    /// lands mid-pass is picked up; starts the runner only if one isn't
    /// already draining.
    private func scheduleIdentityResolve() {
        let shouldStart = resolveGeneration.withLock { state -> Bool in
            state.requested &+= 1
            if state.running { return false }
            state.running = true
            return true
        }
        guard shouldStart else { return }
        Task { [weak self] in await self?.runResolverUntilQuiescent() }
    }

    /// Run resolve passes until no new schedule request arrived during a
    /// pass. An unresolvable peer can't spin the runner — only fresh
    /// `scheduleIdentityResolve` calls advance the generation.
    private func runResolverUntilQuiescent() async {
        while true {
            let startGen = resolveGeneration.withLock { $0.requested }
            await resolveIdentitiesLoop()
            let done = resolveGeneration.withLock { state -> Bool in
                if state.requested == startGen {
                    state.running = false
                    return true
                }
                return false
            }
            if done { return }
        }
    }

    /// One shared resolve loop. Each tick, snapshot every addr missing a
    /// hostname/StableNodeID, fetch ONE `backendStatus`, apply to all — a
    /// burst of joins costs one LocalAPI call, not one per viewer.
    private func resolveIdentitiesLoop() async {
        for attempt in 0..<Self.peerResolveAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            let outstanding = outstandingResolveTargets()
            guard !outstanding.isEmpty else { return }
            let byIP = await backendStatusByIP()
            var anyMissing = false
            for (addr, ip) in outstanding {
                guard let identity = byIP[ip] else {
                    anyMissing = true
                    continue
                }
                cachePeer(ip: ip, hostname: identity.hostname, stableID: identity.stableID)
                applyResolvedIdentity(
                    addr: addr, hostname: identity.hostname, stableID: identity.stableID)
            }
            if !anyMissing { return }
        }
    }

    /// Addrs (pending + connected) still awaiting a hostname or StableNodeID.
    /// An addr is never in both sets at once, so a plain merge is safe.
    private func outstandingResolveTargets() -> [String: String] {
        // Guests are excluded — their tunnel addrs are in no netmap, so
        // including them just spins the resolver's full retry budget.
        let pending = pendingViewers.withLock { state -> [String: String] in
            var m: [String: String] = [:]
            for (addr, viewer) in state
            where
                !viewer.info.isGuest
                && (viewer.info.hostname == nil || viewer.info.stableID == nil)
            {
                m[addr] = viewer.info.tailscaleIP
            }
            return m
        }
        let connected = viewers.withLock { state -> [String: String] in
            var m: [String: String] = [:]
            for (addr, viewer) in state
            where
                !viewer.info.isGuest
                && (viewer.info.hostname == nil || viewer.info.stableID == nil)
            {
                m[addr] = viewer.info.tailscaleIP
            }
            return m
        }
        var out = pending
        out.merge(connected) { _, new in new }
        return out
    }

    /// One LocalAPI netmap fetch → IP → (hostname, StableNodeID). `PeerStatus.ID`
    /// is the string StableNodeID, distinct from the netmap's numeric ID (see
    /// `TailscalePeerDiscovery.mergeKey`). Empty map on failure or a genuinely
    /// peerless netmap — the caller treats both as "retry".
    private func backendStatusByIP() async -> [String: (hostname: String?, stableID: String)] {
        guard let node = self.node else { return [:] }
        let client = LocalAPIClient(localNode: node, logger: logger)
        guard let status = try? await client.backendStatus() else { return [:] }
        var byIP: [String: (hostname: String?, stableID: String)] = [:]
        for (_, peer) in status.Peer ?? [:] {
            guard let ips = peer.TailscaleIPs else { continue }
            let identity = (hostname: peer.HostName, stableID: String(peer.ID))
            for ip in ips { byIP[ip] = identity }
        }
        return byIP
    }

    /// Patch a resolved (hostname, StableNodeID) into whichever collection
    /// holds `addr`, notify the UI, and apply the remembered policy: a
    /// parked viewer runs the admission gate; a connected viewer that turns
    /// out remembered-deny is expelled (open-door admits before resolution).
    private func applyResolvedIdentity(addr: String, hostname: String?, stableID: String?) {
        let hostnameUsable = hostname.map { !$0.isEmpty } ?? false

        let pendingPresent = pendingViewers.withLock { state -> (present: Bool, changed: Bool) in
            guard var viewer = state[addr] else { return (false, false) }
            var changed = false
            if let hostname, hostnameUsable, viewer.info.hostname != hostname {
                viewer.info.hostname = hostname
                changed = true
            }
            if let stableID, viewer.info.stableID != stableID {
                viewer.info.stableID = stableID
                changed = true
            }
            state[addr] = viewer
            return (true, changed)
        }
        if pendingPresent.present {
            if pendingPresent.changed { notifyPendingViewersChanged() }
            if let stableID { applyRememberedPolicyToPending(addr: addr, stableID: stableID) }
            return
        }

        let connectedPresent = viewers.withLock { state -> (present: Bool, changed: Bool) in
            guard var viewer = state[addr] else { return (false, false) }
            var changed = false
            if let hostname, hostnameUsable, viewer.info.hostname != hostname {
                viewer.info.hostname = hostname
                changed = true
            }
            if let stableID, viewer.info.stableID != stableID {
                viewer.info.stableID = stableID
                changed = true
            }
            state[addr] = viewer
            return (true, changed)
        }
        guard connectedPresent.present else { return }
        if connectedPresent.changed { notifyViewersChanged() }
        let policy = stableID.flatMap { id in accessPolicies.withLock { $0[id] } }
        if policy == .deny { expelViewer(addr: addr, reason: "remembered deny") }
    }

    // MARK: - Sweeps (idle viewers, watchdog, adaptive bitrate, FEC arm)

    /// Periodically prunes viewers that haven't said anything in a while —
    /// UDP gives us no FIN/RST for "the other side crashed without BYE".
    private func sweepIdleViewers() async {
        while isRunning {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            typealias IdleDrop = (addr: String, idleNs: UInt64, connectedAt: Date)
            let dropped = viewers.withLock { state -> [IdleDrop] in
                let stale = Self.staleAddrs(
                    lastSeenNs: state.mapValues { $0.lastSeenNs },
                    nowNs: now, timeoutNs: self.viewerIdleTimeoutNs)
                let result = stale.map {
                    (
                        addr: $0, idleNs: now &- (state[$0]?.lastSeenNs ?? now),
                        connectedAt: state[$0]?.info.connectedAt ?? Date()
                    )
                }
                for addr in stale { state.removeValue(forKey: addr) }
                return result
            }
            if !dropped.isEmpty {
                audioSendTails.withLock { state in
                    for entry in dropped { state.removeValue(forKey: entry.addr) }
                }
                viewerCaps.withLock { state in
                    for entry in dropped { state.removeValue(forKey: entry.addr) }
                }
                for entry in dropped { retransmitBuffer.removeViewer(addr: entry.addr) }
                fecGatedAddrs.withLock { gated in
                    for entry in dropped { gated.remove(entry.addr) }
                }
                notifyViewersChanged()
            }
            for entry in dropped {
                let idleMs = Int(entry.idleNs / 1_000_000)
                // An idled-out viewer surrenders any control grant.
                revokeControlIfHeld(byIP: Self.ipFromAddr(entry.addr), reason: "viewer idle timeout")
                logger.log("Viewer timeout \(entry.addr) (idle \(idleMs) ms)")
                // Warning, not info: unlike a BYE, nobody chose this.
                recorder?.record(
                    .viewerDisconnected,
                    role: .sharer,
                    severity: .warning,
                    fields: [
                        "addr": .string(entry.addr),
                        "guest": .bool(isGuestAddr(entry.addr)),
                        "reason": .string("idle_timeout"),
                        "idle_ms": DiagnosticValue(idleMs),
                        "connected_ms": DiagnosticValue(
                            max(0, Int(Date().timeIntervalSince(entry.connectedAt) * 1000)))
                    ])
            }

            // Same sweep for pending viewers, with a longer grace period:
            // a sharer who's away from their desk shouldn't come back to
            // a wall of stale Accept/Deny prompts. We don't send
            // SERVER_BYE here — the pending viewer is still sending
            // KEEPALIVEs, and if they truly drop the next pending sweep
            // will catch them; the noisy ones we trust the sharer to
            // Deny explicitly.
            let droppedPending = pendingViewers.withLock { state -> [String] in
                let stale = Self.staleAddrs(
                    lastSeenNs: state.mapValues { $0.lastSeenNs },
                    nowNs: now, timeoutNs: self.pendingApprovalTimeoutNs)
                for addr in stale { state.removeValue(forKey: addr) }
                return stale
            }
            if !droppedPending.isEmpty {
                notifyPendingViewersChanged()
                for addr in droppedPending {
                    logger.log("Pending viewer timeout \(addr)")
                }
            }

            // Hung-helper watchdog. A helper that's alive but no longer
            // producing (SCStream wedged without firing didStopWithError)
            // leaves `isRunning` true while viewers freeze, and process-death
            // detection never fires. The helper heartbeats ~1 Hz off any
            // delivered SCStream sample, so a gap past the timeout means
            // capture is genuinely stuck — restart it. `lastHelperActivityNs
            // == 0` means no helper yet; skip.
            if helperWatchdogEnabled, helperCapture != nil {
                let last = lastHelperActivityNs.withLock { $0 }
                if Self.helperLooksHung(lastActivityNs: last, nowNs: now, timeoutNs: helperLivenessTimeoutNs) {
                    logger.log(
                        "Helper liveness watchdog: no output for \((now &- last) / 1_000_000) ms — restarting capture")
                    // Re-seed so we don't re-fire every second before the
                    // restart settles (the fresh helper re-seeds it too).
                    lastHelperActivityNs.withLock { $0 = now }
                    Task { [weak self] in try? await self?.restartCapture() }
                }
            }

            // ~1 Hz RTT ping to RR-capable viewers, piggybacked on this sweep.
            // Each carries the server's monotonic uptime; the viewer echoes it
            // in its next receiver report so the sharer can measure RTT.
            let pingAddrs = viewerCaps.withLock { caps in
                caps.compactMap { $0.value.contains(.receiverReport) ? $0.key : nil }
            }
            let liveAddrs = viewers.withLock { Set($0.keys) }
            let pingTargets = pingAddrs.filter { liveAddrs.contains($0) }
            if let pl = media, !pingTargets.isEmpty {
                let ping = ScreenShareControlMessage.encodePing(serverUptimeNs: now)
                Task {
                    for addr in pingTargets { try? await pl.send(ping, to: addr) }
                }
            }
        }
    }

    /// Adaptive-bitrate control loop. Polls every 5s; counts PLIs per viewer,
    /// takes the worst (encode once, fan out), and cuts 25% on loss or
    /// recovers 10% on a clean window. Hysteresis: 5s before a cut, 10s
    /// before recovery. Floor is 30% of baseline.
    private func adaptiveBitrateSweep() async {
        let windowNs: UInt64 = 5_000_000_000
        let downHysteresisNs: UInt64 = 5_000_000_000
        let upHysteresisNs: UInt64 = 10_000_000_000
        let lossThreshold = 2  // PLIs per window before we cut
        lastTransportSummaryNs.withLock { $0 = 0 }

        while isRunning {
            try? await Task.sleep(nanoseconds: windowNs)
            guard isRunning, helperCapture != nil else { continue }

            let baseline = baselineBitrate.withLock { $0 }
            let current = currentBitrate.withLock { $0 }
            let lastChange = lastBitrateChangeNs.withLock { $0 }
            guard baseline > 0 else { continue }
            let now = DispatchTime.now().uptimeNanoseconds

            // Prune each viewer's PLI ring to this window and snapshot the
            // per-viewer PLI count, its (freshness-decayed) RR loss, and who's
            // currently in keyframe-only mode.
            let cutoff = now &- windowNs
            let capsByAddr = viewerCaps.withLock { $0 }
            let (pliCounts, lossQ8ByAddr, currentlyThrottled, feedbackStaleAddrs) =
                viewers.withLock { state -> ([String: Int], [String: Int], Set<String>, Set<String>) in
                    var counts: [String: Int] = [:]
                    var lossQ8: [String: Int] = [:]
                    var throttled = Set<String>()
                    var stale = Set<String>()
                    for key in Array(state.keys) {
                        guard var viewer = state[key] else { continue }
                        viewer.pliTimestampsNs.removeAll { $0 < cutoff }
                        state[key] = viewer
                        counts[key] = viewer.pliTimestampsNs.count
                        // Decay stale RR loss to 0 so a viewer that reported
                        // high loss then went silent can't pin the input up.
                        let fresh = viewer.lastRRAtNs != 0 && now &- viewer.lastRRAtNs < windowNs
                        lossQ8[key] = fresh ? viewer.lossFractionQ8 : 0
                        // Separately record that the decay happened, so it
                        // isn't mistaken for a clean report.
                        let hasReported = viewer.lastRRAtNs != 0
                        let since = now &- (hasReported ? viewer.lastRRAtNs : viewer.admittedAtNs)
                        if Self.feedbackIsStale(
                            expectsReports: capsByAddr[key]?.contains(.receiverReport) ?? false,
                            hasReported: hasReported, sinceNs: since, windowNs: windowNs)
                        {
                            stale.insert(key)
                        }
                        if now < viewer.throttledUntilNs { throttled.insert(key) }
                    }
                    return (counts, lossQ8, throttled, stale)
                }

            // Throttle an isolated bad viewer (keyframe-only) instead of
            // cutting the global rate; feed only the worst non-throttled
            // PLI/RR-loss to the global decision.
            let gci = Self.congestionInputs(
                pliCounts: pliCounts,
                lossQ8ByAddr: lossQ8ByAddr,
                currentlyThrottled: currentlyThrottled,
                lossThreshold: lossThreshold,
                feedbackStaleAddrs: feedbackStaleAddrs)
            let throttleSet = Set(gci.throttle)
            let throttleDeadline = now &+ (2 &* windowNs)  // ~10 s; renewed while isolated

            // Apply/renew throttle windows and derive each viewer's health.
            let healthByAddr = viewers.withLock { state -> [String: ViewerHealth] in
                var health: [String: ViewerHealth] = [:]
                for key in Array(state.keys) {
                    guard var viewer = state[key] else { continue }
                    if throttleSet.contains(key) {
                        viewer.throttledUntilNs = throttleDeadline
                        state[key] = viewer
                    }
                    let plis = pliCounts[key] ?? 0
                    if now < viewer.throttledUntilNs {
                        health[key] = .throttled
                    } else if plis > lossThreshold {
                        health[key] = .degraded
                    } else {
                        health[key] = .good
                    }
                }
                return health
            }
            publishViewerHealth(healthByAddr)
            logViewerStats(
                pliCounts: pliCounts, healthByAddr: healthByAddr,
                feedbackStaleAddrs: feedbackStaleAddrs)
            // Before the drains below: counters are read here as this
            // window's totals, then zeroed.
            recordTransportSummaries(
                now: now, windowNs: windowNs, pliCounts: pliCounts, healthByAddr: healthByAddr)
            recordAnnotationSummary(windowNs: windowNs)

            // Drain the per-window NACK-served counters (loss/PLI inputs already
            // computed by `congestionInputs`, excluding throttled viewers).
            let nackServed = viewers.withLock { state -> Int in
                var nacks = 0
                for key in Array(state.keys) {
                    guard var viewer = state[key] else { continue }
                    nacks += viewer.nackServedThisWindow
                    viewer.nackServedThisWindow = 0
                    // The summary above already read these as this window's
                    // totals.
                    viewer.audioPacketsThisWindow = 0
                    viewer.audioRejectedThisWindow = 0
                    state[key] = viewer
                }
                return nacks
            }

            let elapsedSinceChange = now &- lastChange
            let fpsTier = currentFpsTier.withLock { $0 }
            let sessionFpsCap = sessionQuality.withLock { $0 }.fpsCap
            let decision = Self.nextCongestionDecision(
                CongestionInputs(
                    lossFractionQ8: gci.lossQ8Input,
                    pliCount: gci.pliInput,
                    nackServed: nackServed,
                    current: current,
                    baseline: baseline,
                    fpsTier: fpsTier,
                    fpsCap: sessionFpsCap,
                    elapsedSinceChangeNs: elapsedSinceChange,
                    feedbackStale: gci.feedbackStale),
                lossThreshold: lossThreshold,
                downHysteresisNs: downHysteresisNs,
                upHysteresisNs: upHysteresisNs)
            if let nextBitrate = decision.bitrate {
                var reason = "clean window"
                if nextBitrate < current {
                    reason = "loss \(gci.pliInput)plis/\(gci.lossQ8Input)frac/\(nackServed)nack"
                }
                applyAdaptiveBitrate(nextBitrate, reason: reason)
            }
            if let nextFps = decision.fpsTier {
                applyFpsTier(nextFps)
            }

            sweepFECArm(now: now, windowNs: windowNs)
        }
    }

    /// The FEC arm of the sweep: snapshot per-viewer samples (draining
    /// per-window counters), run `fecSweepDecision`, and apply the resulting
    /// state + parity gate.
    private func sweepFECArm(now: UInt64, windowNs: UInt64) {
        let capsByAddr = viewerCaps.withLock { $0 }
        let samples = viewers.withLock { state -> [String: FECViewerSample] in
            var out: [String: FECViewerSample] = [:]
            for key in Array(state.keys) {
                guard var viewer = state[key] else { continue }
                let recovered = viewer.fecRecoveredThisWindow
                let nackRecovered = viewer.nackRecoveredThisWindow
                let expected = viewer.packetsSentThisWindow
                viewer.fecRecoveredThisWindow = 0
                viewer.nackRecoveredThisWindow = 0
                viewer.packetsSentThisWindow = 0
                state[key] = viewer
                let fresh = viewer.lastRRAtNs != 0 && now &- viewer.lastRRAtNs < windowNs
                out[key] = FECViewerSample(
                    rttNs: viewer.rttNs,
                    residualLossQ8: fresh ? viewer.lossFractionQ8 : 0,
                    recovered: recovered,
                    nackRecovered: nackRecovered,
                    expectedPackets: expected,
                    fecCapable: capsByAddr[key]?.contains(.fec) ?? false)
            }
            return out
        }
        let prior = fecState.withLock { $0 }
        let decision = Self.fecSweepDecision(samples: samples, state: prior)
        if debugFEC {
            let rows =
                samples
                .map { addr, s in
                    let rec = Self.fecRecoveredQ8(
                        recovered: s.recovered + s.nackRecovered, expectedPackets: s.expectedPackets)
                    return
                        "\(addr) rtt=\(s.rttNs / 1_000_000)ms residLossQ8=\(s.residualLossQ8) "
                        + "rawLossQ8=\(min(255, s.residualLossQ8 + rec)) "
                        + "fecRec=\(s.recovered) nackRec=\(s.nackRecovered)/\(s.expectedPackets) fec=\(s.fecCapable)"
                }
                .joined(separator: " | ")
            logger.log(
                "FEC sweep: [\(rows.isEmpty ? "no viewers" : rows)] → groupSize=\(decision.state.groupSize) gated=\(decision.gated.count)"
            )
        }
        applyFECState(decision)
    }

    /// Apply an fps-ladder step: retune capture frame interval, force a
    /// keyframe, reset the hysteresis clock. No-op if unchanged.
    private func applyFpsTier(_ fps: Int) {
        let previous = currentFpsTier.withLock { existing -> Int? in
            guard existing != fps else { return nil }
            let prior = existing
            existing = fps
            return prior
        }
        guard let previous else { return }
        lastBitrateChangeNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        helperCapture?.setFrameInterval(fps)
        helperCapture?.requestKeyframe()
        logger.log("Adaptive fps: → \(fps) fps")
        recorder?.record(
            .encodeFrameIntervalChanged,
            role: .sharer,
            severity: fps < previous ? .warning : .info,
            fields: ["from_fps": DiagnosticValue(previous), "to_fps": DiagnosticValue(fps)])
    }

    /// Update each connected viewer's public `info.health` projection and
    /// republish if anything changed. Value-type write only — keeps the
    /// Sendable `ViewerInfo` seam intact.
    private func publishViewerHealth(_ healthByAddr: [String: ViewerHealth]) {
        let changed = viewers.withLock { state -> Bool in
            var didChange = false
            for (addr, health) in healthByAddr {
                guard var viewer = state[addr] else { continue }
                if viewer.info.health != health {
                    viewer.info.health = health
                    state[addr] = viewer
                    didChange = true
                }
            }
            return didChange
        }
        if changed { notifyViewersChanged() }
    }

    /// Emit one stats log line per viewer with nonzero activity this window
    /// (PLIs, dropped frames, throttle, or stale feedback). Drop counts are
    /// cumulative per send chain.
    ///
    /// `rrStale` is in the guard too: a viewer whose reports stopped has
    /// nothing else nonzero to report, so without it the sharer-gone-deaf
    /// case left no log trace at all.
    private func logViewerStats(
        pliCounts: [String: Int], healthByAddr: [String: ViewerHealth],
        feedbackStaleAddrs: Set<String>
    ) {
        let videoDrops = videoSendTails.withLock { $0.mapValues { $0.droppedFrames } }
        let audioDrops = audioSendTails.withLock { $0.mapValues { $0.droppedFrames } }
        for (addr, plis) in pliCounts {
            let vDrops = videoDrops[addr] ?? 0
            let aDrops = audioDrops[addr] ?? 0
            let thr = healthByAddr[addr] == .throttled
            let rrStale = feedbackStaleAddrs.contains(addr)
            guard plis > 0 || vDrops > 0 || aDrops > 0 || thr || rrStale else { continue }
            logger.log(
                "Viewer stats \(addr) plis/5s=\(plis) vDrops=\(vDrops) aDrops=\(aDrops) "
                    + "throttled=\(thr) rrStale=\(rrStale)")
        }
    }

    /// One `transport.summary` per connected viewer per sweep window,
    /// unconditionally — the log line above stays quiet on a clean window,
    /// which is exactly what made a share with dead receiver reports look
    /// identical to a healthy one in a bundle. No viewers → no record.
    ///
    /// Field set is the pure `transportSummaryFields`, pinned by
    /// `SharerTransportSummaryTests`; this only snapshots the inputs.
    private func recordTransportSummaries(
        now: UInt64, windowNs: UInt64, pliCounts: [String: Int], healthByAddr: [String: ViewerHealth]
    ) {
        guard let recorder else { return }
        // Measured, not nominal — the sweep sleeps then works, so counters
        // span the window plus that work. First row reports the nominal window.
        let elapsedNs = lastTransportSummaryNs.withLock { last -> UInt64 in
            let elapsed = last == 0 || now < last ? windowNs : now - last
            last = now
            return elapsed
        }
        let videoDrops = videoSendTails.withLock { $0.mapValues { $0.droppedFrames } }
        let audioDrops = audioSendTails.withLock { $0.mapValues { $0.droppedFrames } }
        let gated = fecGatedAddrs.withLock { $0 }
        let share = ShareTransportState(
            bitrateBps: currentBitrate.withLock { $0 },
            baselineBps: baselineBitrate.withLock { $0 },
            fpsTier: currentFpsTier.withLock { $0 },
            fecGroupSize: fecEncoderGroupSize())
        let samples = viewers.withLock { state -> [(addr: String, sample: ViewerTransportSample)] in
            state.map { addr, viewer in
                (
                    addr: addr,
                    sample: ViewerTransportSample(
                        pliCount: pliCounts[addr] ?? 0,
                        lossFractionQ8: viewer.lossFractionQ8,
                        rttNs: viewer.rttNs,
                        lastRRAtNs: viewer.lastRRAtNs,
                        nackServed: viewer.nackServedThisWindow,
                        fecRecovered: viewer.fecRecoveredThisWindow,
                        nackRecovered: viewer.nackRecoveredThisWindow,
                        packetsSent: viewer.packetsSentThisWindow,
                        audioPacketsReceived: viewer.audioPacketsThisWindow,
                        audioPacketsRejected: viewer.audioRejectedThisWindow,
                        droppedVideoFrames: videoDrops[addr] ?? 0,
                        droppedAudioFrames: audioDrops[addr] ?? 0,
                        health: healthByAddr[addr] ?? .good,
                        fecGated: gated.contains(addr))
                )
            }
        }
        // Sorted so a multi-viewer share records its rows in a stable order
        // — the timeline is read top to bottom, and two viewers swapping
        // places every window would look like something happened.
        for entry in samples.sorted(by: { $0.addr < $1.addr }) {
            recorder.record(
                .transportSummary,
                role: .sharer,
                fields: Self.transportSummaryFields(
                    addr: entry.addr, sample: entry.sample, share: share,
                    window: SummaryWindow(nowNs: now, nominalNs: windowNs, elapsedNs: elapsedNs)))
        }
    }

    /// Uptime-ns of the previous `transport.summary` pass; 0 before the first
    /// of each share (the sweep clears it on entry, so a server reused for a
    /// second share does not measure its first window from the last share's
    /// final row). Written only by the sweep; `Guarded` so the sanitiser can
    /// see it like every other cross-task field on this class.
    private let lastTransportSummaryNs = Guarded<UInt64>(0)

    /// Viewer annotations seen on the framed control channel since the last
    /// `annotation.summary`. Written from the listener's handler threads,
    /// drained by the sweep.
    private let annotationCounters = Guarded<AnnotationCounters>(AnnotationCounters())

    /// One `annotation.summary` per window with activity, none otherwise —
    /// the opposite rule from `transport.summary`, deliberately: annotations
    /// are discrete acts (silence means nobody drew, an answer rather than a
    /// gap), so a row per empty window would just crowd the recorder's ring.
    ///
    /// Counted here, not per viewer, because the gate that drops an op does
    /// so before the peer resolves to a roster entry.
    private func recordAnnotationSummary(windowNs: UInt64) {
        guard let recorder else { return }
        let counters = annotationCounters.withLock { state -> AnnotationCounters in
            let snapshot = state
            state = AnnotationCounters()
            return snapshot
        }
        guard !counters.isEmpty else { return }
        recorder.record(
            .annotationSummary,
            role: .sharer,
            fields: Self.annotationSummaryFields(counters: counters, windowNs: windowNs))
    }

    /// Push a new bitrate to the live encoder and update the bookkeeping
    /// the sweep reads on the next tick. Forces a keyframe on a down-step
    /// so viewers don't have to wait for the next periodic IDR to recover
    /// at the new rate.
    private func applyAdaptiveBitrate(_ bitrate: Int, reason: String) {
        let prev = currentBitrate.withLock { existing -> Int in
            let p = existing
            existing = bitrate
            return p
        }
        lastBitrateChangeNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        // Bookkeeping stays at the unscaled rate; the encoder gets N/(N+1)
        // of it while parity flows, so media+parity ride at that rate. The
        // applier owns the scaling — pure decisions never see it.
        helperCapture?.setBitrate(Self.fecCompensatedBitrate(bitrate, groupSize: fecEncoderGroupSize()))
        if bitrate < prev {
            helperCapture?.requestKeyframe()
        }
        let kbps = Double(bitrate) / 1000.0
        let prevKbps = Double(prev) / 1000.0
        logger.log("Adaptive bitrate: \(Int(prevKbps)) → \(Int(kbps)) kbps (\(reason))")
        // Severity follows direction so a reader scanning the margin sees cuts.
        recorder?.record(
            .encodeBitrateChanged,
            role: .sharer,
            severity: bitrate < prev ? .warning : .info,
            fields: [
                "from_kbps": DiagnosticValue(prev / 1000),
                "to_kbps": DiagnosticValue(bitrate / 1000),
                "baseline_kbps": DiagnosticValue(baselineBitrate.withLock { $0 } / 1000),
                "fec_group_size": DiagnosticValue(fecEncoderGroupSize()),
                "reason": .string(reason)
            ])
    }

    /// Group size the ENCODER is compensated for: the sweep's N while at
    /// least one viewer is gated for parity, else 0 — compensation must
    /// never outlive parity flow.
    private func fecEncoderGroupSize() -> Int {
        let gatedEmpty = fecGatedAddrs.withLock { $0.isEmpty }
        return gatedEmpty ? 0 : fecState.withLock { $0.groupSize }
    }

    /// Apply a sweep-decided FEC step: store new state + gate set, and when
    /// the EFFECTIVE compensation changed, re-push the encoder rate and
    /// reset hysteresis (same discipline as `applyFpsTier`). Turning parity
    /// on drops effective media rate 9–17%, so also forces a keyframe.
    private func applyFECState(_ decision: FECSweepDecision) {
        let previousEffective = fecEncoderGroupSize()
        fecState.withLock { $0 = decision.state }
        // `gated` is a let member of the Sendable decision — safe to capture.
        fecGatedAddrs.withLock { $0 = decision.gated }
        let nextEffective = fecEncoderGroupSize()
        guard previousEffective != nextEffective else { return }
        lastBitrateChangeNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        let current = currentBitrate.withLock { $0 }
        if current > 0 {
            helperCapture?.setBitrate(Self.fecCompensatedBitrate(current, groupSize: nextEffective))
        }
        if previousEffective == 0 && nextEffective > 0 {
            helperCapture?.requestKeyframe()
        }
        logger.log("Adaptive FEC: effective group size \(previousEffective) → \(nextEffective)")
        // Only on the EFFECTIVE transition — a gray-zone decision that holds
        // N with nobody gated is bookkeeping, not an event.
        recorder?.record(
            nextEffective > 0 ? .fecArmed : .fecDisarmed,
            role: .sharer,
            fields: [
                "group_size": DiagnosticValue(nextEffective),
                "previous_group_size": DiagnosticValue(previousEffective),
                "gated_viewers": DiagnosticValue(decision.gated.count)
            ])
    }

    /// Live-apply a new user bandwidth ceiling mid-share (`nil` = automatic).
    /// Unlike fps/codec, which need a respawn, the ceiling rides the existing
    /// `setBitrate` message. Recomputes `baselineBitrate = min(anchoredBaseline,
    /// ceiling)`, cuts current bitrate if it now exceeds the baseline (a
    /// raised ceiling instead lets the sweep recover gradually). Folds into
    /// the session snapshot for crash-restart respawns. No-op until an
    /// encoder has anchored a baseline.
    public func updateQualityCeiling(_ bps: Int?) {
        // Same clamp/rounding as persistence (`normalized()`), so the live
        // path can't disagree with what the Settings pane stores.
        let ceiling = QualitySettings.normalizedCeiling(bps)
        let changed = sessionQuality.withLock { quality -> Bool in
            guard quality.maxBitrateBps != ceiling else { return false }
            quality.maxBitrateBps = ceiling
            return true
        }
        guard changed else { return }
        // Fold into the anchor inputs so the next IDR doesn't read as a
        // config change and re-anchor over this adjustment.
        lastAnchorInputs.withLock { $0?.ceilingBps = ceiling }
        let anchor = anchoredBaselineBitrate.withLock { $0 }
        guard anchor > 0 else { return }
        // Read the ceiling back off the session, not `ceiling` directly —
        // clearing it still resolves through `automaticCeilingBps`.
        let newBaseline = sessionQuality.withLock { $0 }.cappedBitrate(anchorBps: anchor)
        baselineBitrate.withLock { $0 = newBaseline }
        let current = currentBitrate.withLock { $0 }
        if current > newBaseline {
            applyAdaptiveBitrate(newBaseline, reason: "user bandwidth ceiling")
        } else {
            logger.log("Quality ceiling: baseline now \(newBaseline / 1000) kbps")
        }
    }

    // MARK: - Fan-out (video RTP, audio RTP, system audio)

    /// Convert an encoded AVCC access unit into RTP packets and fan them out
    /// to every registered viewer with a per-viewer SSRC and sequence number.
    /// On IDR, prepend cached parameter sets as Single NAL packets so
    /// late-joining viewers can decode the very first frame (HEVC: VPS+SPS+
    /// PPS; H.264: SPS+PPS).
    private func broadcast(avccData: Data, isKeyframe: Bool) {
        // A broadcast racing `stop()` either copies out the still-live
        // listener (its sends fail once the socket closes) or reads nil.
        guard let pl = media else { return }
        // Codec is cached from the parameter-sets blob the helper
        // sends right after its first encoded frame.
        guard let codec = helperCodec else { return }

        var nals = AVCCParser.nalUnits(from: avccData)
        if isKeyframe, let cached = parameterSets.withLock({ $0 }) {
            switch cached {
            case .h264(let sps, let pps):
                nals = [sps, pps] + nals
            case .hevc(let vps, let sps, let pps):
                // HEVC parameter-set order is significant: VPS, SPS, PPS.
                nals = [vps, sps, pps] + nals
            }
        }
        guard !nals.isEmpty else { return }

        let rtpTs = currentRTPTimestamp()

        // Snapshot viewer state and bump nextSequence atomically so two
        // concurrent broadcasts can't issue overlapping seq ranges to the
        // same viewer.
        struct Plan {
            let addr: String
            let ssrc: UInt32
            let startSeq: UInt16
        }
        // Predict packet count by packetizing once with seq=0/ssrc=0; each
        // viewer then gets the same byte template with seq/ssrc rewritten.
        let templates: [Data]
        switch codec {
        case .h264:
            templates = h264Packetizer.packetize(
                nals: nals, timestamp: rtpTs, ssrc: 0, startSequence: 0
            )
        case .hevc:
            templates = h265Packetizer.packetize(
                nals: nals, timestamp: rtpTs, ssrc: 0, startSequence: 0
            )
        }
        let packetCount = UInt16(templates.count)

        let nowNs = DispatchTime.now().uptimeNanoseconds
        let plans = viewers.withLock { state -> [Plan] in
            var out: [Plan] = []
            // Snapshot keys before the lookup/update loop so we don't iterate
            // a dict whose contents are mid-mutation.
            let addrs = Array(state.keys)
            out.reserveCapacity(addrs.count)
            for addr in addrs {
                guard var viewer = state[addr] else { continue }
                // Keyframe-only throttle: skip inter frames WITHOUT reserving
                // their sequence numbers, so the stream reads as a valid
                // slideshow, not a perceived-loss gap that re-triggers the
                // PLI. Contrast the backlog drop below, which keeps the
                // reserved seq on purpose — do not unify the two.
                let until = viewer.throttledUntilNs
                let send = Self.shouldSendFrame(isKeyframe: isKeyframe, throttledUntilNs: until, nowNs: nowNs)
                guard send else { continue }
                out.append(Plan(addr: addr, ssrc: viewer.ssrc, startSeq: viewer.nextSequence))
                viewer.nextSequence &+= packetCount
                // The per-viewer denominator the FEC arm needs.
                viewer.packetsSentThisWindow += Int(packetCount)
                state[addr] = viewer
            }
            return out
        }

        // Record this broadcast in the retransmit ring for NACK-capable
        // viewers; a frame the send-chain cap sheds below is still
        // registered, so a NACK can recover an intentionally dropped frame.
        let nackAddrs = viewerCaps.withLock { caps in
            plans.compactMap { (caps[$0.addr]?.contains(.nack) ?? false) ? $0.addr : nil }
        }
        if !nackAddrs.isEmpty {
            let batchID = retransmitBuffer.record(templates: templates, nowNs: nowNs)
            let nackSet = Set(nackAddrs)
            for plan in plans where nackSet.contains(plan.addr) {
                retransmitBuffer.recordViewerRange(
                    addr: plan.addr, startSeq: plan.startSeq, count: packetCount, batchID: batchID)
            }
        }

        // FEC: compute the XOR parity bodies ONCE per batch (shared templates,
        // only baseSeq is per-viewer) when FEC is on and a plan recipient
        // passed the gate. Groups never span batches — `groupRanges` on this
        // batch's template array enforces that. Keyed by each group's LAST
        // template index so the send job can interleave parity right behind it.
        let fecGroupSize = fecState.withLock { $0.groupSize }
        let fecRecipients: Set<String>
        if fecGroupSize > 0 {
            let gatedSnapshot = fecGatedAddrs.withLock { $0 }
            fecRecipients = gatedSnapshot.intersection(plans.map(\.addr))
        } else {
            fecRecipients = []
        }
        let parityByLastIndex: [Int: (offset: Int, count: Int, body: Data)]
        if fecRecipients.isEmpty {
            parityByLastIndex = [:]
        } else {
            var groups: [Int: (offset: Int, count: Int, body: Data)] = [:]
            for range in FECCodec.groupRanges(templateCount: templates.count, groupSize: fecGroupSize) {
                let body = FECCodec.parityBody(for: templates[range])
                guard !body.isEmpty else { continue }
                groups[range.upperBound - 1] = (offset: range.lowerBound, count: range.count, body: body)
            }
            parityByLastIndex = groups
        }

        // Fan out to each viewer on its own send chain, capped per-viewer so
        // a slow viewer drops (a PLI recovers) rather than throttling
        // everyone else.
        videoSendTails.withLock { tails in
            var next: [String: ViewerSendChain] = [:]
            next.reserveCapacity(plans.count)
            for plan in plans {
                var chain = tails[plan.addr] ?? ViewerSendChain()
                if chain.queuedFrames >= Self.maxQueuedVideoFramesPerViewer {
                    // Viewer is behind — drop this frame for it. Its seq numbers
                    // were already reserved, so the gap reads as loss and the
                    // viewer's PLI fetches a fresh keyframe.
                    chain.droppedFrames += 1
                    next[plan.addr] = chain
                    continue
                }
                let prev = chain.task
                let addr = plan.addr
                let ssrc = plan.ssrc
                let startSeq = plan.startSeq
                let sendParity = !parityByLastIndex.isEmpty && fecRecipients.contains(plan.addr)
                chain.queuedFrames += 1
                let job = Task { [weak self] in
                    await prev?.value
                    for (i, template) in templates.enumerated() {
                        var pkt = template
                        Self.rewriteRTPHeader(&pkt, sequence: startSeq &+ UInt16(i), ssrc: ssrc)
                        // UDP is allowed to fail; a viewer PLI recovers it.
                        try? await pl.send(pkt, to: addr)
                        // Each group's parity goes out IMMEDIATELY after
                        // that group's last media packet — never after the
                        // whole batch. A keyframe batch can run to hundreds
                        // of packets: batch-trailing parity would (a) let
                        // the viewer's bounded FECGroupBuffer evict early
                        // groups' members before their parity arrives, and
                        // (b) leave an early-group gap NACK-eligible long
                        // before recovery data is even on the wire. Same
                        // send-chain job, so ordering, the backlog cap, and
                        // the drop policy still apply — a frame the cap
                        // sheds for a viewer sheds its parity with it.
                        // Only baseSeq is per-viewer; the body is shared.
                        if sendParity, let group = parityByLastIndex[i] {
                            let datagram = ScreenShareControlMessage.encodeFEC(
                                baseSeq: startSeq &+ UInt16(group.offset),
                                count: group.count,
                                body: group.body)
                            try? await pl.send(datagram, to: addr)
                        }
                    }
                    if sendParity {
                        self?.onFECParitySentForTesting?(addr, parityByLastIndex.count)
                    }
                    self?.videoSendTails.withLock { $0[addr]?.queuedFrames -= 1 }
                }
                chain.task = job
                next[plan.addr] = chain
            }
            // Replacing the dict prunes chains for viewers no longer present.
            tails = next
        }
    }

    /// 90 kHz RTP timestamp, anchored at server start. Wraps every ~13 hours
    /// at 90 kHz, which is fine — RTP timestamps are designed to wrap.
    private func currentRTPTimestamp() -> UInt32 {
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- rtpTimestampOriginNs
        // Multiply nanoseconds by 9 then divide by 100_000 → ns × (90_000 / 1e9).
        let ticks = (elapsedNs / 100_000) * 9
        return UInt32(truncatingIfNeeded: ticks)
    }

    /// Send one outbound audio RTP packet (sharer's mic) to all viewers.
    /// VoiceChannel calls this from its onSend closure. Fans out on the
    /// per-viewer audio send chains so a slow viewer's `pl.send` parks only
    /// its own next packet instead of stalling audio to everyone.
    public func sendAudioRTP(_ packet: Data) {
        guard let pl = media else { return }
        let recipients = viewers.withLock { Array($0.keys) }
        enqueueAudioPackets(packet, to: recipients, on: pl)
    }

    /// Enable/disable the "viewers may ask for remote control" gate. Turning
    /// it off also **drains every parked request** (`.controlRevoked` to
    /// each, pending rows clear); it does not revoke an existing grant.
    public func setAllowControlRequests(_ on: Bool) {
        controlRequestsAllowed.withLock { $0 = on }
        guard !on else { return }
        let drained = controlRequests.withLock { state -> [UUID] in
            let ids = Array(state.keys)
            state.removeAll()
            return ids
        }
        guard !drained.isEmpty else { return }
        notifyControlRequestsChanged()
        for connectionID in drained {
            sendControlRevoked(to: connectionID, reason: "control requests disabled")
        }
        logger.log("Declined \(drained.count) pending control request(s) (control requests disabled)")
    }

    /// Test-only: park a control request as if it arrived on the TCP control
    /// channel, exercising `setAllowControlRequests`'s decline-and-drain
    /// without a live listener.
    func recordControlRequestForTesting(connectionID: UUID, ip: String) {
        recordControlRequest(connectionID: connectionID, ip: ip)
    }

    /// Enable/disable sharing system audio to viewers. Stores the latch (so a
    /// helper (re)spawn re-sends it) and forwards to the live helper for an
    /// instant mute/unmute. Called from the MainActor by `AppState`.
    public func setShareSystemAudio(_ on: Bool) {
        shareSystemAudio.withLock { $0 = on }
        helperCapture?.setAudioEnabled(on)
    }

    /// Tell the server whether the host's capture path is configured to
    /// produce 10-bit video. Safe before or during a share; turning it ON
    /// mid-share re-evaluates admitted viewers immediately, so an incapable
    /// one already watching latches to 8-bit now rather than at next join.
    public func setTenBitCaptureRequested(_ requested: Bool) {
        tenBitRequested.withLock { $0 = requested }
        guard requested else { return }
        enforceBitDepthCapability(trigger: "capture setting")
    }

    /// Packetize one helper-produced system-audio AU as RTP (PT 99, reserved
    /// SSRC) and fan it out to viewers through the shared audio tail. Called on
    /// the helper's reader thread — the only caller, so the packetizer's
    /// single-thread contract holds.
    private func broadcastSystemAudio(au: Data) {
        guard isRunning else { return }
        sendAudioRTP(systemAudioPacketizer.packetize(au: au))
    }

    public func getIPAddresses() async throws -> (ip4: String?, ip6: String?) {
        guard let node = node else { throw TailscaleError.badInterfaceHandle }
        return try await node.addrs()
    }

    // MARK: - Teardown

    public func stop() async {
        logger.log("Server stopping…")
        // First thing: every loop/sweep/callback/restart leg gates on a
        // locked `isRunning` read, so the stop is visible at their next
        // check — in particular the restart chain's post-spawn re-check.
        lifecycle.withLock { $0.isRunning = false }

        // Drop anything still queued for annotation fan-out: every viewer is
        // about to get SERVER_BYE, so there is no canvas left to correct.
        annotationOutboxContinuation.finish()
        annotationDrain.withLock { $0?.cancel() }

        // End any remote-control session. Viewers are torn down by SERVER_BYE
        // below, so there's no need to send a per-connection revoke — just
        // clear the grant/request state, drop queued input, and notify the UI.
        let hadGrant = controlGrant.withLock { state -> Bool in
            let had = state.grant != nil
            if had {
                state.grant = nil
                state.generation += 1
            }
            return had
        }
        controlRequests.withLock { $0.removeAll() }
        remoteControlInjector?.deactivate()
        droppedInputLogged.withLock { $0 = false }
        inputRateLimiter.withLock { $0 = EventRateLimiter() }
        if hadGrant { notifyControlGrantChanged() }
        notifyControlRequestsChanged()
        linkOffers.withLock { $0.clear() }
        notifyLinkOffersChanged()

        // Drain any in-flight `restartCapture` before touching
        // `helperCapture` — else its final assignment races our detach and
        // orphans a child process (the stuck recording badge).
        let pending = restartTask.withLock { task -> Task<Error?, Never>? in
            let t = task
            task = nil
            return t
        }
        if let pending {
            _ = await pending.value
        }

        // Best-effort SERVER_BYE first, before tearing the listener down —
        // `pc.Close()` discards anything still buffered in the Go-side
        // socketpair. Three redundant sends per viewer mitigate UDP loss;
        // the sleep after gives tsnet's bridge goroutines time to emit them.
        let goodbyeAddrs =
            viewers.withLock { Array($0.keys) }
            + pendingViewers.withLock { Array($0.keys) }
        if let pl = media, !goodbyeAddrs.isEmpty {
            let payload = ScreenShareControlMessage.encode(.serverBye)
            for _ in 0..<3 {
                for addr in goodbyeAddrs {
                    try? await pl.send(payload, to: addr)
                }
            }
            logger.log("Server stop: SERVER_BYE sent to \(goodbyeAddrs.count) viewer(s)")
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Claim the backend atomically (clearing codec too), stop outside
        // the lock — `broadcast()` now reads nil and no-ops.
        let capture = lifecycle.withLock { lc -> (any CaptureEncoding)? in
            let c = lc.helperCapture
            lc.helperCapture = nil
            lc.helperCodec = nil
            return c
        }
        await capture?.stop()
        lastAnchorInputs.withLock { $0 = nil }
        logger.log("Server stop: capture done")

        viewers.withLock { $0.removeAll() }
        pendingViewers.withLock { $0.removeAll() }
        peerNameCache.withLock { $0.removeAll() }
        peerStableIDCache.withLock { $0.removeAll() }
        preApprovedIPs.withLock { $0.removeAll() }
        expelledAddrs.withLock { $0.removeAll() }
        // Drop per-viewer send chains. Any in-flight send job completes on its
        // own (its pl.send just fails once the listener closes below).
        videoSendTails.withLock { $0.removeAll() }
        audioSendTails.withLock { $0.removeAll() }
        viewerCaps.withLock { $0.removeAll() }
        retransmitBuffer.reset()
        fecState.withLock { $0 = FECState() }
        fecGatedAddrs.withLock { $0.removeAll() }
        notifyViewersChanged()
        notifyPendingViewersChanged()

        // Detach-then-close: once the slot is nil every sender snapshots
        // nil and no-ops instead of racing the close.
        let socketsToClose = lifecycle.withLock { lc in
            let sockets = (lc.packetListener, lc.guestPacketListener)
            lc.packetListener = nil
            lc.guestPacketListener = nil
            return sockets
        }
        await socketsToClose.0?.close()
        await socketsToClose.1?.close()
        guestAddrs.withLock { $0.removeAll() }
        // Stream viewers already got SERVER_BYE through the routes above;
        // drop the routes so a straggling send no-ops. The connections
        // themselves belong to the host-owned listener and may outlive the
        // share.
        streamRoutes.withLock { $0.removeAll() }
        streamAddrByConnection.withLock { $0.removeAll() }
        logger.log("Server stop: packet listener closed")

        let receiveErrors = receiveLoopErrorTotal.withLock { count -> Int in
            let total = count
            count = 0
            return total
        }
        if receiveErrors > 0 {
            logger.log("Server stop: receive loop survived \(receiveErrors) error(s) this session")
        }

        // Wipe per-connection annotation-UUID state before clearing the
        // handlers so the cleanup path in `installControlHandlers` doesn't
        // fire stale `.undo` ops back through `onAnnotationReceived` after
        // AppState has already torn the overlay down.
        annotationsByConnection.withLock { $0.removeAll() }
        annotationConnectionIP.withLock { $0.removeAll() }
        droppedAnnotationLogged.withLock { $0 = false }
        pendingCapLogged.withLock { $0 = false }
        uninstallControlHandlers()

        // Only tear down the listener if we created it ourselves — when
        // AppState owns it, leave it running for request-to-share traffic.
        typealias ListenerPair = (TailscreenControlListener?, TailscreenControlListener?)
        let (ownedListener, guestListener) = lifecycle.withLock { lc -> ListenerPair in
            let pair = (lc.ownedControlListener, lc.guestControlListener)
            lc.ownedControlListener = nil
            lc.controlListener = nil
            lc.guestControlListener = nil
            return pair
        }
        if let ownedListener {
            await ownedListener.stop()
            logger.log("Server stop: owned control listener closed")
        }
        // The guest control channel dies with the share unconditionally —
        // its listener is bound on a guest node the host is about to close.
        if let guestListener {
            await guestListener.stop()
            logger.log("Server stop: guest control channel closed")
        }

        // Only close the node if this server actually owns it — closing an
        // AppState-owned node here would break peer discovery and sign-in.
        let (nodeToClose, ownsIt) = lifecycle.withLock { lc -> (TailscaleNode?, Bool) in
            let n = lc.node
            lc.node = nil
            return (n, lc.ownsNode)
        }
        if let nodeToClose, ownsIt {
            try? await nodeToClose.close()
        }

        logger.log("Server stopped")
    }

    deinit {
        lifecycle.withLock { $0.isRunning = false }
        // Synchronous only. Ends the drain loop for a server dropped without
        // `stop()` (the loop holds `self` weakly).
        annotationOutboxContinuation.finish()
    }

    // MARK: - Test-only entrypoints
    //
    // `ScreenShareSyntheticFramesTests` brings the server up with
    // `filterData: nil` (no capture-helper) and injects pre-encoded AVCC
    // bytes through the broadcast path. Reachable only via `@testable import`.

    /// Seed the server's cached codec + parameter sets as if the
    /// capture-helper had just emitted them.
    public func injectSyntheticParameters(_ params: CodecParameterSets) {
        parameterSets.withLock { $0 = params }
        switch params {
        case .h264: lifecycle.withLock { $0.helperCodec = .h264 }
        case .hevc: lifecycle.withLock { $0.helperCodec = .hevc }
        }
    }

    /// Fan out a pre-encoded AVCC access unit through the server's RTP path.
    /// Bypasses the helper-process plumbing but uses the exact same broadcast
    /// route production frames take.
    func broadcastForTesting(avccData: Data, isKeyframe: Bool) {
        broadcast(avccData: avccData, isKeyframe: isKeyframe)
    }

    /// Inject a system-audio AU as if the capture-helper had produced it:
    /// packetize as RTP PT 99 and fan out through the exact production path.
    /// Sibling of `broadcastForTesting` for the audio side.
    func broadcastSystemAudioForTesting(au: Data) {
        broadcastSystemAudio(au: au)
    }
}
