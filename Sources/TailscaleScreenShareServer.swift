import AppKit
import Foundation
import ScreenCaptureKit
import TailscaleKit
import os

/// Screen-share server. Runs two listeners on the same port:
///
///   - **TCP 7447**: presence beacon for peer discovery only. Accepts and
///     immediately closes — `TailscalePeerDiscovery` probes this to detect
///     "is Tailscreen running on that node?" without speaking any protocol.
///   - **UDP 7447**: actual video stream. Carries RTP packets out to viewers
///     and small control bytes (HELLO/KEEPALIVE/BYE/PLI) back from them. The
///     same socket multiplexes both directions; we tell them apart by the
///     first byte (RTP V=2 → 0x80–0xBF, control → 0x00–0x7F).
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
    private var probeListener: Listener?
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
    private let annotationConnections = OSAllocatedUnfairLock<[UUID: IncomingConnection]>(initialState: [:])
    /// Per-connection set of annotation UUIDs the viewer has produced.
    /// Keyed by the server-side connection UUID (same key as
    /// ``annotationConnections``); the value is every annotation
    /// `.id` that's still considered live on this viewer's behalf
    /// (mid-drag entries the viewer never finished count too — they've
    /// already been added to the sharer's overlay via in-progress
    /// `.add` ops). Cleared incrementally as the viewer's own
    /// `.undo` / `.clearAll` ops arrive, and en masse in
    /// `receiveAnnotations`' defer when their connection drops — we
    /// fire `.undo` for each remaining UUID so the sharer's overlay
    /// (and every other viewer, via `broadcastAnnotation`) stops showing
    /// strokes nobody is around to clean up.
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
    private let pendingApprovalTimeoutNs: UInt64 = 60_000_000_000

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

    /// Tail of the broadcast chain. Each new frame's send job awaits this
    /// before issuing its own sends, so frame N's packets fully drain
    /// through the PacketListener actor before frame N+1 starts. Without
    /// this, two concurrent send tasks could interleave at the actor and
    /// receivers would see seq numbers go backwards within an AU.
    private let broadcastTail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// Same idea as `broadcastTail`, but for audio: every audio fan-out
    /// (sharer mic out, viewer-to-viewer relay) chains through here so
    /// we don't spawn a fresh detached `Task` per ~21 ms AU × N viewers.
    /// Under congestion the chain provides natural backpressure — the
    /// next packet's job parks on the previous one's `await prev?.value`
    /// rather than piling up unbounded.
    private let audioBroadcastTail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// Drop viewers that have gone silent for this long. Has to absorb a
    /// run of consecutive UDP keepalive losses plus any Task scheduling
    /// jitter from the cooperative pool — the previous 5 s value was
    /// tight enough that a brief network/CPU stall would drop a healthy
    /// viewer mid-session, which then triggered the viewer's own 3 s
    /// "no video" disconnect and tore the whole call down. Clients send
    /// KEEPALIVE every 500 ms, so 15 s tolerates ~30 consecutive misses
    /// while still collecting a truly crashed viewer well before any
    /// HELLO retry would.
    private let viewerIdleTimeoutNs: UInt64 = 15_000_000_000

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
    /// surface the failure as a normal capture stop.
    private var helperCrashTimestampsNs: [UInt64] = []

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
        existingNode: TailscaleNode? = nil
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
            try await newNode.up()
            node = newNode
        }

        let ips = try await node.addrs()
        logger.log("Tailscale connected — ip4=\(ips.ip4 ?? "-") ip6=\(ips.ip6 ?? "-")")

        guard let tailscaleHandle = await node.tailscale else {
            throw TailscaleError.badInterfaceHandle
        }

        // TCP "presence beacon" so existing peer discovery (which probes
        // by opening a TCP connection on this port) keeps working. We
        // never speak any protocol on these sockets — accept and close.
        let probeListener = try await Listener(
            tailscale: tailscaleHandle,
            proto: .tcp,
            address: ":\(port)",
            logger: logger
        )
        self.probeListener = probeListener
        logger.log("TCP presence beacon listening on :\(port)")

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

        Task { [weak self] in await self?.acceptControlConnections() }
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

    private func startHelperCapture(filterData: Data) throws {
        let helper = HelperScreenCapture()
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
            // -3805 ("application connection being interrupted") on
            // the helper's first SCStream startup is replayd
            // refusing the slot — usually because another same-bundle
            // process on this Mac already holds one. Respawning hits
            // the exact same wall, so bail straight to teardown
            // instead of burning the full crash budget.
            if reason.contains("-3805") || reason.localizedCaseInsensitiveContains("being interrupted") {
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
            }
            // Helper tagged its own death as non-retryable (decode
            // failure, startup-watchdog timeout, etc.). Respawning
            // would hit the same wall, so bail straight to teardown.
            // The helper writes `permanent: ...` via `writeFatal`,
            // which surfaces here as `"fatal: permanent: ..."`.
            if reason.contains("permanent:") {
                let err = NSError(
                    domain: "Tailscreen.HelperScreenCapture",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: reason]
                )
                self.onCaptureStopped?(err)
                return
            }
            // Sliding-window restart: tolerate ≤3 crashes in 30 s,
            // give up after that. Each crash invalidates replayd's
            // slot for that PID, so respawning gets a fresh process
            // with no inherited bad state.
            let now = DispatchTime.now().uptimeNanoseconds
            let windowNs: UInt64 = 30_000_000_000
            self.helperCrashTimestampsNs.removeAll { now &- $0 > windowNs }
            self.helperCrashTimestampsNs.append(now)
            if self.helperCrashTimestampsNs.count > 3 || !self.isRunning {
                let err = NSError(
                    domain: "Tailscreen.HelperScreenCapture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: reason])
                self.onCaptureStopped?(err)
                return
            }
            self.logger.log("HelperScreenCapture: restarting (crash #\(self.helperCrashTimestampsNs.count) in window)")
            do {
                guard let filterData = self.lastFilterData else {
                    throw NSError(
                        domain: "Tailscreen.HelperScreenCapture", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "no cached filter to restart against"])
                }
                try self.startHelperCapture(filterData: filterData)
            } catch {
                let err = NSError(
                    domain: "Tailscreen.HelperScreenCapture", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "respawn failed: \(error)"])
                self.onCaptureStopped?(err)
            }
        }
        try helper.start(filterData: filterData)
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
        // Run the restart inside a tracked Task so `stop()` can
        // await it. Without this synchronization, stop() can race
        // with `helperCapture = helper` inside `startHelperCapture`
        // and leave a child process alive after teardown — visible
        // as the macOS screen-recording badge stuck on after Stop
        // Sharing.
        let work = Task { [weak self] () -> Error? in
            guard let self else { return nil }
            if let existing = self.helperCapture {
                self.helperCapture = nil
                await existing.stop()
            }
            self.helperCrashTimestampsNs.removeAll()
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
        let result = await work.value
        restartTask.withLock { $0 = nil }
        if let result { throw result }
    }

    /// Accept TCP connections on port 7447. The same listener serves two
    /// roles, both of which look identical at the socket level:
    ///
    ///   * **Peer-discovery probe** (`TailscalePeerDiscovery.probeTailscreenPort`)
    ///     opens a connection, sends nothing, then closes. The receive loop
    ///     errors out on EOF and we move on — the probe got "connection
    ///     succeeded" which is all it needed.
    ///   * **Annotation back-channel** from a viewer streams framed
    ///     ``ScreenShareMessage.annotation(...)`` payloads. We parse and
    ///     surface each op via ``onAnnotationReceived``.
    private func acceptControlConnections() async {
        guard let listener = probeListener else { return }
        while isRunning {
            do {
                let conn = try await listener.accept(timeout: 1.0)
                let id = UUID()
                annotationConnections.withLock { $0[id] = conn }
                annotationsByConnection.withLock { $0[id] = [] }
                Task { [weak self] in
                    await self?.receiveAnnotations(from: conn, id: id)
                }
            } catch {
                continue
            }
        }
    }

    /// Reads framed annotation messages from one viewer's TCP back-channel
    /// until the connection closes or the server stops. A peer-discovery
    /// probe just hangs up after a successful connect — the receive call
    /// errors quickly and we tear the entry down with no noise.
    ///
    /// On exit, fires `.undo` for every annotation UUID this viewer was
    /// still on the hook for so their strokes don't outlive them — both
    /// on the sharer's local overlay (via `onAnnotationReceived`) and on
    /// every other viewer's overlay (via `broadcastAnnotation`).
    /// Peer-discovery probes leave the tracking set empty, so the
    /// cleanup is a no-op for them.
    private func receiveAnnotations(from connection: IncomingConnection, id: UUID) async {
        defer {
            _ = annotationConnections.withLock { $0.removeValue(forKey: id) }
            let outstanding = annotationsByConnection.withLock { $0.removeValue(forKey: id) ?? [] }
            if !outstanding.isEmpty {
                // Fire `.undo` for every UUID this viewer was on the hook
                // for so their strokes don't outlive them — both on the
                // sharer's local overlay (via `onAnnotationReceived`) and
                // on every other viewer's overlay (via `broadcastAnnotation`).
                let cb = onAnnotationReceived
                for uuid in outstanding {
                    let op: AnnotationOp = .undo(uuid)
                    cb?(op)
                    Task { [weak self] in
                        await self?.broadcastAnnotation(op, excludingConnection: id)
                    }
                }
            }
            Task { await connection.close() }
        }
        var parser = ScreenShareMessageParser()
        while isRunning {
            do {
                let chunk = try await connection.receive(maximumLength: 16 * 1024, timeout: 5_000)
                if chunk.isEmpty { return }  // EOF — peer closed
                parser.append(chunk)
                while let message = parser.next() {
                    if case .annotation(let op) = message {
                        trackAnnotationOp(op, connectionID: id)
                        onAnnotationReceived?(op)
                        // Fan out to every OTHER viewer so window /
                        // application share modes can carry annotations
                        // peer-to-peer instead of relying on SCStream
                        // catching the sharer's overlay panel.
                        Task { [weak self] in
                            await self?.broadcastAnnotation(op, excludingConnection: id)
                        }
                    }
                }
            } catch TailscaleError.readFailed {
                if !isRunning { return }
                continue  // poll timeout or transient — keep reading
            } catch {
                return
            }
        }
    }

    /// Broadcast a framed `AnnotationOp` to every annotation back-channel
    /// connection, optionally skipping the one that originated the op
    /// (to avoid echoing a viewer's stroke back to them). Used both for
    /// sharer-painted strokes (no exclusion — sharer has no annotation
    /// connection) and viewer-to-viewer fan-out (exclude the source).
    /// Send failures are logged and ignored; the receive loop on the
    /// far side will tear the stale connection down on its own.
    func broadcastAnnotation(_ op: AnnotationOp, excludingConnection: UUID? = nil) async {
        let data = ScreenShareMessage.annotation(op).encode()
        let conns = annotationConnections.withLock { state -> [IncomingConnection] in
            state.compactMap { (id, conn) in
                id == excludingConnection ? nil : conn
            }
        }
        guard !conns.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for conn in conns {
                group.addTask {
                    do {
                        // `IncomingConnection` is itself an actor; its
                        // `send` is auto-serialized, so concurrent
                        // broadcasts can't interleave bytes on the same
                        // socket even though they're fanned out via a
                        // task group here.
                        try await conn.send(data)
                    } catch {
                        // Connection's dead or buffer-full; the receive
                        // task's defer will clean up the entry.
                    }
                }
            }
        }
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
        }
    }

    /// Relay one inbound audio RTP packet to all other viewers and pass
    /// a copy to the local VoiceChannel via `onAudioReceived`. The packet
    /// is forwarded byte-for-byte (no transcode) so the receiving viewer
    /// sees the original sender's SSRC.
    private func handleInboundAudioRTP(_ packet: Data, header: RTPHeader, from sender: String) {
        // Verify the sender is registered AND the embedded SSRC matches the
        // one we assigned to this address. Without the SSRC check, a
        // registered viewer could spoof another viewer's audio by stuffing
        // its SSRC into the RTP header.
        let validated = viewers.withLock { state -> (valid: Bool, recipients: [String]) in
            guard let viewer = state[sender], viewer.audioSSRC == header.ssrc else {
                return (false, [])
            }
            return (true, state.keys.filter { $0 != sender })
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

    /// Append a PLI timestamp to the viewer's ring. The adaptive sweep
    /// (every 5 s) reads these to decide whether to step bitrate down.
    /// Drop the oldest entry once we hold more than 32 — at our
    /// recovery cadence (PLI per missing AU, capped by the encoder's
    /// keyframe production rate) this is comfortably more than a 5 s
    /// window can ever observe.
    private func recordPLI(from addr: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        viewers.withLock { state in
            guard var viewer = state[addr] else { return }
            viewer.pliTimestampsNs.append(now)
            if viewer.pliTimestampsNs.count > 32 {
                viewer.pliTimestampsNs.removeFirst(viewer.pliTimestampsNs.count - 32)
            }
            state[addr] = viewer
        }
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

        let (added, viewerCount) = viewers.withLock { state -> (Bool, Int) in
            if var existing = state[addr] {
                existing.lastSeenNs = now
                state[addr] = existing
                return (false, state.count)
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

    /// Periodically prunes viewers that haven't said anything in a while.
    /// Covers the case where a viewer crashes without sending BYE — we
    /// can't rely on UDP for "the other side is gone" the way TCP gives
    /// us via FIN/RST.
    private func sweepIdleViewers() async {
        while isRunning {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let now = DispatchTime.now().uptimeNanoseconds
            let dropped = viewers.withLock { state -> [(addr: String, idleNs: UInt64)] in
                let stale = state.filter { now &- $0.value.lastSeenNs > self.viewerIdleTimeoutNs }
                let result = stale.map { (addr: $0.key, idleNs: now &- $0.value.lastSeenNs) }
                for (addr, _) in stale { state.removeValue(forKey: addr) }
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
                let stale = state.filter { now &- $0.value.lastSeenNs > self.pendingApprovalTimeoutNs }
                for (addr, _) in stale { state.removeValue(forKey: addr) }
                return stale.map { $0.key }
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
            let floor = max(baseline * 3 / 10, 500_000)  // 30 % of baseline, never below 500 kbps
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
            if worstPLIs > lossThreshold && elapsedSinceChange >= downHysteresisNs && current > floor {
                let next = max(floor, current * 3 / 4)  // -25 %
                applyAdaptiveBitrate(next, reason: "loss (\(worstPLIs) PLIs/5s)")
            } else if worstPLIs == 0 && elapsedSinceChange >= upHysteresisNs && current < baseline {
                let next = min(baseline, current + max(current / 10, 100_000))  // +10 %, min step 100 kbps
                applyAdaptiveBitrate(next, reason: "clean window")
            }
        }
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

        // Chain after the previous frame's send job. The encoder is bursty
        // (one frame's worth of packets emitted in a single callback) but
        // VT serializes its callbacks, so the chain stays short — at most
        // one frame's worth of work in flight at a time.
        let prev = broadcastTail.withLock { $0 }
        let job = Task {
            await prev?.value
            for plan in plans {
                for (i, template) in templates.enumerated() {
                    var pkt = template
                    let seq = plan.startSeq &+ UInt16(i)
                    Self.rewriteRTPHeader(&pkt, sequence: seq, ssrc: plan.ssrc)
                    // UDP is allowed to fail; PLI from the viewer will
                    // recover any frame we couldn't push.
                    try? await pl.send(pkt, to: plan.addr)
                }
            }
        }
        broadcastTail.withLock { $0 = job }
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
    /// Avoids re-encoding the whole header per viewer.
    private static func rewriteRTPHeader(_ packet: inout Data, sequence: UInt16, ssrc: UInt32) {
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
        notifyViewersChanged()
        notifyPendingViewersChanged()

        await packetListener?.close()
        packetListener = nil
        logger.log("Server stop: packet listener closed")

        await probeListener?.close()
        probeListener = nil
        logger.log("Server stop: probe listener closed")

        // Close any in-flight annotation back-channels in parallel; their
        // receive tasks will see the close and exit naturally. Wipe the
        // per-connection annotation-UUID map first so each receive loop's
        // defer sees an empty set — otherwise the cleanup path would fire
        // `.undo` ops back through `onAnnotationReceived` *after* AppState
        // has already torn the overlay down, which would re-create the
        // overlay just to apply a no-op undo.
        annotationsByConnection.withLock { $0.removeAll() }
        let conns = annotationConnections.withLock { state -> [IncomingConnection] in
            let values = Array(state.values)
            state.removeAll()
            return values
        }
        await withTaskGroup(of: Void.self) { group in
            for conn in conns { group.addTask { await conn.close() } }
        }

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
}

private struct TSLogger: LogSink {
    var logFileHandle: Int32?
    func log(_ message: String) {
        if message.hasPrefix("Listening for ") { return }
        print("[Tailscale] \(message)")
    }
}
