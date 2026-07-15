import AppKit
import Foundation
import ScreenCaptureKit
import TailscaleKit
import os

/// Screen-share server. Owns the UDP video path and registers handlers on
/// the long-lived `TailscreenControlListener` for the duration of a share:
///
///   - **UDP 7447**: actual video stream. Carries RTP packets out to viewers
///     and small control bytes (HELLO/KEEPALIVE/BYE/PLI) back from them. The
///     same socket multiplexes both directions; we tell them apart by the
///     first byte (RTP V=2 → 0x80–0xBF, control → 0x00–0x7F).
///   - **TCP 7447** is shared with the request-to-share path via
///     `TailscreenControlListener` (owned by `AppState`). The server attaches
///     its annotation handlers in `start()` and clears them in `stop()`; the
///     listener and its bound socket survive across share start/stop cycles.
///
/// Viewers are tracked by their UDP source address. A viewer has to send a
/// HELLO datagram to be added to the fan-out set; if no HELLO/KEEPALIVE
/// arrives for `viewerIdleTimeout` seconds the viewer is dropped silently.
/// There is no TCP-style accept queue and no per-viewer send pipeline — UDP
/// send is non-blocking and a slow viewer just drops packets at the network
/// boundary instead of stalling our process.

/// Public-facing snapshot of one connected viewer. Built from the server's
/// internal `Viewer` plus a netmap lookup against the live `TailscaleNode`
/// to translate the source IP into a friendly hostname. `hostname` is `nil`
/// until the lookup completes (or if the peer isn't in the netmap), in
/// which case the UI should fall back to `tailscaleIP`.
struct ViewerInfo: Sendable, Identifiable, Hashable {
    let id: String  // matches the server's internal viewer key ("ip:port")
    let tailscaleIP: String
    var hostname: String?
    /// Tailscale StableNodeID (LocalAPI `PeerStatus.ID`) resolved from the
    /// same netmap lookup that fills `hostname`. nil until resolution
    /// completes (or if the peer isn't in the netmap). This is the key the
    /// persistent allow/deny store uses — never key policy on hostname or
    /// any other wire-supplied claim.
    var stableID: String?
    let connectedAt: Date
}

/// A viewer that sent HELLO while `requireApproval` was on and is waiting
/// for the sharer's Accept / Deny decision. Kept distinct from
/// `ViewerInfo` so the UI can show "wants to view" prompts without
/// polluting the connected-viewer roster. `id` matches the same
/// `"ip:port"` key the server uses internally, so the AppState pass-through
/// to `approveViewer`/`denyViewer` is trivial.
struct PendingViewerInfo: Sendable, Identifiable, Hashable {
    let id: String  // "ip:port"
    let tailscaleIP: String
    var hostname: String?
    /// Tailscale StableNodeID — see `ViewerInfo.stableID`. Carried here so
    /// "Always Allow" / "Deny & Block" on a pending row can persist the
    /// decision under the spoof-resistant key.
    var stableID: String?
    let arrivedAt: Date
}

final class TailscaleScreenShareServer: @unchecked Sendable {
    private let port: UInt16
    var node: TailscaleNode?
    /// True when this server created the tsnet node itself; false when it
    /// borrowed a node owned by AppState. Controls whether `stop()` tears
    /// the node down or just releases its reference.
    private var ownsNode: Bool = true
    /// External TCP listener (owned by AppState) on which the server
    /// registers annotation handlers for the duration of a share. nil when
    /// running standalone (e.g. legacy callers / tests that create their
    /// own node) — in that case `start()` falls back to its own listener.
    private var controlListener: TailscreenControlListener?
    /// Backing listener when the server owns its own. Mutually exclusive
    /// with `controlListener` (the external case).
    private var ownedControlListener: TailscreenControlListener?
    private var packetListener: PacketListener?
    private var isRunning = false
    private let logger: TSLogger

    /// Wall-clock anchor used to derive the 90 kHz RTP timestamp. Stays
    /// fixed for the lifetime of the server so the timestamp space is
    /// monotonic across encoder restarts.
    private let rtpTimestampOriginNs: UInt64

    /// Per-viewer state. Keyed by the UDP source address ("ip:port") that
    /// the HELLO arrived from — that's also the destination we echo packets
    /// back to. `pliTimestampsNs` is a small ring of recent PLI arrivals
    /// used by the adaptive-bitrate sweep — losing more than a couple of
    /// frames in 5 s is the signal to step bitrate down.
    private struct Viewer {
        let addr: String
        let ssrc: UInt32
        /// SSRC the sharer assigns to this viewer for *audio* (sent in
        /// HELLO_ACK). Distinct from `ssrc` above, which the server uses
        /// when sending video *to* this viewer.
        let audioSSRC: UInt32
        var nextSequence: UInt16
        var lastSeenNs: UInt64
        var pliTimestampsNs: [UInt64] = []
    }

    private let viewers = OSAllocatedUnfairLock<[String: Viewer]>(initialState: [:])
    private let parameterSets = OSAllocatedUnfairLock<CodecParameterSets?>(initialState: nil)
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
    private let annotationsByConnection = OSAllocatedUnfairLock<[UUID: Set<UUID>]>(initialState: [:])

    /// Maps a TCP annotation connection's `UUID` to the peer IP it dialed
    /// from (stripped of the ephemeral port). Populated on the first
    /// annotation seen on a connection and cleared when it closes. Lets the
    /// inbound-annotation gate check the connection's peer against the
    /// admitted-viewer set (the video path's admission gate covers only
    /// UDP, so without this a pending/denied/blocked peer could still inject
    /// annotations over TCP), and lets `expelViewer` sever a blocked peer's
    /// back-channel by IP.
    private let annotationConnectionIP = OSAllocatedUnfairLock<[UUID: String]>(initialState: [:])

    // MARK: - Remote control

    /// The single live remote-control grant, or nil when nobody holds control.
    /// The input-event gate matches purely on `connectionID` (see
    /// `RemoteControlPolicy.shouldInject`), so a NAT rebind can't inherit it
    /// and a non-grantee can't inject. At most one grant exists — granting a
    /// new viewer implicitly revokes the old.
    private let controlGrant = OSAllocatedUnfairLock<ControlGrant?>(initialState: nil)
    /// Viewers that asked for control and are awaiting the sharer's Grant /
    /// Deny, keyed by their TCP control connection's `UUID`.
    private let controlRequests = OSAllocatedUnfairLock<[UUID: ControlRequestInfo]>(initialState: [:])
    /// Per-share event-rate ceiling on injected input (defense against a
    /// malicious grantee flooding the injector). Reset in `stop()`.
    private let inputRateLimiter = OSAllocatedUnfairLock<EventRateLimiter>(initialState: EventRateLimiter())
    /// Injects the grantee's events on this (main) process via `CGEvent`.
    private let remoteControlInjector = RemoteControlInjector()
    /// Log a dropped (non-grantee) input event at most once per share.
    private let droppedInputLogged = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Fires whenever the set of pending control requests changes. Snapshot;
    /// replace the UI list wholesale. Runs on any thread — bounce to MainActor.
    var onControlRequestsChanged: (@Sendable ([ControlRequestInfo]) -> Void)?
    /// Fires whenever the live grant changes (granted, revoked, auto-revoked).
    /// `nil` means nobody holds control now.
    var onControlGrantChanged: (@Sendable (ControlGrantInfo?) -> Void)?
    /// Fires when a grant is refused because the process lacks the
    /// Accessibility TCC grant `CGEvent` injection needs. AppState surfaces
    /// the prompt + deep-link to Privacy → Accessibility.
    var onControlAccessibilityRequired: (@Sendable () -> Void)?
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

    /// Public projection of `viewers` that the UI can read without touching
    /// the internal RTP bookkeeping. Kept in lockstep with `viewers` from
    /// the same lifecycle hooks (`registerOrRefresh`, `removeViewer`,
    /// `sweepIdleViewers`, `stop`). `Viewer` is intentionally not Sendable —
    /// `ViewerInfo` is the safe, value-type snapshot.
    private let viewerInfos = OSAllocatedUnfairLock<[String: ViewerInfo]>(initialState: [:])

    /// Per-pending-viewer state for the approval gate (see
    /// `requireApproval`). Kept separate from `viewers` so a pending viewer
    /// can't accidentally be included in video / audio fan-out. Stores
    /// `lastSeenNs` so the idle sweep can prune pending viewers that walk
    /// away before the sharer answers; cached audio SSRC so an `approveViewer`
    /// can finally emit the HELLO_ACK the viewer's been waiting on.
    private struct PendingViewer {
        let addr: String
        let audioSSRC: UInt32
        var lastSeenNs: UInt64
    }
    private let pendingViewers = OSAllocatedUnfairLock<[String: PendingViewer]>(initialState: [:])
    /// Hard cap on the pending-approval set. A peer that HELLOs while the
    /// gate is on pins server state (and a LocalAPI resolver) until the
    /// sharer answers or the 60 s sweep collects it; without a cap a flood
    /// of spoofed HELLO source addresses could exhaust memory and amplify
    /// LocalAPI traffic. New HELLOs past the cap are dropped (logged once).
    static let maxPendingViewers = 32
    /// One-shot latch so the "pending set full" line logs at most once per
    /// saturation episode instead of on every dropped HELLO.
    private let pendingCapLogged = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Pure pending-cap gate: a HELLO is admitted to the pending set when it
    /// refreshes an existing slot, or when the set is below `cap`. Extracted
    /// so the DoS bound is unit testable.
    static func canAcceptPending(currentCount: Int, isExisting: Bool, cap: Int = maxPendingViewers) -> Bool {
        isExisting || currentCount < cap
    }
    /// Public projection of `pendingViewers` — built alongside it in the
    /// same critical sections, surfaced via `onPendingViewersChanged`.
    private let pendingViewerInfos = OSAllocatedUnfairLock<[String: PendingViewerInfo]>(initialState: [:])

    /// When true, a HELLO from a previously-unseen viewer parks them in
    /// `pendingViewers` and fires `onPendingViewersChanged` instead of
    /// joining them immediately. The sharer must call `approveViewer` /
    /// `denyViewer` to resolve the request. Set via `setRequireApproval`
    /// while a share is live; defaults off so test fixtures and existing
    /// callers see unchanged behavior.
    private let requireApproval = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Pending viewers go stale eventually too — pruned by the same idle
    /// sweep as connected viewers, using a longer timeout so the sharer
    /// has plausibly enough time to react. Matches the typical macOS
    /// notification banner dwell + a few seconds of user attention.
    private let pendingApprovalTimeoutNs = TransportTuning.pendingApprovalTimeoutNs

    /// IP → hostname cache. Filled lazily by the resolve tasks from the
    /// LocalAPI backend status. Avoids re-querying tsnet on every
    /// reconnect / KEEPALIVE storm. Cleared in `stop()`.
    private let peerNameCache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    /// IP → StableNodeID cache, filled alongside `peerNameCache`. A cached
    /// ID lets `registerOrRefresh` apply the remembered allow/deny policy
    /// synchronously on a re-HELLO instead of re-parking the peer behind
    /// the async LocalAPI lookup. Cleared in `stop()`.
    ///
    /// KNOWN LIMITATION: this cache freezes the IP→StableNodeID binding for
    /// the lifetime of the share. If an ephemeral tailnet IP is reclaimed
    /// and reassigned to a *different* node mid-share, that new node would
    /// inherit the previous occupant's remembered allow/deny decision — a
    /// rare consent-bypass. Accepted for now (ephemeral-IP churn on a live
    /// share is uncommon and the share is short-lived); a short TTL on cache
    /// entries would close it if it ever bites.
    private let peerStableIDCache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Remembered per-peer policies, keyed by StableNodeID. The server is
    /// `@unchecked Sendable` and must never reach into `UserDefaults` or
    /// `@MainActor` state, so AppState pushes value snapshots through
    /// `setAccessPolicies` — at share start and on every store change.
    /// Empty when no policies exist (tests, standalone callers), in which
    /// case every path below degrades to the pre-policy behavior.
    private let accessPolicies = OSAllocatedUnfairLock<[String: PeerPolicy]>(initialState: [:])

    /// One-time admit list keyed by peer IP. After the sharer accepts a
    /// named request-to-share (explicit per-peer consent), AppState
    /// pre-approves the requester's IP here so their imminent HELLO joins
    /// immediately instead of parking behind a second approval prompt.
    /// Consumed on first matching HELLO. A remembered `deny` still outranks
    /// it — a pre-approval never un-blocks a blocked peer.
    private let preApprovedIPs = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// Quality knobs snapshotted at `start()` and reused for **every**
    /// helper respawn, so a crash-restart mid-share can't silently pick up
    /// different settings (fps/codec edits apply on the next share). The
    /// one exception is the bandwidth ceiling, which live-applies via
    /// `updateQualityCeiling` — that also folds the new value into this
    /// snapshot so respawns spawn with the ceiling the user last set.
    /// Locked: written from `start()`/`updateQualityCeiling` (MainActor)
    /// and read from `startHelperCapture` and the helper's reader thread.
    private let sessionQuality = OSAllocatedUnfairLock<QualitySettings>(initialState: .default)

    /// Raw encoder-formula baseline (`w × h × bpp × fpsCap`) anchored on
    /// each parameter-sets emit, *before* the user ceiling is applied.
    /// Kept separate from `baselineBitrate` so raising or removing the
    /// ceiling mid-share can recompute the effective baseline without
    /// waiting for the next encoder reinit.
    private let anchoredBaselineBitrate = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Inputs that produced the current adaptive-bitrate anchor. Parameter
    /// sets — and therefore `onEncoderResolution` — re-emit on *every* IDR
    /// (roughly every 2 s under PLI-driven keyframes), so the anchor
    /// handler compares against this and only resets the sweep's state
    /// (`currentBitrate` / `lastBitrateChangeNs`) when the encoder
    /// configuration genuinely changed; an unconditional reset would wipe
    /// every cut and every recovery step within one hysteresis window.
    /// Cleared per helper spawn so a fresh helper (whose encoder starts
    /// back at the formula/ceiling bitrate) always re-anchors, and updated
    /// by `updateQualityCeiling` so a live ceiling edit doesn't look like
    /// a config change on the next IDR.
    private struct AnchorInputs: Equatable {
        let width: Int
        let height: Int
        let codec: VideoCodec
        let fpsCap: Int
        var ceilingBps: Int?
    }
    private let lastAnchorInputs = OSAllocatedUnfairLock<AnchorInputs?>(initialState: nil)

    /// Effective adaptive-sweep ceiling: the anchored formula baseline
    /// clamped by the user's bandwidth ceiling. The sweep never raises
    /// above it. Recomputed on every encoder reinit (resolution change)
    /// and on `updateQualityCeiling`.
    private let baselineBitrate = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// Current applied bitrate. Set equal to baseline at encoder setup,
    /// then cut/raised by the adaptive sweep.
    private let currentBitrate = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// Last time the sweep changed the bitrate. Used for hysteresis so we
    /// don't oscillate.
    private let lastBitrateChangeNs = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    /// Per-viewer video send chain: the tail send `Task` plus a count of
    /// frames queued behind it. Each viewer's frame N+1 awaits only its own
    /// frame N — so packet order is preserved per viewer (each has its own seq
    /// space), but a slow/distant viewer whose socketpair write blocks throttles
    /// only its own stream instead of stalling the global frame rate for
    /// everyone (the head-of-line blocking a single shared chain caused). See
    /// `broadcast`.
    private struct ViewerSendChain {
        var task: Task<Void, Never>?
        var queuedFrames: Int = 0
    }
    /// Keyed by viewer addr; pruned to the live viewer set on each broadcast.
    private let videoSendTails = OSAllocatedUnfairLock<[String: ViewerSendChain]>(initialState: [:])
    /// Drop a viewer's frame once this many are already queued behind a stalled
    /// send, so a viewer that can't keep up sheds frames (UDP video tolerates
    /// loss; a PLI recovers) rather than accumulating unbounded latency/memory.
    private static let maxQueuedVideoFramesPerViewer = TransportTuning.maxQueuedVideoFramesPerViewer

    /// A single shared tail for audio fan-out (sharer mic out plus
    /// viewer-to-viewer relay): every audio send chains through here so we
    /// don't spawn a fresh detached `Task` per ~21 ms AU × N viewers. Audio
    /// packets are tiny (one AAC AU each), so head-of-line blocking across
    /// viewers isn't the concern it is for video — a single chain is fine.
    /// Under congestion the chain provides natural backpressure — the next
    /// packet's job parks on the previous one's `await prev?.value` rather
    /// than piling up unbounded.
    private let audioBroadcastTail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// Drop viewers that have gone silent for this long. Has to absorb a
    /// run of consecutive UDP keepalive losses plus any Task scheduling
    /// jitter from the cooperative pool — the previous 5 s value was
    /// tight enough that a brief network/CPU stall would drop a healthy
    /// viewer mid-session, which then triggered the viewer's own 3 s
    /// "no video" disconnect and tore the whole call down. Clients send
    /// KEEPALIVE every 500 ms, so 15 s tolerates ~30 consecutive misses
    /// while still collecting a truly crashed viewer well before any
    /// HELLO retry would. Must stay equal to the client's idle disconnect
    /// — both are defined in `TransportTuning` to keep them coupled.
    private let viewerIdleTimeoutNs = TransportTuning.viewerIdleTimeoutNs

    var onCaptureStopped: ((Error?) -> Void)?
    var onPreviewImage: ((NSImage) -> Void)?

    /// JSON-encoded `PickerSelection` describing what the user picked —
    /// set by `start()` and replaced by the most recent `changeSource`.
    /// Cached so `restartCapture()` can rebuild the SCStream against the
    /// same content (display / window / app / multi-app) without forcing
    /// the caller to track that state. Carried as raw `Data` so the main
    /// process never has to know the schema — the helper decodes it.
    /// Locked: written from `start()` and the nonisolated-async
    /// `changeSource`, read inside the detached restart tasks — cross-thread
    /// like the class's other locked mutables.
    private let lastFilterData = OSAllocatedUnfairLock<Data?>(initialState: nil)

    /// Helper-process wrapper. Owns the child Tailscreen process
    /// running `--capture-helper`, which holds the SCStream and
    /// VideoEncoder.
    private var helperCapture: HelperScreenCapture?

    /// Codec the helper's encoder is producing. Set when the helper
    /// sends its first parameter-sets blob; consumed by `broadcast()`
    /// to pick H.264 vs HEVC RTP payload type.
    private var helperCodec: VideoCodec?

    /// Latched on when a viewer reports (via CODEC_NO) that it can't decode
    /// the current stream. Forces the helper's encoder to H.264 — the
    /// lowest-common-denominator codec every Mac can decode — on the next
    /// (re)spawn. We default to HEVC for its efficiency, but a single viewer
    /// that can't decode HEVC (e.g. an older Intel Mac) would otherwise sit
    /// on a black screen forever; falling the *whole* share back to H.264 is
    /// the safe recovery. Locked: read in `startHelperCapture` on the
    /// cooperative pool, written from the control-receive loop.
    private let forceH264 = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Latched on when a viewer reports (via PROFILE_NO) that it can decode
    /// the codec but not its bit depth — a 10-bit HEVC Main 10 stream reaching
    /// a viewer whose hardware only decodes 8-bit HEVC. Passes
    /// `TAILSCREEN_FORCE_8BIT=1` to the helper on the next (re)spawn so the
    /// capture-helper pins its `ColorInfo` to 8-bit (staying on HEVC). A
    /// lighter fallback than `forceH264`: we keep HEVC's efficiency, just drop
    /// the extra two bits. Locked for the same reason as `forceH264`.
    private let force8bit = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Stateful per-codec packetizers. Held across `broadcast()` calls so
    /// each call can recycle the previous batch's buffer storage instead
    /// of allocating a fresh `Data` per packet. See `RTPPacketBufferPool`
    /// for the COW-based safety argument. Cheap when unused (no codec yet
    /// settled): each holds an empty pool array.
    private let h264Packetizer = H264Packetizer()
    private let h265Packetizer = H265Packetizer()

    /// Total non-timeout receive-loop errors survived this session. Feeds
    /// the give-up log line and `stop()`'s summary. Locked: bumped from the
    /// receive task, read from `stop()`.
    private let receiveLoopErrorTotal = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Sliding-window restart counter for helper-process crashes.
    /// Each unexpected exit pushes its timestamp; we tolerate up to
    /// 3 exits within a 30 s window, after which we give up and
    /// surface the failure as a normal capture stop. Locked because
    /// it's mutated from the helper's `terminationHandler` queue *and*
    /// the restart `Task` on the cooperative pool — concurrent
    /// `append`/`removeAll` on a bare `Array` is heap corruption.
    private let helperCrashTimestampsNs = OSAllocatedUnfairLock<[UInt64]>(initialState: [])

    /// Uptime-ns of the last message received from the capture helper — AUs,
    /// params, logs, or the ~1 Hz heartbeat. The hung-helper watchdog compares
    /// `now` against this. Seeded to "now" when a helper spawns so SCStream
    /// bring-up gets a full grace window; 0 means no helper is running.
    private let lastHelperActivityNs = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    /// If the helper emits nothing for this long while a share is live, the
    /// watchdog assumes capture wedged — SCStream stopped delivering without
    /// the process exiting, which process-death detection can't catch — and
    /// restarts it. Generous (matches the viewer idle timeout): the helper
    /// heartbeats ~1 Hz off *any* delivered SCStream sample, including the
    /// `.idle` frames a static screen still produces, so a healthy idle share
    /// never trips it.
    private let helperLivenessTimeoutNs = TransportTuning.helperLivenessTimeoutNs
    /// On by default; `TAILSCREEN_DISABLE_HELPER_WATCHDOG=1` is an escape hatch
    /// in case some hardware delivers idle frames too sparsely to keep the
    /// heartbeat alive and would otherwise trip false restarts.
    private let helperWatchdogEnabled =
        ProcessInfo.processInfo.environment["TAILSCREEN_DISABLE_HELPER_WATCHDOG"] != "1"

    /// In-flight `restartCapture()` work. `stop()` awaits this before
    /// tearing down `helperCapture`, otherwise a concurrent restart
    /// can finish spawning a new helper *after* `stop()` already
    /// nulled out `helperCapture`, leaving an orphaned child process
    /// holding replayd's slot — visible as the macOS screen-recording
    /// badge stuck on after the user clicked Stop Sharing.
    private let restartTask = OSAllocatedUnfairLock<Task<Error?, Never>?>(initialState: nil)

    /// Fires when a viewer sends an annotation op over the back-channel.
    /// AppState routes these into the sharer's overlay window; the drawings
    /// get captured into the video stream and distributed to every viewer.
    var onAnnotationReceived: ((AnnotationOp) -> Void)?

    /// Fires whenever the connected-viewer set changes — join, BYE, idle
    /// timeout, hostname resolved, or `stop()`. The argument is a snapshot
    /// of the current roster; replace the UI's list wholesale rather than
    /// diffing. Callback may run on any thread; bounce to `@MainActor`.
    var onViewersChanged: (@Sendable ([ViewerInfo]) -> Void)?

    /// Fires whenever the pending-approval set changes — new HELLO under
    /// `requireApproval`, `approveViewer` / `denyViewer`, idle sweep, or
    /// `stop()`. Same shape and bounce rules as `onViewersChanged`.
    var onPendingViewersChanged: (@Sendable ([PendingViewerInfo]) -> Void)?

    /// Fires on every inbound audio RTP packet from any viewer. AppState
    /// pipes these into the local VoiceChannel so the sharer can hear
    /// viewers.
    var onAudioReceived: ((Data) -> Void)?

    /// Test-only: fires with the viewer's address each time a PLI is recorded.
    /// In production, a PLI also triggers `helperCapture?.requestKeyframe()`,
    /// but with no capture-helper (synthetic test mode) that's a no-op and the
    /// only observable effect is the recorded timestamp. Lets a test confirm
    /// the viewer→server PLI path without an encoder attached.
    var onPLIRecordedForTesting: ((String) -> Void)?

    /// Invoked once the underlying `TailscaleNode` has been instantiated but
    /// **before** `node.up()` is called. AppState uses this hook to subscribe
    /// an IPN-bus watcher that opens the interactive-login URL in the user's
    /// browser when tsnet emits a `BrowseToURL`. Without something listening
    /// before `up()`, the call blocks indefinitely waiting on a login the
    /// user can't see.
    var nodeReadyBeforeUp: (@Sendable (TailscaleNode) async -> Void)?

    init(port: UInt16 = NetworkConfig.tailscreenPort) {
        self.port = port
        self.logger = TSLogger()
        self.rtpTimestampOriginNs = DispatchTime.now().uptimeNanoseconds
    }

    /// Bring the server up. `filterData` is the JSON-encoded
    /// `PickerSelection` the picker subprocess produced. Pass `nil`
    /// only from tests that exercise the network/audio path and
    /// don't want the capture-helper subprocess to spawn — production
    /// callers always pass a real selection. `quality` is snapshotted
    /// for the whole share session (see `sessionQuality`).
    func start(
        hostname: String = "tailscreen-server",
        authKey: String? = nil,
        path: String? = nil,
        controlURL: String = kDefaultControlURL,
        filterData: Data?,
        quality: QualitySettings = .default,
        existingNode: TailscaleNode? = nil,
        controlListener: TailscreenControlListener? = nil
    ) async throws {
        guard !isRunning else { return }

        sessionQuality.withLock { $0 = quality.normalized() }

        let node: TailscaleNode
        if let existing = existingNode {
            // Reuse the AppState-owned node — same Tailscale identity used
            // for sign-in. Avoids spinning up a second tsnet machine that
            // would need its own browser login.
            node = existing
            self.node = existing
            self.ownsNode = false
            logger.log("Screen-share server reusing existing Tailscale node")
        } else {
            let statePath =
                path
                ?? {
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                        .first!
                    return appSupport.appendingPathComponent("Tailscreen/tailscale\(TailscreenInstance.stateSuffix)")
                        .path
                }()
            try? FileManager.default.createDirectory(atPath: statePath, withIntermediateDirectories: true)

            logger.log("Starting Tailscale server…")

            let config = Configuration(
                hostName: hostname,
                path: statePath,
                authKey: authKey,
                controlURL: controlURL,
                ephemeral: true
            )

            let newNode = try TailscaleNode(config: config, logger: logger)
            self.node = newNode
            self.ownsNode = true
            if let ready = nodeReadyBeforeUp {
                await ready(newNode)
            }
            // Bound up() when an auth key is present (no human in the loop, so
            // it should reach Running quickly); leave it unbounded otherwise so
            // an interactive browser login isn't cut off. See the matching note
            // in AppState.getOrCreateNode.
            if authKey != nil {
                try await withTimeout(seconds: 60) { try await newNode.up() }
            } else {
                try await newNode.up()
            }
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
            self.controlListener = provided
            logger.log("Screen-share server attaching to shared control listener")
        } else {
            let owned = TailscreenControlListener(port: port)
            try await owned.start(node: node)
            self.ownedControlListener = owned
            self.controlListener = owned
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
        self.packetListener = packetListener
        logger.log("UDP video stream listening on \(bindAddr)")

        isRunning = true

        Task { [weak self] in await self?.receiveControlLoop() }
        Task { [weak self] in await self?.sweepIdleViewers() }
        Task { [weak self] in await self?.adaptiveBitrateSweep() }

        lastFilterData.withLock { $0 = filterData }
        remoteControlInjector.setSelection(decodedSelection())
        if let filterData {
            try startHelperCapture(filterData: filterData)
        } else {
            logger.log("Screen-share server: no filterData — skipping helper-capture spawn (test mode)")
        }
    }

    /// What to do about a helper process that exited without being asked to.
    enum HelperExitDisposition: Equatable {
        /// replayd refused the capture slot (another same-bundle process
        /// already holds one). Respawning hits the exact same wall — bail
        /// straight to teardown instead of burning the crash budget.
        case slotRefused
        /// The helper tagged its own death as non-retryable (decode failure,
        /// startup-watchdog timeout, …) via `writeFatal("permanent: …")`.
        case permanent
        /// Anything else — worth respawning, subject to the crash budget.
        case retryable
    }

    /// Pure classification of a helper's unexpected-exit reason string.
    /// -3805 ("application connection being interrupted") on the helper's
    /// first SCStream startup is replayd refusing the slot; `permanent:` is
    /// the helper's own non-retryable marker. Extracted from
    /// `onUnexpectedExit` so the routing is unit testable.
    static func classifyHelperExit(reason: String) -> HelperExitDisposition {
        if reason.contains("-3805") || reason.localizedCaseInsensitiveContains("being interrupted") {
            return .slotRefused
        }
        if reason.contains("permanent:") {
            return .permanent
        }
        return .retryable
    }

    /// Crash budget: give up after this many helper exits inside the sliding
    /// window (see `slidingWindowCrashCount`).
    static let maxHelperCrashesPerWindow = TransportTuning.maxHelperCrashesPerWindow

    /// Pure sliding-window crash accounting: prune timestamps older than
    /// `windowNs`, record `nowNs`, and return how many crashes the window now
    /// holds (including this one). The caller gives up once the result
    /// exceeds `maxHelperCrashesPerWindow`. Extracted from `onUnexpectedExit`
    /// so the budget math is unit testable.
    static func slidingWindowCrashCount(
        _ stamps: inout [UInt64],
        appending nowNs: UInt64,
        windowNs: UInt64 = TransportTuning.helperCrashWindowNs
    ) -> Int {
        stamps.removeAll { nowNs &- $0 > windowNs }
        stamps.append(nowNs)
        return stamps.count
    }

    private func startHelperCapture(filterData: Data) throws {
        let helper = HelperScreenCapture()
        // Fresh helper ⇒ fresh anchor state: its encoder starts back at the
        // formula/ceiling bitrate, so the first parameter-sets emit must
        // re-anchor even if the resolution/codec are unchanged from the
        // previous helper's.
        lastAnchorInputs.withLock { $0 = nil }
        // Seed the liveness clock now so SCStream bring-up gets a full grace
        // window before the watchdog can fire, then tick it on every message.
        lastHelperActivityNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        helper.onActivity = { [weak self] in
            self?.lastHelperActivityNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        }
        helper.onAccessUnit = { [weak self] avcc, isKeyframe in
            self?.handleHelperAccessUnit(avcc, isKeyframe: isKeyframe)
        }
        helper.onParameterSets = { [weak self] params in
            self?.parameterSets.withLock { $0 = params }
            switch params {
            case .h264: self?.helperCodec = .h264
            case .hevc: self?.helperCodec = .hevc
            }
        }
        helper.onEncoderResolution = { [weak self] width, height in
            guard let self else { return }
            // Anchor the adaptive-bitrate ceiling. Parameter sets — and
            // this callback — re-emit on *every* IDR, so re-anchor only
            // when the inputs actually changed: an unconditional reset
            // would wipe the sweep's currentBitrate/hysteresis state every
            // couple of seconds and permanently defeat both cuts and
            // recovery. `helperCodec` is already set here because the
            // wrapper fires `onParameterSets` first (see the ordering
            // invariant in HelperScreenCapture's readLoop); the HEVC
            // default is a belt-and-braces fallback only. The fps factor
            // comes from the same session snapshot the helper's encoder
            // runs at, so the two ends of the formula can't diverge (this
            // used to hardcode 60.0), and the user's bandwidth ceiling
            // clamps the result exactly like the helper clamps its own
            // DataRateLimits.
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
            let bpp = VideoEncoder.defaultBitsPerPixel(for: codec)
            let anchor = VideoEncoder.computeBitrate(
                width: width, height: height, fps: quality.fpsCap, bitsPerPixel: bpp)
            self.anchoredBaselineBitrate.withLock { $0 = anchor }
            let baseline = min(anchor, quality.maxBitrateBps ?? anchor)
            self.baselineBitrate.withLock { $0 = baseline }
            self.currentBitrate.withLock { $0 = baseline }
            self.lastBitrateChangeNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
            self.logger.log(
                "HelperScreenCapture: anchored baseline bitrate \(baseline / 1000) kbps for "
                    + "\(width)x\(height) \(codec) @\(quality.fpsCap)fps"
            )
        }
        helper.onPreviewImage = { [weak self] image in
            self?.onPreviewImage?(image)
        }
        helper.onUserStopped = { [weak self] in
            self?.logger.log("HelperScreenCapture: user stopped via Control Center")
            self?.helperCapture = nil
            // Surface a userStopped SCStreamError so AppState's
            // `isUserInitiatedCaptureStop` branch tears the share
            // down quietly instead of trying to recover.
            let err = NSError(
                domain: SCStreamError.errorDomain,
                code: SCStreamError.Code.userStopped.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "User stopped capture"]
            )
            self?.onCaptureStopped?(err)
        }
        helper.onUnexpectedExit = { [weak self] reason in
            guard let self else { return }
            self.logger.log("HelperScreenCapture: unexpected exit (\(reason))")
            self.helperCapture = nil
            switch Self.classifyHelperExit(reason: reason) {
            case .slotRefused:
                let err = NSError(
                    domain: "Tailscreen.HelperScreenCapture",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Another Tailscreen instance on this Mac is already capturing — replayd refused the slot. Stop sharing on the other instance and try again."
                    ]
                )
                self.onCaptureStopped?(err)
                return
            case .permanent:
                let err = NSError(
                    domain: "Tailscreen.HelperScreenCapture",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: reason]
                )
                self.onCaptureStopped?(err)
                return
            case .retryable:
                break
            }
            // Sliding-window restart: tolerate ≤3 crashes in 30 s,
            // give up after that. Each crash invalidates replayd's
            // slot for that PID, so respawning gets a fresh process
            // with no inherited bad state.
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
            // Route the respawn through the same tracked Task that `stop()`
            // awaits and that re-checks `isRunning` *after* the spawn.
            // Calling `startHelperCapture` synchronously here would assign
            // `helperCapture` outside that guard, so a Stop-Sharing racing
            // this callback could leave the freshly-spawned child orphaned —
            // the stuck recording-badge bug this whole design exists to
            // prevent.
            let work = self.scheduleHelperRestart(resetCrashBudget: false)
            Task { [weak self] in
                guard let err = await work.value, let self, self.isRunning else { return }
                self.onCaptureStopped?(
                    NSError(
                        domain: "Tailscreen.HelperScreenCapture", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "respawn failed: \(err)"]))
            }
        }
        // Quality knobs travel as env vars (the framed contentFilter
        // payload stays schema-stable). Reading the session snapshot here
        // means crash-restart respawns reuse the same fps/codec — and the
        // latest live-applied bandwidth ceiling — automatically.
        var qualityEnv = sessionQuality.withLock { $0 }.helperEnvironment()
        // A viewer's 8-bit fallback request (PROFILE_NO) rides the same
        // env-var channel as the quality knobs so a crash-restart respawn
        // inherits it. The helper's `captureColorInfo` reads it to pin the
        // capture + encode to 8-bit.
        if force8bit.withLock({ $0 }) {
            qualityEnv["TAILSCREEN_FORCE_8BIT"] = "1"
        }
        try helper.start(
            filterData: filterData, forceH264: forceH264.withLock { $0 }, qualityEnv: qualityEnv)
        helperCapture = helper
        logger.log("HelperScreenCapture started (filter=\(filterData.count)B)")
    }

    private func handleHelperAccessUnit(_ avcc: Data, isKeyframe: Bool) {
        guard isRunning else { return }
        broadcast(avccData: avcc, isKeyframe: isKeyframe)
    }

    /// Called by the host (`AppState`) after the helper-process
    /// capture died mid-flight. Spawns a fresh helper on the same
    /// display, without disturbing the UDP/TCP listeners or the
    /// connected viewer set. On success, video resumes flowing and
    /// viewers recover transparently. On failure, the caller is
    /// expected to fall back to `stop()` and surface the error to
    /// the user.
    ///
    /// Note: the helper itself self-restarts up to 3 times in 30 s
    /// via `onUnexpectedExit`. This entry point is the
    /// AppState-driven recovery path that runs after that budget is
    /// exhausted (or for any other externally-observed stream
    /// death). It resets the crash budget so the user gets a fresh
    /// run of auto-restarts.
    func restartCapture() async throws {
        guard isRunning else { return }
        if let result = await scheduleHelperRestart(resetCrashBudget: true).value {
            throw result
        }
    }

    /// Retarget capture to a new `PickerSelection` without touching the
    /// UDP/TCP listeners, the viewer roster, the approval state, or the
    /// annotation back-channel. Swaps the cached selection, then rides the
    /// same tracked-restart path as `restartCapture()` — never spawning a
    /// helper directly — so it inherits both orphan-safety properties of
    /// `scheduleHelperRestart` (the `stop()` drain and the post-spawn
    /// `isRunning` re-check). The crash budget is reset: the new target
    /// deserves a fresh run of auto-restarts.
    ///
    /// A crash-triggered auto-restart racing this call is benign in either
    /// order: both funnel through `scheduleHelperRestart` (which chains
    /// restarts strictly), and `lastFilterData` already holds the new bytes.
    ///
    /// Returns `false` — without restarting anything — when the server is
    /// not running, so a caller racing a concurrent `stop()` can tell the
    /// no-op apart from a successful retarget and skip its success side
    /// effects. Throws `CancellationError` when the share stops while the
    /// restart is in flight (the restart task unwinds deliberately — the
    /// stop path owns teardown).
    ///
    /// `forceH264` is deliberately left latched (viewer decode capability
    /// didn't change with the source) and `parameterSets` / `helperCodec`
    /// are left in place — the fresh helper overwrites them, in order,
    /// before its first encoded AU broadcasts.
    func changeSource(filterData: Data) async throws -> Bool {
        guard isRunning else { return false }
        lastFilterData.withLock { $0 = filterData }
        // Keep the injector's coordinate mapping in step with the new source
        // so a live control grant keeps landing events on the right region.
        remoteControlInjector.setSelection(decodedSelection())
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
    ///      predecessor to completion. Two overlapping restarts (a crash
    ///      auto-restart racing a `changeSource`) could otherwise both
    ///      observe `helperCapture == nil`, both spawn helpers, and the
    ///      second assignment would clobber the first — orphaning a live
    ///      `--capture-helper` that keeps holding replayd's recording slot
    ///      (the stuck-badge bug).
    ///   2. `stop()` drains `restartTask` and awaits the in-flight work before
    ///      nulling `helperCapture` — the slot always holds the *newest*
    ///      restart, and awaiting it transitively drains the whole chain, so
    ///      a respawn can't finish *after* teardown unnoticed.
    ///   3. The Task re-checks `isRunning` *after* `startHelperCapture` assigns
    ///      `helperCapture` and tears the new helper back down if the share was
    ///      stopped meanwhile. This post-spawn check — not just the await — is
    ///      what prevents a Stop-Sharing that races the respawn from orphaning
    ///      a child process holding replayd's recording slot.
    ///
    /// `resetCrashBudget` clears the sliding crash-window so the AppState-driven
    /// recovery path gets a fresh run of auto-restarts; the auto-restart path
    /// passes `false` to keep counting toward the 3-in-30s cap.
    ///
    /// The slot is deliberately not cleared on completion: a finished `Task`
    /// left in `restartTask` is harmless (`stop()` awaits it and returns at
    /// once, and chaining onto it is instant), and *not* clearing avoids a
    /// clobber race where one restart nils out a slot another restart just
    /// populated.
    @discardableResult
    private func scheduleHelperRestart(resetCrashBudget: Bool) -> Task<Error?, Never> {
        // Snapshot-and-install under one lock hold (property 1 above): any
        // concurrent scheduleHelperRestart serializes on this lock, so each
        // new task chains onto its true predecessor — never onto a stale
        // snapshot taken before another restart slipped into the slot.
        return restartTask.withLock { slot in
            let previous = slot
            let work = Task { [weak self] () -> Error? in
                // Serialize restarts strictly: let the previous one finish
                // (normally, or by unwinding from a stop-induced
                // CancellationError) before touching `helperCapture`.
                _ = await previous?.value
                guard let self else { return nil }
                if let existing = self.helperCapture {
                    self.helperCapture = nil
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
                        await self.helperCapture?.stop()
                        self.helperCapture = nil
                    }
                    return error
                }
                if !self.isRunning {
                    await self.helperCapture?.stop()
                    self.helperCapture = nil
                }
                return nil
            }
            slot = work
            return work
        }
    }

    /// True when some admitted viewer's UDP source shares `ip` (the viewer
    /// keys are `ip:port`; the TCP annotation channel dials from the same
    /// tailnet IP but a different ephemeral port, so we match on IP). This
    /// is the trust anchor for the inbound-annotation gate.
    private func isAdmittedViewerIP(_ ip: String) -> Bool {
        viewers.withLock { state in state.keys.contains { ipFromAddr($0) == ip } }
    }

    /// Log a dropped (ungated) annotation at most once per share so a peer
    /// spamming the back-channel can't flood the log.
    private let droppedAnnotationLogged = OSAllocatedUnfairLock<Bool>(initialState: false)
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
    func declineControlRequest(connectionID: UUID) {
        let existed = controlRequests.withLock { $0.removeValue(forKey: connectionID) != nil }
        guard existed else { return }
        notifyControlRequestsChanged()
        sendControlRevoked(to: connectionID, reason: "request declined")
        logger.log("Declined remote-control request on \(connectionID)")
    }

    /// Grant remote control to the pending request on `connectionID`. Refuses
    /// (returns false) when the process lacks Accessibility TCC — firing
    /// `onControlAccessibilityRequired` so the UI can prompt — rather than
    /// installing a grant that `CGEventPost` would silently ignore. Granting
    /// implicitly revokes any previous grantee (single-holder invariant).
    @discardableResult
    func grantControl(toConnectionID connectionID: UUID) -> Bool {
        guard isRunning else { return false }
        guard grantBypassesAccessibilityForTesting || remoteControlInjector.isTrusted() else {
            onControlAccessibilityRequired?()
            return false
        }
        let request = controlRequests.withLock { $0.removeValue(forKey: connectionID) }
        guard let request else { return false }
        notifyControlRequestsChanged()

        // Revoke a previous grantee before installing the new one.
        let previous = controlGrant.withLock { $0 }
        if let previous, previous.connectionID != connectionID {
            sendControlRevoked(to: previous.connectionID, reason: "granted to another viewer")
        }

        let stableID = peerStableIDCache.withLock { $0[request.viewerIP] }
        let grant = ControlGrant(
            connectionID: connectionID, viewerIP: request.viewerIP, stableID: stableID,
            hostname: request.hostname, grantedAt: Date())
        controlGrant.withLock { $0 = grant }
        droppedInputLogged.withLock { $0 = false }
        remoteControlInjector.reset()
        remoteControlInjector.setSelection(decodedSelection())
        Task { [weak self] in
            await self?.controlListener?.send(.controlGranted, to: connectionID)
        }
        logger.log("Granted remote control to \(request.viewerIP)")
        notifyControlGrantChanged()
        return true
    }

    /// Revoke the live grant (if any): tell the grantee, drop any queued
    /// input, and clear the sharer UI. `reason` is a short English tag for
    /// logs — the viewer shows its own localized message.
    func revokeControl(reason: String) {
        let previous = controlGrant.withLock { grant -> ControlGrant? in
            let value = grant
            grant = nil
            return value
        }
        guard let previous else { return }
        remoteControlInjector.reset()
        sendControlRevoked(to: previous.connectionID, reason: reason)
        logger.log("Revoked remote control from \(previous.viewerIP) (\(reason))")
        notifyControlGrantChanged()
    }

    /// Revoke the grant only when `connectionID` holds it. Used by the
    /// connection-close hook (the reliable auto-revoke-on-disconnect signal).
    private func revokeControlIfHeld(byConnection connectionID: UUID, reason: String) {
        let held = controlGrant.withLock { $0?.connectionID == connectionID }
        if held { revokeControl(reason: reason) }
    }

    /// Revoke the grant only when the peer at `ip` holds it. Belt-and-braces
    /// for the UDP-side disconnect signals (BYE / idle sweep / expel), which
    /// don't carry the TCP connection UUID.
    private func revokeControlIfHeld(byIP ip: String, reason: String) {
        let held = controlGrant.withLock { $0?.viewerIP == ip }
        if held { revokeControl(reason: reason) }
    }

    private func sendControlRevoked(to connectionID: UUID, reason: String) {
        Task { [weak self] in
            await self?.controlListener?.send(.controlRevoked(reason: reason), to: connectionID)
        }
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
        let info = controlGrant.withLock { grant -> ControlGrantInfo? in
            guard let grant else { return nil }
            return ControlGrantInfo(
                connectionID: grant.connectionID, viewerIP: grant.viewerIP, hostname: grant.hostname)
        }
        cb(info)
    }

    /// Wire annotation + connection-close callbacks onto the
    /// `TailscreenControlListener`. The listener handles the framed-TCP
    /// accept loop and dispatch; we only see decoded
    /// `ScreenShareMessage.annotation` ops and per-connection close
    /// notifications here.
    private func installControlHandlers() {
        guard let listener = controlListener else { return }
        listener.onAnnotation = { [weak self] op, connectionID, peerAddress in
            guard let self else { return }
            // Gate: the TCP back-channel accepts a connection from any peer
            // that can dial port 7447, so an annotation op is only honoured
            // when its connection's peer IP belongs to an ADMITTED viewer
            // (present in `viewers`). A pending/denied/blocked/expelled peer
            // is not in that set, so its ops are dropped — never applied to
            // the sharer's overlay and never fanned out.
            let peerIP = peerAddress.map { self.ipFromAddr($0) }
            guard let peerIP, self.isAdmittedViewerIP(peerIP) else {
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
            self.trackAnnotationOp(op, connectionID: connectionID)
            self.onAnnotationReceived?(op)
            // Fan out to every OTHER viewer so window / application share
            // modes can carry annotations peer-to-peer instead of relying
            // on SCStream catching the sharer's overlay panel.
            Task { [weak self] in
                await self?.broadcastAnnotation(op, excludingConnection: connectionID)
            }
        }
        listener.onControlRequest = { [weak self] connectionID, peerAddress in
            guard let self else { return }
            // Only an admitted viewer may even ask for control — the TCP
            // channel accepts a dial from any peer, so gate on the same
            // admitted-viewer-IP anchor the annotation path uses.
            let peerIP = peerAddress.map { self.ipFromAddr($0) }
            guard let peerIP, self.isAdmittedViewerIP(peerIP) else {
                self.logger.log("Dropped control request from non-admitted peer \(peerAddress ?? "unknown")")
                return
            }
            self.recordControlRequest(connectionID: connectionID, ip: peerIP)
        }
        listener.onInputEvent = { [weak self] event, connectionID, _ in
            guard let self else { return }
            // Authoritative gate: inject only from the current grantee's
            // connection. Everything else is dropped and counted.
            let grant = self.controlGrant.withLock { $0 }
            guard RemoteControlPolicy.shouldInject(grant: grant, connectionID: connectionID) else {
                self.logDroppedInput()
                return
            }
            // Hard per-share rate ceiling on top of the viewer-side throttle.
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let allowed = self.inputRateLimiter.withLock { $0.allow(nowNs: nowNs) }
            guard allowed else { return }
            self.onInputEventForTesting?(event)
            self.remoteControlInjector.apply(event)
        }
        listener.onConnectionClosed = { [weak self] connectionID in
            guard let self else { return }
            self.annotationConnectionIP.withLock { _ = $0.removeValue(forKey: connectionID) }
            // A closed connection can't hold a grant or a pending request.
            self.removeControlRequest(connectionID: connectionID)
            self.revokeControlIfHeld(byConnection: connectionID, reason: "viewer disconnected")
            let outstanding = self.annotationsByConnection.withLock {
                $0.removeValue(forKey: connectionID) ?? []
            }
            guard !outstanding.isEmpty else { return }
            // Fire `.undo` for every UUID this viewer was on the hook for
            // so their strokes don't outlive them — both on the sharer's
            // local overlay (via `onAnnotationReceived`) and on every
            // other viewer's overlay (via `broadcastAnnotation`).
            let cb = self.onAnnotationReceived
            for uuid in outstanding {
                let op: AnnotationOp = .undo(uuid)
                cb?(op)
                Task { [weak self] in
                    await self?.broadcastAnnotation(op, excludingConnection: connectionID)
                }
            }
        }
    }

    /// Detach this share's annotation handlers from the shared control
    /// listener so a subsequent share (or just request-to-share traffic)
    /// can attach its own without observing this share's stale closures.
    /// `onRequestToShare` is owned by AppState and intentionally untouched.
    private func uninstallControlHandlers() {
        controlListener?.onAnnotation = nil
        controlListener?.onConnectionClosed = nil
        controlListener?.onControlRequest = nil
        controlListener?.onInputEvent = nil
    }

    /// Broadcast a framed `AnnotationOp` to every connection on the shared
    /// control listener, optionally skipping the one that originated the op
    /// (to avoid echoing a viewer's stroke back to them). Used both for
    /// sharer-painted strokes (no exclusion — sharer has no annotation
    /// connection) and viewer-to-viewer fan-out (exclude the source).
    func broadcastAnnotation(_ op: AnnotationOp, excludingConnection: UUID? = nil) async {
        // A `.clearAll` wipes every stroke on every canvas — regardless of
        // who originated it (the server's own "Change Source…" broadcast,
        // the sharer's Clear All, or a viewer's fanned-out op). Retire every
        // per-connection tracked UUID with it: leaving them tracked would
        // replay spurious `.undo`s for already-cleared strokes on a later
        // viewer disconnect, and via the sharer's `onAnnotationReceived` →
        // `ensureSharerOverlay` those replays resurrect an already-torn-down
        // sharer overlay. Same lock discipline as the inbound
        // `trackAnnotationOp` path; keys stay (connections are still alive),
        // only the tracked sets empty out.
        if case .clearAll = op {
            annotationsByConnection.withLock { state in
                state = state.mapValues { _ in [] }
            }
        }
        await controlListener?.broadcast(.annotation(op), excluding: excludingConnection)
    }

    /// Update the per-connection annotation-UUID set in response to an
    /// inbound op. `.add` registers the UUID (idempotent for mid-drag
    /// progressive updates that share an id), `.undo` retires it (already
    /// removed on the canvas — no need to redo on disconnect), and
    /// `.clearAll` wipes the set (the viewer asked everyone to clear, so
    /// they have nothing left to undo on the way out).
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

    /// `NSError` domain marking a dead UDP receive loop. AppState treats
    /// this domain as non-recoverable: respawning the capture helper can't
    /// fix a socket loop that can no longer read, so it goes straight to
    /// `stopSharing` instead of the capture-restart path.
    static let receiveLoopErrorDomain = "Tailscreen.ReceiveLoop"

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
    /// RTP packets shouldn't arrive at the server; if they do (a confused
    /// client), they're dropped — we identify them by V=2 in byte 0.
    ///
    /// A non-timeout receive error used to kill this loop permanently, which
    /// silently killed joins/keepalives/PLIs/viewer audio while the share
    /// still looked active to the sharer. Each error now retries after a
    /// capped exponential backoff (`ReceiveLoopPolicy`); a run of
    /// `maxConsecutiveErrors` — or `maxErrorsPerWindow` inside the trailing
    /// window, for a flapping socket whose errors interleave with timeouts —
    /// means the socket is genuinely dead, and the share is torn down through
    /// `onCaptureStopped`. A share whose control loop can't read is
    /// unrecoverable.
    ///
    /// `TailscaleError.readFailed` is ambiguous: the benign 1 s poll timeout
    /// and a dead fd (POLLHUP → instant return) both surface as it. Treating
    /// every `readFailed` as a timeout let a dead socket busy-spin with the
    /// error counter permanently reset, so the give-up ladder was
    /// unreachable — the elapsed-time classification below tells them apart.
    private func receiveControlLoop() async {
        guard let pl = packetListener else { return }
        var consecutiveErrors = 0
        var errorStampsNs: [UInt64] = []
        while isRunning {
            let recvStartNs = DispatchTime.now().uptimeNanoseconds
            do {
                let (data, from) = try await pl.recv(timeout: 1_000)
                consecutiveErrors = 0
                handleIncoming(data: data, from: from)
            } catch {
                guard isRunning else { break }
                if case TailscaleError.readFailed = error {
                    let elapsedNs = DispatchTime.now().uptimeNanoseconds &- recvStartNs
                    if !ReceiveLoopPolicy.classifyReadFailedAsError(elapsedNs: elapsedNs) {
                        consecutiveErrors = 0
                        continue  // poll timeout, just keep polling
                    }
                    // Near-instant readFailed = dead fd; fall through and
                    // count it like any other receive error.
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
                    logger.log("Server: receive loop dead (\(detail)) — stopping share")
                    onCaptureStopped?(Self.receiveLoopDeadError(underlying: error))
                    break
                }
                try? await Task.sleep(
                    nanoseconds: ReceiveLoopPolicy.retryDelayNs(consecutiveErrors: consecutiveErrors))
            }
        }
    }

    private func handleIncoming(data: Data, from addr: String) {
        guard !data.isEmpty else { return }
        if !ScreenShareControlMessage.looksLikeControl(data) {
            // RTP from a viewer is only allowed for audio (PT=98). Anything
            // else (video PTs) is dropped.
            if let (header, _) = RTPHeader.decode(from: data),
                header.payloadType == RTPHeader.aacPayloadType
            {
                handleInboundAudioRTP(data, header: header, from: addr)
            }
            return
        }
        guard let kind = ScreenShareControlMessage.decode(data) else { return }

        switch kind {
        case .hello:
            // Re-ack on every HELLO, not just first registration. A viewer
            // that lost its assigned SSRC (process restart, NAT rebind that
            // changes our `addr` for it) must receive the ack again to send
            // audio. registerOrRefresh always populates `audioSSRC`, so the
            // lookup never fails for a known viewer.
            //
            // Pending viewers never get an ack — the sharer hasn't said
            // yes yet, and silence keeps the viewer parked at "Connecting…"
            // until `approveViewer` or `denyViewer` resolves them.
            registerOrRefresh(addr: addr, isNew: true)
            if let assignedSSRC = (viewers.withLock { $0[addr]?.audioSSRC }) {
                Task { [weak self] in
                    guard let pl = self?.packetListener else { return }
                    let ack = ScreenShareControlMessage.encodeHelloAck(ssrc: assignedSSRC)
                    try? await pl.send(ack, to: addr)
                }
            } else if (pendingViewers.withLock { $0[addr] != nil }) {
                // Parked behind the approval gate. Echo HELLO_PENDING so
                // the viewer can flip its UI from "Connecting…" to
                // "Waiting for approval"; resend on every HELLO retry in
                // case an earlier one was lost on the UDP path.
                Task { [weak self] in
                    guard let pl = self?.packetListener else { return }
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
        }
    }

    /// A viewer reported it can't decode the current codec. Latch the share
    /// to H.264 and respawn the helper so the encoder switches over. Idempotent
    /// via the `forceH264` latch: once we've fallen back, a storm of CODEC_NO
    /// from a still-black-screened viewer triggers at most one restart, and
    /// further reports (including from other viewers) are no-ops. If we're
    /// already encoding H.264 the respawn is harmless but pointless, so the
    /// latch also short-circuits the already-fell-back case.
    private func handleCodecUnsupported(from addr: String) {
        guard isRunning else { return }
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

    /// A viewer reported it can decode the codec but not its bit depth (a
    /// 10-bit HEVC Main 10 stream on 8-bit-only decode hardware). Latch the
    /// share to 8-bit and respawn the helper so the encoder drops to Main.
    /// Idempotent via the `force8bit` latch, exactly like
    /// `handleCodecUnsupported`: a storm of PROFILE_NO from a still-stuck
    /// viewer triggers at most one restart. If we're already encoding 8-bit
    /// the latch short-circuits the pointless respawn.
    private func handleProfileUnsupported(from addr: String) {
        guard isRunning else { return }
        let shouldFallback = force8bit.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard shouldFallback else { return }
        logger.log("Viewer \(addr) can't decode the current bit depth — falling back to 8-bit")
        Task { [weak self] in
            try? await self?.restartCapture()
        }
    }

    /// Pure inbound-audio relay decision. The sender must be a registered
    /// viewer AND the embedded SSRC must match the one we assigned to that
    /// address — without the SSRC check, a registered viewer could spoof
    /// another viewer's audio by stuffing its SSRC into the RTP header. On
    /// success, returns every *other* viewer as a relay recipient. Extracted
    /// from `handleInboundAudioRTP` so the anti-spoof gate is unit testable.
    static func audioRelayDecision(
        viewerAudioSSRCs: [String: UInt32],
        sender: String,
        headerSSRC: UInt32
    ) -> (valid: Bool, recipients: [String]) {
        guard let assigned = viewerAudioSSRCs[sender], assigned == headerSSRC else {
            return (false, [])
        }
        return (true, viewerAudioSSRCs.keys.filter { $0 != sender })
    }

    /// Relay one inbound audio RTP packet to all other viewers and pass
    /// a copy to the local VoiceChannel via `onAudioReceived`. The packet
    /// is forwarded byte-for-byte (no transcode) so the receiving viewer
    /// sees the original sender's SSRC.
    private func handleInboundAudioRTP(_ packet: Data, header: RTPHeader, from sender: String) {
        let validated = viewers.withLock { state in
            Self.audioRelayDecision(
                viewerAudioSSRCs: state.mapValues { $0.audioSSRC },
                sender: sender,
                headerSSRC: header.ssrc
            )
        }
        guard validated.valid else { return }
        if !validated.recipients.isEmpty, let pl = packetListener {
            let recipients = validated.recipients
            let prev = audioBroadcastTail.withLock { $0 }
            let job = Task {
                await prev?.value
                for addr in recipients {
                    try? await pl.send(packet, to: addr)
                }
            }
            audioBroadcastTail.withLock { $0 = job }
        }
        onAudioReceived?(packet)
    }

    /// Pure PLI-ring append: add `timestampNs` and drop the oldest entries
    /// once the ring exceeds `cap`. Extracted from `recordPLI` so the
    /// bounded-growth invariant is unit testable.
    static func appendingPLI(_ ring: [UInt64], timestampNs: UInt64, cap: Int = 32) -> [UInt64] {
        var out = ring
        out.append(timestampNs)
        if out.count > cap {
            out.removeFirst(out.count - cap)
        }
        return out
    }

    /// Append a PLI timestamp to the viewer's ring. The adaptive sweep
    /// (every 5 s) reads these to decide whether to step bitrate down.
    /// Drop the oldest entry once we hold more than 32 — at our
    /// recovery cadence (PLI per missing AU, capped by the encoder's
    /// keyframe production rate) this is comfortably more than a 5 s
    /// window can ever observe.
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

    /// What to do with a not-yet-connected viewer's HELLO.
    enum Admission: Equatable {
        /// Join the fan-out set immediately (remembered allow, or gate off).
        case admit
        /// Park in `pendingViewers` awaiting the sharer's Accept / Deny.
        case park
        /// Reject outright (remembered deny) — HELLO_DENY + SERVER_BYE.
        case reject
    }

    /// Pure admission gate: remembered `deny` always rejects (a blocked
    /// peer stays blocked even in open-door mode), remembered `allow`
    /// always admits, and an unremembered peer parks behind the approval
    /// gate when it's on. Extracted so the precedence
    /// (blocklist > allowlist > gate) is unit testable — same pattern as
    /// `audioRelayDecision`.
    static func admissionDecision(policy: PeerPolicy?, requireApproval: Bool) -> Admission {
        switch policy {
        case .deny:
            return .reject
        case .allow:
            return .admit
        case nil:
            return requireApproval ? .park : .admit
        }
    }

    /// Pure drain decision for `setRequireApproval(false)`: everyone parked
    /// pending gets admitted *except* remembered-deny peers, who are denied
    /// instead. Peers whose StableNodeID never resolved (`nil`) can't match
    /// a policy and are admitted — the post-resolution deny check in
    /// `applyResolvedIdentity` still expels them if they turn out to be
    /// blocked. Results are sorted for determinism.
    static func drainDecision(
        pendingStableIDs: [String: String?],
        policies: [String: PeerPolicy]
    ) -> (approve: [String], deny: [String]) {
        var approve: [String] = []
        var deny: [String] = []
        for (addr, stableID) in pendingStableIDs {
            let policy = stableID.flatMap { policies[$0] }
            if policy == .deny {
                deny.append(addr)
            } else {
                approve.append(addr)
            }
        }
        return (approve.sorted(), deny.sorted())
    }

    /// Pure connected-roster deny sweep: which currently-connected
    /// addresses now resolve to a remembered `deny`? Used by
    /// `setAccessPolicies` so a "Deny & Block" applied to an
    /// already-connected peer expels it instead of only blocking future
    /// HELLOs. Unresolved (`nil`) StableNodeIDs can't match a policy and
    /// are left alone. Sorted for determinism.
    static func connectedDenyList(
        viewerStableIDs: [String: String?],
        policies: [String: PeerPolicy]
    ) -> [String] {
        viewerStableIDs.compactMap { (addr, stableID) -> String? in
            guard let stableID, policies[stableID] == .deny else { return nil }
            return addr
        }.sorted()
    }

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

        let approvalRequired = requireApproval.withLock { $0 }
        let alreadyKnown = viewers.withLock { $0[addr] != nil }
        let ip = ipFromAddr(addr)

        // Consult the remembered allow/deny policy when this IP's
        // StableNodeID is already cached (a re-HELLO from a peer we've
        // resolved before). A fresh peer has no cached ID yet — it goes
        // through the async LocalAPI resolution below, and the policy is
        // applied post-resolution instead. Note remembered `deny` rejects
        // even in open-door mode: "Deny & block" outranks the gate.
        // One code path through the unit-tested gate: a fresh peer with a
        // cached StableNodeID applies its remembered policy synchronously;
        // an unknown/uncached peer passes `nil` policy, so `admissionDecision`
        // degrades to the plain approval gate. An already-known viewer isn't
        // subject to admission — it just refreshes below.
        let cachedStableID = alreadyKnown ? nil : peerStableIDCache.withLock({ $0[ip] })
        let cachedPolicy = cachedStableID.flatMap { id in accessPolicies.withLock { $0[id] } }
        var admission = Self.admissionDecision(policy: cachedPolicy, requireApproval: approvalRequired)
        // A one-time pre-approval (from accepting this peer's request-to-share)
        // admits it straight away — but never overrides a remembered deny.
        if !alreadyKnown && admission != .reject {
            let preApproved = preApprovedIPs.withLock { $0.remove(ip) != nil }
            if preApproved { admission = .admit }
        }
        if !alreadyKnown && admission == .reject {
            logger.log("Viewer \(addr) rejected (remembered deny)")
            sendDenialDatagrams(to: addr)
            return
        }

        // Brand new addr that has to wait for the sharer: park in pending
        // and surface to the UI. We allocate the audio SSRC up front so the
        // eventual HELLO_ACK (after Accept) can reuse it without an extra
        // hop. The collision check only spans other pending viewers —
        // the connected set's SSRC space is 2^32, so a cross-set clash
        // is astronomically unlikely, and the audio-validation check is
        // keyed by source address anyway.
        if admission == .park && !alreadyKnown {
            // Cap the pending set so a flood of spoofed HELLO source
            // addresses can't exhaust memory or amplify LocalAPI resolves.
            // Drop the HELLO (logged once) when full and this addr is new.
            let accepted = pendingViewers.withLock { state -> Bool in
                guard Self.canAcceptPending(currentCount: state.count, isExisting: state[addr] != nil) else {
                    return false
                }
                var ssrc: UInt32
                repeat {
                    ssrc = UInt32.random(in: 1...UInt32.max)
                } while state.values.contains(where: { $0.audioSSRC == ssrc })
                state[addr] = PendingViewer(addr: addr, audioSSRC: ssrc, lastSeenNs: now)
                return true
            }
            guard accepted else {
                logPendingCapReached(addr: addr)
                return
            }
            let cachedName = peerNameCache.withLock { $0[ip] }
            let cachedStableID = peerStableIDCache.withLock { $0[ip] }
            let info = PendingViewerInfo(
                id: addr, tailscaleIP: ip, hostname: cachedName, stableID: cachedStableID,
                arrivedAt: Date())
            pendingViewerInfos.withLock { $0[addr] = info }
            logger.log("Viewer pending approval \(addr)")
            notifyPendingViewersChanged()
            if cachedName == nil || cachedStableID == nil {
                scheduleIdentityResolve()
            }
            // Close the toggle-off race: if `setRequireApproval(false)`
            // ran and drained the pending queue between our gate read and
            // this insert, the toggle's drain didn't see us. Re-read and
            // self-promote (via the same admission gate, so a remembered
            // deny still wins) so the new viewer isn't stranded waiting on
            // a sharer who already opted into open-door mode.
            if !requireApproval.withLock({ $0 }) {
                applyRememberedPolicyToPending(addr: addr, stableID: cachedStableID)
            }
            return
        }

        let (added, viewerCount, audioSSRC) = viewers.withLock { state -> (Bool, Int, UInt32) in
            if var existing = state[addr] {
                existing.lastSeenNs = now
                state[addr] = existing
                return (false, state.count, existing.audioSSRC)
            }
            var newAudioSSRC: UInt32
            repeat {
                newAudioSSRC = UInt32.random(in: 1...UInt32.max)
            } while state.values.contains(where: { $0.audioSSRC == newAudioSSRC })
            let v = Viewer(
                addr: addr,
                ssrc: UInt32.random(in: 1...UInt32.max),
                audioSSRC: newAudioSSRC,
                nextSequence: UInt16.random(in: 0...UInt16.max),
                lastSeenNs: now
            )
            state[addr] = v
            return (true, state.count, newAudioSSRC)
        }

        if added {
            // Proactively ACK any newly-added viewer with its audio SSRC —
            // including one whose source address changed under a NAT/DERP path
            // migration and re-registered via KEEPALIVE rather than a fresh
            // HELLO. Without this the rebound viewer never learns the new SSRC
            // the server just assigned, so the SSRC-validation check silently
            // drops its mic audio until a full reconnect. A normal HELLO join
            // also gets the .hello case's ACK; the duplicate is idempotent
            // (the viewer ignores an ACK that matches its current SSRC).
            let ssrc = audioSSRC
            Task { [weak self] in
                guard let pl = self?.packetListener else { return }
                try? await pl.send(ScreenShareControlMessage.encodeHelloAck(ssrc: ssrc), to: addr)
            }
            publishAddedViewer(addr: addr)
        }

        if added || isNew {
            logger.log("Viewer \(added ? "joined" : "refreshed") \(addr) (total=\(viewerCount))")
            // New viewer (or one that re-helloed): force a keyframe so
            // they get something decodable immediately. We also push the
            // last cached SPS/PPS in-band on the next IDR; that's handled
            // by `broadcast(avccData:isKeyframe:)`.
            helperCapture?.requestKeyframe()
        }
    }

    /// Toggle the per-session approval gate. Called by AppState when the
    /// user flips the "Require approval for new viewers" toggle; safe to
    /// call before, during, or after `start()`. Turning the toggle off
    /// auto-approves anyone currently waiting.
    func setRequireApproval(_ enabled: Bool) {
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
            let pendingStableIDs = pendingViewerInfos.withLock { state in
                state.mapValues { $0.stableID }
            }
            let policies = accessPolicies.withLock { $0 }
            let decision = Self.drainDecision(pendingStableIDs: pendingStableIDs, policies: policies)
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
    func setAccessPolicies(_ policies: [String: PeerPolicy]) {
        accessPolicies.withLock { $0 = policies }
        let resolved = pendingViewerInfos.withLock { state in
            state.compactMap { (addr, info) in info.stableID.map { (addr, $0) } }
        }
        for (addr, stableID) in resolved {
            applyRememberedPolicyToPending(addr: addr, stableID: stableID)
        }
        // Sweep the CONNECTED roster too: a "Deny & Block" applied to an
        // already-connected peer must expel it here, not merely block its
        // future HELLOs (which never come — it's already in the fan-out).
        let connectedStableIDs = viewerInfos.withLock { state in
            state.mapValues { $0.stableID }
        }
        for addr in Self.connectedDenyList(viewerStableIDs: connectedStableIDs, policies: policies) {
            logger.log("Expelling connected viewer \(addr): policy changed to deny")
            expelViewer(addr: addr)
        }
    }

    /// One-time pre-approve a peer by IP so its next HELLO joins the
    /// fan-out immediately, bypassing the approval gate — but NOT a
    /// remembered `deny` (a blocked peer stays blocked). Called after the
    /// sharer accepts that peer's request-to-share, so their connect doesn't
    /// hit a second consent prompt.
    func preApproveViewer(ip: String) {
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
        switch Self.admissionDecision(policy: policy, requireApproval: gate) {
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

    /// Seed, insert, and publish a freshly-added connected viewer's
    /// `ViewerInfo` from the identity caches, then kick the shared resolver
    /// if either the hostname or StableNodeID is still uncached. Shared by
    /// `registerOrRefresh`'s add path and `approveViewer` so the
    /// build → insert → notify → resolve-if-uncached shape lives once.
    private func publishAddedViewer(addr: String) {
        let ip = ipFromAddr(addr)
        let cachedName = peerNameCache.withLock { $0[ip] }
        let cachedStableID = peerStableIDCache.withLock { $0[ip] }
        let info = ViewerInfo(
            id: addr,
            tailscaleIP: ip,
            hostname: cachedName,
            stableID: cachedStableID,
            connectedAt: Date()
        )
        viewerInfos.withLock { $0[addr] = info }
        notifyViewersChanged()
        if cachedName == nil || cachedStableID == nil {
            scheduleIdentityResolve()
        }
    }

    /// Move a pending viewer into the active set: emit the HELLO_ACK
    /// we suppressed at HELLO time, force a keyframe, and surface them
    /// in the connected-viewer roster. Safe to call for a viewer who's
    /// already approved (no-op).
    func approveViewer(addr: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        let pending = pendingViewers.withLock { state -> PendingViewer? in
            state.removeValue(forKey: addr)
        }
        pendingViewerInfos.withLock { _ = $0.removeValue(forKey: addr) }
        notifyPendingViewersChanged()
        guard let pending else { return }

        let (added, viewerCount) = viewers.withLock { state -> (Bool, Int) in
            if state[addr] != nil { return (false, state.count) }
            let v = Viewer(
                addr: pending.addr,
                ssrc: UInt32.random(in: 1...UInt32.max),
                audioSSRC: pending.audioSSRC,
                nextSequence: UInt16.random(in: 0...UInt16.max),
                lastSeenNs: now
            )
            state[addr] = v
            return (true, state.count)
        }
        if added {
            publishAddedViewer(addr: addr)
        }
        logger.log("Viewer approved \(addr) (total=\(viewerCount))")
        // Send the deferred HELLO_ACK and request a keyframe so video
        // starts flowing on the next encoded AU.
        let ack = ScreenShareControlMessage.encodeHelloAck(ssrc: pending.audioSSRC)
        Task { [weak self] in
            guard let pl = self?.packetListener else { return }
            try? await pl.send(ack, to: addr)
        }
        helperCapture?.requestKeyframe()
    }

    /// Reject a pending viewer: send HELLO_DENY + SERVER_BYE so they tear
    /// down immediately (and can tell "declined" from "sharer stopped"),
    /// and drop them from the pending set. Safe to call for an unknown
    /// addr (no-op).
    func denyViewer(addr: String) {
        let existed = pendingViewers.withLock { state -> Bool in
            state.removeValue(forKey: addr) != nil
        }
        guard existed else { return }
        pendingViewerInfos.withLock { _ = $0.removeValue(forKey: addr) }
        notifyPendingViewersChanged()
        logger.log("Viewer denied \(addr)")
        sendDenialDatagrams(to: addr)
    }

    /// Kick an already-connected viewer that turned out to be blocked —
    /// open-door mode admits on HELLO before the async StableNodeID
    /// resolution completes, so a remembered-deny peer can briefly join
    /// before this pulls them back out. No-op for unknown addrs.
    private func expelViewer(addr: String) {
        let removed = viewers.withLock { state -> Bool in
            state.removeValue(forKey: addr) != nil
        }
        guard removed else { return }
        viewerInfos.withLock { _ = $0.removeValue(forKey: addr) }
        // Symmetric teardown: drop the per-viewer video send chain (a
        // lingering chain would keep addressing the kicked peer) and sever
        // the TCP annotation back-channel keyed by IP, so a blocked peer
        // loses annotation access along with its video (composes with the
        // inbound-annotation gate). Closing the connection makes the listener
        // fire onConnectionClosed, which retires the peer's tracked strokes.
        videoSendTails.withLock { _ = $0.removeValue(forKey: addr) }
        closeAnnotationChannels(forIP: ipFromAddr(addr))
        revokeControlIfHeld(byIP: ipFromAddr(addr), reason: "viewer blocked")
        notifyViewersChanged()
        logger.log("Viewer expelled (remembered deny) \(addr)")
        sendDenialDatagrams(to: addr)
    }

    /// Close every TCP annotation connection whose peer dialed from `ip`.
    /// The listener's close path fires `onConnectionClosed`, which clears the
    /// per-connection tracking maps and emits the `.undo`s that make the
    /// peer's strokes vanish from every overlay.
    private func closeAnnotationChannels(forIP ip: String) {
        let connectionIDs = annotationConnectionIP.withLock { state in
            state.filter { $0.value == ip }.map { $0.key }
        }
        guard !connectionIDs.isEmpty, let listener = controlListener else { return }
        Task {
            for id in connectionIDs { await listener.close(connectionID: id) }
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
            guard let pl = self?.packetListener else { return }
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
            pendingViewerInfos.withLock { _ = $0.removeValue(forKey: addr) }
            notifyPendingViewersChanged()
            logger.log("Pending viewer disconnected \(addr)")
        }
    }

    private func removeViewer(addr: String) {
        let removed = viewers.withLock { state -> Bool in
            state.removeValue(forKey: addr) != nil
        }
        if removed {
            viewerInfos.withLock { _ = $0.removeValue(forKey: addr) }
            notifyViewersChanged()
            // A viewer that BYE'd/left surrenders any control grant. The TCP
            // close usually beats this via `revokeControlIfHeld(byConnection:)`;
            // this covers a UDP BYE that outruns the TCP FIN.
            revokeControlIfHeld(byIP: ipFromAddr(addr), reason: "viewer disconnected")
            logger.log("Viewer disconnected \(addr)")
        }
    }

    /// Snapshot the current roster (sorted by connection time so the UI
    /// list is stable) and hand it to `onViewersChanged`. Cheap enough to
    /// call on every join/leave — the lock window is tiny and the roster
    /// is at most a handful of entries.
    private func notifyViewersChanged() {
        guard let cb = onViewersChanged else { return }
        let snapshot = viewerInfos.withLock { state -> [ViewerInfo] in
            state.values.sorted { $0.connectedAt < $1.connectedAt }
        }
        cb(snapshot)
    }

    /// Mirror of `notifyViewersChanged` for the pending-approval set.
    private func notifyPendingViewersChanged() {
        guard let cb = onPendingViewersChanged else { return }
        let snapshot = pendingViewerInfos.withLock { state -> [PendingViewerInfo] in
            state.values.sorted { $0.arrivedAt < $1.arrivedAt }
        }
        cb(snapshot)
    }

    /// Strip the trailing `:port` from a UDP source address. Splits on the
    /// last `:` so IPv6 literals like `[fd7a::1]:54321` stay intact (the
    /// brackets get included in the IP part — fine, the netmap match
    /// handles both forms via prefix comparison).
    private func ipFromAddr(_ addr: String) -> String {
        guard let lastColon = addr.lastIndex(of: ":") else { return addr }
        var ip = String(addr[..<lastColon])
        if ip.hasPrefix("["), ip.hasSuffix("]") {
            ip = String(ip.dropFirst().dropLast())
        }
        return ip
    }

    /// How many times the shared resolver re-queries LocalAPI before giving
    /// up, one second apart. A freshly-joined (e.g. ephemeral) peer can
    /// HELLO before its entry lands in our netmap snapshot; a couple of
    /// retries turn that race from "row stays IP-only and the remembered
    /// policy never applies" into a short delay.
    private static let peerResolveAttempts = 5

    /// Coordinates the single shared identity resolver. Every park/join with
    /// an uncached identity coalesces onto ONE in-flight loop that resolves
    /// all outstanding addrs from a single `backendStatus` snapshot per tick,
    /// instead of N independent LocalAPI fetches × 5 retries — the amplifier
    /// a HELLO flood could otherwise drive against the local API. `requested`
    /// is bumped on every schedule call so a park that lands mid-pass can't be
    /// missed: the runner re-loops whenever the generation advanced during a
    /// pass (a genuinely-unresolvable peer doesn't bump it, so it can't spin).
    private let resolveGeneration =
        OSAllocatedUnfairLock<(running: Bool, requested: UInt64)>(initialState: (false, 0))

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

    /// Run resolve passes until no new schedule request arrived during a pass.
    /// Each pass caps its own retries (`resolveIdentitiesLoop`), so an
    /// unresolvable peer can't spin the runner — only fresh `scheduleIdentityResolve`
    /// calls (new parks/joins) advance the generation and keep it looping.
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

    /// One shared resolve loop. Each tick, snapshot every addr still missing
    /// a hostname or StableNodeID (pending + connected), fetch ONE
    /// `backendStatus`, and apply the results to all of them — so a burst of
    /// joins costs one LocalAPI call, not one per viewer. Retries up to
    /// `peerResolveAttempts` times (1 s apart) only for addrs not yet in the
    /// netmap snapshot; returns as soon as every outstanding addr was found.
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

    /// Addrs (pending + connected) still awaiting a hostname or StableNodeID,
    /// mapped to the tailnet IP the resolver should look them up by. An addr
    /// is never in both sets at once (approve moves it), so a plain merge is
    /// safe.
    private func outstandingResolveTargets() -> [String: String] {
        // Each `withLock` closure is `@Sendable`, so it can't mutate a
        // captured outer var — collect inside and merge the returned maps.
        let pending = pendingViewerInfos.withLock { state -> [String: String] in
            var m: [String: String] = [:]
            for (addr, info) in state where info.hostname == nil || info.stableID == nil {
                m[addr] = info.tailscaleIP
            }
            return m
        }
        let connected = viewerInfos.withLock { state -> [String: String] in
            var m: [String: String] = [:]
            for (addr, info) in state where info.hostname == nil || info.stableID == nil {
                m[addr] = info.tailscaleIP
            }
            return m
        }
        var out = pending
        out.merge(connected) { _, new in new }
        return out
    }

    /// One LocalAPI netmap fetch → IP → (hostname, StableNodeID) for every
    /// peer address in the snapshot. `PeerStatus.ID` is the string
    /// StableNodeID — distinct from the netmap's numeric node ID, see the
    /// note at `TailscalePeerDiscovery.mergeKey`. nil on LocalAPI failure so
    /// the caller retries.
    /// An empty map means "couldn't fetch" — the caller treats that the same
    /// as "no outstanding addr resolved this tick" and retries, so there's no
    /// need to distinguish it from a genuinely peerless netmap with an
    /// optional.
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
    /// holds `addr` — pending or connected — notify the UI on change, and
    /// apply the remembered policy: a parked viewer runs the admission gate
    /// (remembered-allow auto-admits, remembered-deny is denied), a connected
    /// viewer that turns out to be remembered-deny is expelled (open-door
    /// mode admits before resolution completes).
    private func applyResolvedIdentity(addr: String, hostname: String?, stableID: String?) {
        let hostnameUsable = hostname.map { !$0.isEmpty } ?? false

        let pendingPresent = pendingViewerInfos.withLock { state -> (present: Bool, changed: Bool) in
            guard var info = state[addr] else { return (false, false) }
            var changed = false
            if let hostname, hostnameUsable, info.hostname != hostname {
                info.hostname = hostname
                changed = true
            }
            if let stableID, info.stableID != stableID {
                info.stableID = stableID
                changed = true
            }
            state[addr] = info
            return (true, changed)
        }
        if pendingPresent.present {
            if pendingPresent.changed { notifyPendingViewersChanged() }
            if let stableID { applyRememberedPolicyToPending(addr: addr, stableID: stableID) }
            return
        }

        let connectedPresent = viewerInfos.withLock { state -> (present: Bool, changed: Bool) in
            guard var info = state[addr] else { return (false, false) }
            var changed = false
            if let hostname, hostnameUsable, info.hostname != hostname {
                info.hostname = hostname
                changed = true
            }
            if let stableID, info.stableID != stableID {
                info.stableID = stableID
                changed = true
            }
            state[addr] = info
            return (true, changed)
        }
        guard connectedPresent.present else { return }
        if connectedPresent.changed { notifyViewersChanged() }
        let policy = stableID.flatMap { id in accessPolicies.withLock { $0[id] } }
        if policy == .deny { expelViewer(addr: addr) }
    }

    /// Pure staleness computation: which addresses have been silent longer
    /// than `timeoutNs` as of `nowNs`? Shared by the connected-viewer and
    /// pending-viewer sweeps (which differ only in their timeout). Extracted
    /// from `sweepIdleViewers` so the timeout math is unit testable.
    static func staleAddrs(
        lastSeenNs: [String: UInt64], nowNs: UInt64, timeoutNs: UInt64
    ) -> [String] {
        lastSeenNs.filter { nowNs &- $0.value > timeoutNs }.map(\.key)
    }

    /// Pure hung-helper predicate: a helper is considered wedged when it has
    /// produced *something* before (`lastActivityNs != 0` — 0 means no helper
    /// yet) but nothing within `timeoutNs`. Extracted from the watchdog in
    /// `sweepIdleViewers` so the liveness math is unit testable.
    static func helperLooksHung(
        lastActivityNs: UInt64, nowNs: UInt64, timeoutNs: UInt64
    ) -> Bool {
        lastActivityNs != 0 && nowNs &- lastActivityNs > timeoutNs
    }

    /// Periodically prunes viewers that haven't said anything in a while.
    /// Covers the case where a viewer crashes without sending BYE — we
    /// can't rely on UDP for "the other side is gone" the way TCP gives
    /// us via FIN/RST.
    private func sweepIdleViewers() async {
        while isRunning {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            let dropped = viewers.withLock { state -> [(addr: String, idleNs: UInt64)] in
                let stale = Self.staleAddrs(
                    lastSeenNs: state.mapValues { $0.lastSeenNs },
                    nowNs: now, timeoutNs: self.viewerIdleTimeoutNs)
                let result = stale.map { (addr: $0, idleNs: now &- (state[$0]?.lastSeenNs ?? now)) }
                for addr in stale { state.removeValue(forKey: addr) }
                return result
            }
            if !dropped.isEmpty {
                viewerInfos.withLock { state in
                    for entry in dropped { state.removeValue(forKey: entry.addr) }
                }
                notifyViewersChanged()
            }
            for entry in dropped {
                let idleMs = Int(entry.idleNs / 1_000_000)
                // An idled-out viewer surrenders any control grant.
                revokeControlIfHeld(byIP: ipFromAddr(entry.addr), reason: "viewer idle timeout")
                logger.log("Viewer timeout \(entry.addr) (idle \(idleMs) ms)")
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
                pendingViewerInfos.withLock { state in
                    for addr in droppedPending { state.removeValue(forKey: addr) }
                }
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
        }
    }

    /// Adaptive-bitrate control loop. Polls every 5 seconds; counts PLIs
    /// received from each viewer in the last 5 s window, takes the worst
    /// per-viewer rate (we encode once and fan out — the worst link is
    /// the one we have to satisfy), and either:
    ///
    ///   * cuts bitrate by 25 % if PLIs exceed the loss threshold, or
    ///   * recovers 10 % toward the baseline if the window was clean.
    ///
    /// Hysteresis: at least 5 s must elapse since the last change before
    /// we cut, and at least 10 s before we step back up. Bitrate floor is
    /// 30 % of the baseline so a temporarily-bad link doesn't push us into
    /// unwatchable territory.
    private func adaptiveBitrateSweep() async {
        let windowNs: UInt64 = 5_000_000_000
        let downHysteresisNs: UInt64 = 5_000_000_000
        let upHysteresisNs: UInt64 = 10_000_000_000
        let lossThreshold = 2  // PLIs per window before we cut

        while isRunning {
            try? await Task.sleep(nanoseconds: windowNs)
            guard isRunning, helperCapture != nil else { continue }

            let baseline = baselineBitrate.withLock { $0 }
            let current = currentBitrate.withLock { $0 }
            let lastChange = lastBitrateChangeNs.withLock { $0 }
            guard baseline > 0 else { continue }
            let now = DispatchTime.now().uptimeNanoseconds

            let worstPLIs = viewers.withLock { state -> Int in
                var worst = 0
                let cutoff = now &- windowNs
                let keys = Array(state.keys)
                for key in keys {
                    guard var viewer = state[key] else { continue }
                    viewer.pliTimestampsNs.removeAll { $0 < cutoff }
                    state[key] = viewer
                    worst = max(worst, viewer.pliTimestampsNs.count)
                }
                return worst
            }

            let elapsedSinceChange = now &- lastChange
            if let next = Self.nextAdaptiveBitrate(
                worstPLIs: worstPLIs,
                current: current,
                baseline: baseline,
                elapsedSinceChangeNs: elapsedSinceChange,
                lossThreshold: lossThreshold,
                downHysteresisNs: downHysteresisNs,
                upHysteresisNs: upHysteresisNs
            ) {
                let reason = next < current ? "loss (\(worstPLIs) PLIs/5s)" : "clean window"
                applyAdaptiveBitrate(next, reason: reason)
            }
        }
    }

    /// Pure adaptive-bitrate decision: given the worst per-viewer PLI count in
    /// the last window, the current and baseline bitrates, and how long since
    /// the last change, return the next bitrate — or `nil` to hold steady.
    ///
    /// Cut 25 % (never below the floor of 30 % of baseline or 500 kbps) when
    /// loss exceeds `lossThreshold` and the down-hysteresis has elapsed; recover
    /// +10 % (min 100 kbps step, capped at baseline) after a clean window once
    /// the longer up-hysteresis has elapsed. Asymmetric hysteresis makes cuts
    /// fast and recovery slow. A `current` above `baseline` clamps straight
    /// down to it with no hysteresis (see below). Extracted from the sweep so
    /// the math is unit testable without a live encoder.
    static func nextAdaptiveBitrate(
        worstPLIs: Int,
        current: Int,
        baseline: Int,
        elapsedSinceChangeNs: UInt64,
        lossThreshold: Int = 2,
        downHysteresisNs: UInt64 = 5_000_000_000,
        upHysteresisNs: UInt64 = 10_000_000_000
    ) -> Int? {
        guard baseline > 0 else { return nil }
        // Self-heal: a mid-share ceiling drop can race an in-flight sweep
        // apply and leave `current` parked above the (new, lower) baseline,
        // where neither arm below would ever fire on a loss-free link (the
        // raise arm requires current < baseline). Clamp straight down, no
        // hysteresis — the encoder should never run above the effective
        // ceiling.
        if current > baseline { return baseline }
        // 30 % of baseline, never below 500 kbps (see TransportTuning).
        let floor = TransportTuning.adaptiveBitrateFloor(baseline: baseline)
        if worstPLIs > lossThreshold && elapsedSinceChangeNs >= downHysteresisNs && current > floor {
            return max(floor, current * 3 / 4)  // -25 %
        } else if worstPLIs == 0 && elapsedSinceChangeNs >= upHysteresisNs && current < baseline {
            return min(baseline, current + max(current / 10, 100_000))  // +10 %, min step 100 kbps
        }
        return nil
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
        helperCapture?.setBitrate(bitrate)
        if bitrate < prev {
            helperCapture?.requestKeyframe()
        }
        let kbps = Double(bitrate) / 1000.0
        let prevKbps = Double(prev) / 1000.0
        logger.log("Adaptive bitrate: \(Int(prevKbps)) → \(Int(kbps)) kbps (\(reason))")
    }

    /// Live-apply a new user bandwidth ceiling mid-share (`nil` = back to
    /// automatic). fps / codec edits need a helper respawn and deliberately
    /// wait for the next share, but the ceiling rides the existing
    /// `setBitrate` wire message, so Settings changes take effect at once.
    /// Recomputes `baselineBitrate = min(anchoredBaseline, ceiling)` and
    /// pushes the current bitrate down if it now exceeds the new baseline;
    /// a raised (or removed) ceiling instead lets the adaptive sweep
    /// recover gradually toward the new baseline. Also folds the value
    /// into the session snapshot so a crash-restart respawn spawns the
    /// helper with the ceiling the user last set. Safe to call while not
    /// sharing (no-ops until an encoder anchors a baseline).
    func updateQualityCeiling(_ bps: Int?) {
        // Same clamp/rounding as persistence (`normalized()`), so the live
        // path can't disagree with what the Settings pane stores.
        let ceiling = QualitySettings.normalizedCeiling(bps)
        let changed = sessionQuality.withLock { quality -> Bool in
            guard quality.maxBitrateBps != ceiling else { return false }
            quality.maxBitrateBps = ceiling
            return true
        }
        guard changed else { return }
        // Fold the new ceiling into the anchor inputs so the next IDR's
        // parameter-sets emit doesn't read as a config change and re-anchor
        // over the adjustment applied below.
        lastAnchorInputs.withLock { $0?.ceilingBps = ceiling }
        let anchor = anchoredBaselineBitrate.withLock { $0 }
        // No encoder anchored yet — the snapshot applies at anchor time.
        guard anchor > 0 else { return }
        let newBaseline = min(anchor, ceiling ?? anchor)
        baselineBitrate.withLock { $0 = newBaseline }
        let current = currentBitrate.withLock { $0 }
        if current > newBaseline {
            applyAdaptiveBitrate(newBaseline, reason: "user bandwidth ceiling")
        } else {
            logger.log("Quality ceiling: baseline now \(newBaseline / 1000) kbps")
        }
    }

    /// Convert an encoded AVCC access unit into RTP packets and fan them out
    /// to every registered viewer with a per-viewer SSRC and sequence number.
    /// On IDR we prepend the cached parameter sets as Single NAL packets so
    /// the access unit is fully self-contained — late-joining viewers can
    /// decode the very first frame they observe. (For HEVC that's VPS+SPS+
    /// PPS; for H.264 it's SPS+PPS.)
    private func broadcast(avccData: Data, isKeyframe: Bool) {
        guard let pl = packetListener else { return }
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

        let plans = viewers.withLock { state -> [Plan] in
            var out: [Plan] = []
            // Snapshot keys before the lookup/update loop so we don't iterate
            // a dict whose contents are mid-mutation.
            let addrs = Array(state.keys)
            out.reserveCapacity(addrs.count)
            for addr in addrs {
                guard var viewer = state[addr] else { continue }
                out.append(Plan(addr: addr, ssrc: viewer.ssrc, startSeq: viewer.nextSequence))
                viewer.nextSequence &+= packetCount
                state[addr] = viewer
            }
            return out
        }

        // Fan out to each viewer on its OWN send chain. A viewer's frame N+1
        // awaits only its own frame N (preserving that viewer's packet order),
        // so a slow viewer whose `pl.send` blocks throttles only its own stream
        // — not the global frame rate. Per viewer we cap frames queued behind a
        // stalled send and drop past the cap (a PLI recovers the gap), so a
        // viewer that can't keep up doesn't accumulate unbounded latency.
        videoSendTails.withLock { tails in
            var next: [String: ViewerSendChain] = [:]
            next.reserveCapacity(plans.count)
            for plan in plans {
                var chain = tails[plan.addr] ?? ViewerSendChain()
                if chain.queuedFrames >= Self.maxQueuedVideoFramesPerViewer {
                    // Viewer is behind — drop this frame for it. Its seq numbers
                    // were already reserved, so the gap reads as loss and the
                    // viewer's PLI fetches a fresh keyframe.
                    next[plan.addr] = chain
                    continue
                }
                let prev = chain.task
                let addr = plan.addr
                let ssrc = plan.ssrc
                let startSeq = plan.startSeq
                chain.queuedFrames += 1
                let job = Task { [weak self] in
                    await prev?.value
                    for (i, template) in templates.enumerated() {
                        var pkt = template
                        Self.rewriteRTPHeader(&pkt, sequence: startSeq &+ UInt16(i), ssrc: ssrc)
                        // UDP is allowed to fail; a viewer PLI recovers it.
                        try? await pl.send(pkt, to: addr)
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

    /// Overwrites bytes 2-3 (sequence) and 8-11 (SSRC) of an RTP packet.
    /// Avoids re-encoding the whole header per viewer. Internal (not
    /// private) so the per-viewer rewrite is unit testable.
    static func rewriteRTPHeader(_ packet: inout Data, sequence: UInt16, ssrc: UInt32) {
        packet[2] = UInt8((sequence >> 8) & 0xFF)
        packet[3] = UInt8(sequence & 0xFF)
        packet[8] = UInt8((ssrc >> 24) & 0xFF)
        packet[9] = UInt8((ssrc >> 16) & 0xFF)
        packet[10] = UInt8((ssrc >> 8) & 0xFF)
        packet[11] = UInt8(ssrc & 0xFF)
    }

    /// Send one outbound audio RTP packet (sharer's mic) to all viewers.
    /// VoiceChannel calls this from its onSend closure. Chains through
    /// `audioBroadcastTail` so a slow `pl.send` parks the next packet's
    /// job rather than piling up detached Tasks at 50 Hz × N viewers.
    func sendAudioRTP(_ packet: Data) {
        guard let pl = packetListener else { return }
        let recipients = viewers.withLock { Array($0.keys) }
        guard !recipients.isEmpty else { return }
        let prev = audioBroadcastTail.withLock { $0 }
        let job = Task {
            await prev?.value
            for addr in recipients {
                try? await pl.send(packet, to: addr)
            }
        }
        audioBroadcastTail.withLock { $0 = job }
    }

    func getIPAddresses() async throws -> (ip4: String?, ip6: String?) {
        guard let node = node else { throw TailscaleError.badInterfaceHandle }
        return try await node.addrs()
    }

    func stop() async {
        logger.log("Server stopping…")
        isRunning = false

        // End any remote-control session. Viewers are torn down by SERVER_BYE
        // below, so there's no need to send a per-connection revoke — just
        // clear the grant/request state, drop queued input, and notify the UI.
        let hadGrant = controlGrant.withLock { grant -> Bool in
            let had = grant != nil
            grant = nil
            return had
        }
        controlRequests.withLock { $0.removeAll() }
        remoteControlInjector.reset()
        remoteControlInjector.setSelection(nil)
        droppedInputLogged.withLock { $0 = false }
        inputRateLimiter.withLock { $0 = EventRateLimiter() }
        if hadGrant { notifyControlGrantChanged() }
        notifyControlRequestsChanged()

        // Drain any in-flight `restartCapture` before we touch
        // `helperCapture`. The restart's final assignment otherwise
        // races with our nil-out and orphans a child helper process —
        // the macOS screen-recording badge stays on after Stop Sharing.
        let pending = restartTask.withLock { task -> Task<Error?, Never>? in
            let t = task
            task = nil
            return t
        }
        if let pending {
            _ = await pending.value
        }

        // Best-effort SERVER_BYE first, so viewers tear down on the spot
        // instead of waiting out their 15 s no-video timer. We send while
        // the packet listener is still healthy and *before* tearing the
        // helper down — issuing SERVER_BYE after listener close (or
        // even just before, racing with the close) loses the datagrams
        // because libtailscale's `pc.Close()` discards anything still
        // buffered in the Go-side socketpair. Three redundant sends per
        // viewer mitigate single-packet UDP loss; the brief sleep that
        // follows gives tsnet's bridge goroutines time to actually emit
        // the datagrams onto the wire before we close the listener.
        let goodbyeAddrs =
            viewers.withLock { Array($0.keys) }
            + pendingViewers.withLock { Array($0.keys) }
        if let pl = packetListener, !goodbyeAddrs.isEmpty {
            let payload = ScreenShareControlMessage.encode(.serverBye)
            for _ in 0..<3 {
                for addr in goodbyeAddrs {
                    try? await pl.send(payload, to: addr)
                }
            }
            logger.log("Server stop: SERVER_BYE sent to \(goodbyeAddrs.count) viewer(s)")
            try? await Task.sleep(for: .milliseconds(200))
        }

        await helperCapture?.stop()
        helperCapture = nil
        helperCodec = nil
        lastAnchorInputs.withLock { $0 = nil }
        logger.log("Server stop: capture done")

        viewers.withLock { $0.removeAll() }
        viewerInfos.withLock { $0.removeAll() }
        pendingViewers.withLock { $0.removeAll() }
        pendingViewerInfos.withLock { $0.removeAll() }
        peerNameCache.withLock { $0.removeAll() }
        peerStableIDCache.withLock { $0.removeAll() }
        preApprovedIPs.withLock { $0.removeAll() }
        // Drop per-viewer send chains. Any in-flight send job completes on its
        // own (its pl.send just fails once the listener closes below).
        videoSendTails.withLock { $0.removeAll() }
        notifyViewersChanged()
        notifyPendingViewersChanged()

        await packetListener?.close()
        packetListener = nil
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

        // Only tear down the listener if we created it ourselves. When
        // AppState owns it (the production path), leave it running so
        // request-to-share traffic keeps flowing after the share ends.
        if let owned = ownedControlListener {
            await owned.stop()
            logger.log("Server stop: owned control listener closed")
        }
        ownedControlListener = nil
        controlListener = nil

        // Only close the node if this server actually owns it. When AppState
        // hands us its own node, AppState retains ownership and closes it on
        // sign-out — closing it here would break peer discovery and the
        // signed-in UI state.
        if let node = node, ownsNode {
            try? await node.close()
        }
        self.node = nil

        logger.log("Server stopped")
    }

    deinit {
        isRunning = false
    }

    // MARK: - Test-only entrypoints
    //
    // Synthetic-frames XCTest (`ScreenShareSyntheticFramesTests`) brings the
    // server up with `filterData: nil` so no capture-helper spawns, then
    // injects pre-encoded AVCC bytes through the broadcast path. These shims
    // are reachable only via `@testable import Tailscreen`; production code
    // reaches `broadcast` via `handleHelperAccessUnit` + the helper's
    // `onParameterSets` callback.

    /// Seed the server's cached codec + parameter sets as if the
    /// capture-helper had just emitted them.
    func injectSyntheticParameters(_ params: CodecParameterSets) {
        parameterSets.withLock { $0 = params }
        switch params {
        case .h264: helperCodec = .h264
        case .hevc: helperCodec = .hevc
        }
    }

    /// Fan out a pre-encoded AVCC access unit through the server's RTP path.
    /// Bypasses the helper-process plumbing but uses the exact same broadcast
    /// route production frames take.
    func broadcastForTesting(avccData: Data, isKeyframe: Bool) {
        broadcast(avccData: avccData, isKeyframe: isKeyframe)
    }
}

private struct TSLogger: LogSink {
    var logFileHandle: Int32?
    func log(_ message: String) {
        if message.hasPrefix("Listening for ") { return }
        print("[Tailscale] \(message)")
    }
}
