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
    /// `.clearAll` ops arrive, and en masse when the control listener
    /// reports the connection closed — we fire `.undo` for each remaining
    /// UUID so the sharer's overlay (and every other viewer, via
    /// `broadcastAnnotation`) stops showing strokes nobody is around to
    /// clean up.
    private let annotationsByConnection = OSAllocatedUnfairLock<[UUID: Set<UUID>]>(initialState: [:])

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

    /// IP → hostname cache. Filled lazily by `resolveHostname` from the
    /// LocalAPI backend status. Avoids re-querying tsnet on every
    /// reconnect / KEEPALIVE storm. Cleared in `stop()`.
    private let peerNameCache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Encoder bitrate the most recent `setup` produced, in bits/sec. The
    /// adaptive-bitrate sweep treats this as the ceiling and never raises
    /// above it. Recomputed on every encoder reinit (resolution change).
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

    /// JSON-encoded `PickerSelection` describing what the user
    /// picked. Cached so `restartCapture()` can rebuild the SCStream
    /// against the same content (display / window / app / multi-app)
    /// without forcing the caller to track that state. Carried as
    /// raw `Data` so the main process never has to know the schema
    /// — the helper decodes it.
    private var lastFilterData: Data?

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

    /// Stateful per-codec packetizers. Held across `broadcast()` calls so
    /// each call can recycle the previous batch's buffer storage instead
    /// of allocating a fresh `Data` per packet. See `RTPPacketBufferPool`
    /// for the COW-based safety argument. Cheap when unused (no codec yet
    /// settled): each holds an empty pool array.
    private let h264Packetizer = H264Packetizer()
    private let h265Packetizer = H265Packetizer()

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
    /// callers always pass a real selection.
    func start(
        hostname: String = "tailscreen-server",
        authKey: String? = nil,
        path: String? = nil,
        controlURL: String = kDefaultControlURL,
        filterData: Data?,
        existingNode: TailscaleNode? = nil,
        controlListener: TailscreenControlListener? = nil
    ) async throws {
        guard !isRunning else { return }

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

        lastFilterData = filterData
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
            // Anchor the adaptive-bitrate ceiling. `defaultBitsPerPixel`
            // wants a codec; default to HEVC's value if helperCodec
            // hasn't landed yet — encoder will overwrite it on its
            // next emit anyway.
            let codec: VideoCodec = self.helperCodec ?? .hevc
            let bpp = VideoEncoder.defaultBitsPerPixel(for: codec)
            let baseline = Int(Double(width * height) * bpp * 60.0)
            self.baselineBitrate.withLock { $0 = baseline }
            self.currentBitrate.withLock { $0 = baseline }
            self.lastBitrateChangeNs.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
            self.logger.log(
                "HelperScreenCapture: anchored baseline bitrate \(baseline / 1000) kbps for \(width)x\(height) \(codec)"
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
        try helper.start(filterData: filterData, forceH264: forceH264.withLock { $0 })
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

    /// Spawn a fresh helper against the cached filter, wrapped in a tracked
    /// `Task` stored in `restartTask` so `stop()` can await it. Shared by the
    /// AppState-driven `restartCapture()` and the helper's own
    /// `onUnexpectedExit` auto-restart, so *both* respawn paths go through the
    /// same guard. Two properties make it orphan-safe:
    ///
    ///   1. `stop()` drains `restartTask` and awaits the in-flight work before
    ///      nulling `helperCapture`, so a respawn can't finish *after* teardown
    ///      unnoticed.
    ///   2. The Task re-checks `isRunning` *after* `startHelperCapture` assigns
    ///      `helperCapture` and tears the new helper back down if the share was
    ///      stopped meanwhile. This post-spawn check — not just the await — is
    ///      what prevents a Stop-Sharing that races the respawn from orphaning
    ///      a child process holding replayd's recording slot (the stuck-badge
    ///      bug).
    ///
    /// `resetCrashBudget` clears the sliding crash-window so the AppState-driven
    /// recovery path gets a fresh run of auto-restarts; the auto-restart path
    /// passes `false` to keep counting toward the 3-in-30s cap.
    ///
    /// The slot is deliberately not cleared on completion: a finished `Task`
    /// left in `restartTask` is harmless (`stop()` awaits it and returns at
    /// once), and *not* clearing avoids a clobber race where one restart nils
    /// out a slot another restart just populated.
    @discardableResult
    private func scheduleHelperRestart(resetCrashBudget: Bool) -> Task<Error?, Never> {
        let work = Task { [weak self] () -> Error? in
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
                guard let filterData = self.lastFilterData else {
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
        restartTask.withLock { $0 = work }
        return work
    }

    /// Wire annotation + connection-close callbacks onto the
    /// `TailscreenControlListener`. The listener handles the framed-TCP
    /// accept loop and dispatch; we only see decoded
    /// `ScreenShareMessage.annotation` ops and per-connection close
    /// notifications here.
    private func installControlHandlers() {
        guard let listener = controlListener else { return }
        listener.onAnnotation = { [weak self] op, connectionID in
            guard let self else { return }
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
        listener.onConnectionClosed = { [weak self] connectionID in
            guard let self else { return }
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
    }

    /// Broadcast a framed `AnnotationOp` to every connection on the shared
    /// control listener, optionally skipping the one that originated the op
    /// (to avoid echoing a viewer's stroke back to them). Used both for
    /// sharer-painted strokes (no exclusion — sharer has no annotation
    /// connection) and viewer-to-viewer fan-out (exclude the source).
    func broadcastAnnotation(_ op: AnnotationOp, excludingConnection: UUID? = nil) async {
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

    /// Drains UDP datagrams and routes control bytes (HELLO/KEEPALIVE/BYE/PLI).
    /// RTP packets shouldn't arrive at the server; if they do (a confused
    /// client), they're dropped — we identify them by V=2 in byte 0.
    private func receiveControlLoop() async {
        guard let pl = packetListener else { return }
        while isRunning {
            do {
                let (data, from) = try await pl.recv(timeout: 1_000)
                handleIncoming(data: data, from: from)
            } catch TailscaleError.readFailed {
                continue  // poll timeout, just keep polling
            } catch {
                if isRunning {
                    logger.log("Server: receive error: \(error)")
                }
                break
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
        case .codecUnsupported:
            registerOrRefresh(addr: addr, isNew: false)
            handleCodecUnsupported(from: addr)
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

        // Brand new addr while approval is required: park in pending and
        // surface to the UI. We allocate the audio SSRC up front so the
        // eventual HELLO_ACK (after Accept) can reuse it without an extra
        // hop. The collision check only spans other pending viewers —
        // the connected set's SSRC space is 2^32, so a cross-set clash
        // is astronomically unlikely, and the audio-validation check is
        // keyed by source address anyway.
        if approvalRequired && !alreadyKnown {
            pendingViewers.withLock { state in
                var ssrc: UInt32
                repeat {
                    ssrc = UInt32.random(in: 1...UInt32.max)
                } while state.values.contains(where: { $0.audioSSRC == ssrc })
                state[addr] = PendingViewer(addr: addr, audioSSRC: ssrc, lastSeenNs: now)
            }
            let ip = ipFromAddr(addr)
            let cached = peerNameCache.withLock { $0[ip] }
            let info = PendingViewerInfo(id: addr, tailscaleIP: ip, hostname: cached, arrivedAt: Date())
            pendingViewerInfos.withLock { $0[addr] = info }
            logger.log("Viewer pending approval \(addr)")
            notifyPendingViewersChanged()
            if cached == nil {
                Task { [weak self] in
                    await self?.resolvePendingHostnameAndUpdate(for: addr, ip: ip)
                }
            }
            // Close the toggle-off race: if `setRequireApproval(false)`
            // ran and drained the pending queue between our gate read and
            // this insert, the toggle's drain didn't see us. Re-read and
            // self-promote so the new viewer isn't stranded waiting on
            // a sharer who already opted into open-door mode.
            if !requireApproval.withLock({ $0 }) {
                approveViewer(addr: addr)
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

            let ip = ipFromAddr(addr)
            let cached = peerNameCache.withLock { $0[ip] }
            let info = ViewerInfo(
                id: addr,
                tailscaleIP: ip,
                hostname: cached,
                connectedAt: Date()
            )
            viewerInfos.withLock { $0[addr] = info }
            notifyViewersChanged()
            if cached == nil {
                Task { [weak self] in
                    await self?.resolveHostnameAndUpdate(for: addr, ip: ip)
                }
            }
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
            // open-door mode, so admit everyone in the pending queue.
            let pending = pendingViewers.withLock { Array($0.keys) }
            for addr in pending {
                approveViewer(addr: addr)
            }
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
            let ip = ipFromAddr(addr)
            let cached = peerNameCache.withLock { $0[ip] }
            let info = ViewerInfo(
                id: addr,
                tailscaleIP: ip,
                hostname: cached,
                connectedAt: Date()
            )
            viewerInfos.withLock { $0[addr] = info }
            notifyViewersChanged()
            if cached == nil {
                Task { [weak self] in
                    await self?.resolveHostnameAndUpdate(for: addr, ip: ip)
                }
            }
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

    /// Reject a pending viewer: send SERVER_BYE so they tear down
    /// immediately and drop them from the pending set. Safe to call for
    /// an unknown addr (no-op).
    func denyViewer(addr: String) {
        let existed = pendingViewers.withLock { state -> Bool in
            state.removeValue(forKey: addr) != nil
        }
        guard existed else { return }
        pendingViewerInfos.withLock { _ = $0.removeValue(forKey: addr) }
        notifyPendingViewersChanged()
        logger.log("Viewer denied \(addr)")
        // Three redundant SERVER_BYE datagrams mitigate single-packet UDP
        // loss — same template as `stop()`'s teardown path.
        let payload = ScreenShareControlMessage.encode(.serverBye)
        Task { [weak self] in
            guard let pl = self?.packetListener else { return }
            for _ in 0..<3 {
                try? await pl.send(payload, to: addr)
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

    /// Same as `resolveHostnameAndUpdate` but for an entry in
    /// `pendingViewerInfos`. Kept separate because the two dictionaries
    /// have different value types and we don't want one update to mutate
    /// both — once a viewer transitions pending → approved, the pending
    /// entry is already gone.
    private func resolvePendingHostnameAndUpdate(for addr: String, ip: String) async {
        guard let node = self.node else { return }
        let client = LocalAPIClient(localNode: node, logger: logger)
        guard let status = try? await client.backendStatus() else { return }
        var resolved: String?
        for (_, peer) in status.Peer ?? [:] {
            if let ips = peer.TailscaleIPs, ips.contains(ip) {
                resolved = peer.HostName
                break
            }
        }
        guard let hostname = resolved, !hostname.isEmpty else { return }
        peerNameCache.withLock { $0[ip] = hostname }
        let changed = pendingViewerInfos.withLock { state -> Bool in
            guard var info = state[addr] else { return false }
            guard info.hostname != hostname else { return false }
            info.hostname = hostname
            state[addr] = info
            return true
        }
        if changed { notifyPendingViewersChanged() }
    }

    /// Look the viewer's IP up in the tsnet netmap and patch its hostname
    /// in `viewerInfos` if found. Best-effort — failures leave the row as
    /// "ip only" and the UI falls back to showing the IP. Cached so
    /// repeated reconnects from the same peer don't re-query LocalAPI.
    private func resolveHostnameAndUpdate(for addr: String, ip: String) async {
        guard let node = self.node else { return }
        let client = LocalAPIClient(localNode: node, logger: logger)
        guard let status = try? await client.backendStatus() else { return }
        var resolved: String?
        for (_, peer) in status.Peer ?? [:] {
            if let ips = peer.TailscaleIPs, ips.contains(ip) {
                resolved = peer.HostName
                break
            }
        }
        guard let hostname = resolved, !hostname.isEmpty else { return }
        peerNameCache.withLock { $0[ip] = hostname }
        let changed = viewerInfos.withLock { state -> Bool in
            guard var info = state[addr] else { return false }
            guard info.hostname != hostname else { return false }
            info.hostname = hostname
            state[addr] = info
            return true
        }
        if changed { notifyViewersChanged() }
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
    /// fast and recovery slow. Extracted from the sweep so the math is unit
    /// testable without a live encoder.
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
        logger.log("Server stop: capture done")

        viewers.withLock { $0.removeAll() }
        viewerInfos.withLock { $0.removeAll() }
        pendingViewers.withLock { $0.removeAll() }
        pendingViewerInfos.withLock { $0.removeAll() }
        peerNameCache.withLock { $0.removeAll() }
        // Drop per-viewer send chains. Any in-flight send job completes on its
        // own (its pl.send just fails once the listener closes below).
        videoSendTails.withLock { $0.removeAll() }
        notifyViewersChanged()
        notifyPendingViewersChanged()

        await packetListener?.close()
        packetListener = nil
        logger.log("Server stop: packet listener closed")

        // Wipe per-connection annotation-UUID state before clearing the
        // handlers so the cleanup path in `installControlHandlers` doesn't
        // fire stale `.undo` ops back through `onAnnotationReceived` after
        // AppState has already torn the overlay down.
        annotationsByConnection.withLock { $0.removeAll() }
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
