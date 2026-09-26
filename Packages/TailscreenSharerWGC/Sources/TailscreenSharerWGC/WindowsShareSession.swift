import Foundation
import SendInputKit
import TailscaleKit
import TailscreenAudio
import TailscreenProtocol
import TailscreenSharer
import TailscreenTransport
import WGCCaptureKit
import WinOverlayKit

/// Runs a share on Windows: the system capture picker, then the portable
/// `TailscaleScreenShareServer` driven by `WGCCaptureEncoder`.
///
/// A package type, not an app file: this half must not touch the UI thread
/// (an earlier sign-in freeze was exactly this mistake — tsnet bring-up
/// running on a `@MainActor` method's non-suspending body). The controller
/// is NOT `@MainActor`; it publishes back through a callback the caller hops
/// for itself. The picker is the deliberate exception — modal system UI
/// needing an owner window and message pump, called from the main thread.
/// Also, nothing here imports a UI toolkit, so Linux CI typechecks it.
///
/// Remote control is offered only when the caller can say WHERE the shared
/// content is on screen (`controlRegion`) — a WGC `GraphicsCaptureItem`
/// exposes no HMONITOR/HWND, so without a region no injector is supplied and
/// the server withholds `ScreenShareCaps.remoteControl`.
public final class WindowsShareSession: @unchecked Sendable {
    /// What the UI needs to render, pushed on every change.
    public struct Status: Sendable {
        /// Where the share is (`ShareBringUpPhase`, TailscreenProtocol).
        public var phase: ShareBringUpPhase = .idle
        /// A projection of `phase`, so callers asking only "is a share up?" can't disagree with it.
        public var isSharing: Bool { phase.isSharing }
        /// The picker's own name for the target — "Screen 1", a window title.
        public var target = ""
        public var viewerCount = 0
        /// Who is watching, and enough about each to act on them — the
        /// surface a sharer uses to change their mind about an admitted viewer.
        public var viewers: [ConnectedViewer] = []
        public var message = ""
        /// Viewers asking for remote control, awaiting an answer. The server
        /// surfaces these and does nothing else — the grant is the person's decision.
        public var controlRequests: [ControlRequestInfo] = []
        /// Links viewers have sent, awaiting Open or Dismiss. The server
        /// surfaces these and does nothing else — opening is the sharer's
        /// click, never automatic (TS-LNK-010).
        public var linkOffers: [LinkOfferInfo] = []
        /// Viewers parked at the approval gate, awaiting Accept or Deny.
        public var pendingViewers: [PendingViewer] = []
        /// Whether new viewers have to be let in by hand. Mirrored into
        /// status so the UI's switch reads from the thing it controls.
        public var requireApproval = true
        /// Who currently holds control, if anyone.
        public var controlGrantedTo: String?
        /// Whether a capture device was opened — the capability the mic
        /// control's existence rides on.
        public var micAvailable = false
        /// Whether the sharer's voice is reaching viewers. Starts off.
        public var micOn = false
        /// Whether viewers can ask to control this machine. Reported rather
        /// than left implicit, or its absence is invisible from both ends.
        public var remoteControlAvailable = false
        /// Whether viewers' strokes appear on this screen. Gated on the same
        /// resolved geometry as control — coordinates are normalized against
        /// what the viewer sees.
        public var annotationsAvailable = false
        /// Whether the SHARER can draw on their own screen. Same geometry
        /// gate, plus arming must be reversible; see `selectDrawingTool(_:)`.
        public var drawingAvailable = false
        /// The sharer's armed tool, or nil. Read back from the latch, so a
        /// refused arm renders as unarmed rather than a tool that does nothing.
        public var activeDrawingTool: AnnotationTool?
        /// Why drawing is unavailable or was refused — surfaced rather than
        /// swallowed, or a refusal reads as "drawing is broken."
        public var drawingNote: String?
        /// The colour this sharer's strokes appear in. Identity-derived, never chosen.
        public var drawingInkColor = Annotation.defaultColor
        /// Live capture timings, so "it's slow" answers with which stage.
        public var timings: CaptureTimings?
        /// The most recent preview of what viewers are receiving, refreshed
        /// about once a second, or nil when nothing is being captured.
        public var preview: ThumbnailScaler.Thumbnail?
        /// The live share link's token — nil while the link is off. Dies with the share.
        public var linkToken: String?
        /// True while the link is being created or rotated; toggle flips are ignored.
        public var linkBusy = false
        /// This share was started signed out: the guest tunnel is its only
        /// socket, so the link is the only way in, with no off position short
        /// of Stop Sharing.
        public var linkIsOnlyWayIn = false

        public init() {}
    }

    /// Somebody currently watching.
    ///
    /// `stableID` rides along because remember/forget actions key on
    /// Tailscale StableNodeID, never `displayName` (a peer-chosen hostname).
    /// Nil until the sharer's netmap lookup lands.
    public struct ConnectedViewer: Sendable, Identifiable, Hashable {
        /// The server's `"ip:port"` viewer key — what `disconnectViewer` takes.
        public let id: String
        public let displayName: String
        public let stableID: String?
        /// The link's state, straight off the server. Passed as the ENUM
        /// rather than a rendered string, since this package has no string catalog.
        public let health: ViewerHealth
        /// A share-by-token guest: no StableNodeID ever resolves (the
        /// remember actions don't apply), and the row carries a badge.
        public let isGuest: Bool

        public init(
            id: String, displayName: String, stableID: String?, health: ViewerHealth,
            isGuest: Bool = false
        ) {
            self.id = id
            self.displayName = displayName
            self.stableID = stableID
            self.health = health
            self.isGuest = isGuest
        }
    }

    /// A viewer waiting on the sharer's Accept / Deny.
    ///
    /// A local type rather than the server's `PendingViewerInfo`, so the app
    /// avoids a direct `TailscreenSharer` dependency. `id` is the server's
    /// `"ip:port"` viewer key — `approveViewer`/`denyViewer` match on exactly
    /// that; a bare IP silently no-ops both.
    public struct PendingViewer: Sendable, Identifiable, Hashable {
        public let id: String
        /// Hostname when the netmap lookup has landed, the Tailscale IP until
        /// then. Cosmetic — never use it to identify the viewer.
        public let displayName: String
        /// See `ConnectedViewer.stableID`: "Always Allow" / "Deny & Block" on a
        /// pending row persists under this, not under `displayName`.
        public let stableID: String?
        /// See `ConnectedViewer.isGuest` — a pending guest's approval is the
        /// only way one ever reaches the roster.
        public let isGuest: Bool

        public init(
            id: String, displayName: String, stableID: String? = nil, isGuest: Bool = false
        ) {
            self.id = id
            self.displayName = displayName
            self.stableID = stableID
            self.isGuest = isGuest
        }
    }

    /// Called off the main actor. The caller hops.
    public var onStatus: (@Sendable (Status) -> Void)?

    /// Opens a capture device, or throws if there is none.
    ///
    /// Supplied by the app, because the WASAPI backend lives in the app target
    /// and this package deliberately carries no Windows-only code — that is
    /// what lets Linux CI typecheck it. A factory rather than an instance
    /// because the device is opened when a share starts and released when it
    /// stops: a long-lived open keeps the Windows microphone indicator lit
    /// while idle, which reads to a user as "this app is listening".
    ///
    /// Nil means no microphone control is offered at all.
    public var microphoneFactory: (@Sendable () throws -> MicrophoneCapturing)?
    /// Plays a viewer's decoded voice on the local output device.
    public var playRemoteVoice: (@Sendable ([Float]) -> Void)?

    /// - Parameter accessStore: injectable for tests, exactly as the GTK
    ///   engine's is. The default is `%LOCALAPPDATA%\Tailscreen` — the same
    ///   root the account registry uses, one place a user's Tailscreen state
    ///   lives — which off Windows resolves under the home directory, so a
    ///   suite that took the default would write into whoever ran it.
    public init(accessStore: PeerAccessStore? = nil) {
        self.injectedAccessStore = accessStore
        // Both flags move together, always — the latch owns that pairing, and
        // this session only mirrors it into the published status. Fires on
        // whichever thread opened, closed or lost the device; `update` takes
        // `lock` for itself and publishes outside it, so no hop is needed here.
        voiceSession.onStateChanged = { [weak self] available, on in
            self?.update {
                $0.micAvailable = available
                $0.micOn = on
            }
        }
        voiceSession.onRemotePCM = { [weak self] pcm in self?.playRemoteVoice?(pcm) }
    }

    /// One-time process setup. **Call at startup, before any window exists.**
    /// DPI awareness — without it, Windows reports scaled coordinates while
    /// WGC reports physical pixels, so above 100% scaling
    /// `resolveControlRegion` finds no matching monitor and the share
    /// silently loses remote control and annotations.
    public static func prepareProcess() {
        SendInputInjector.enablePerMonitorDPIAwareness()
    }

    private let lock = NSLock()
    private var server: TailscaleScreenShareServer?
    private var overlay: AnnotationOverlay?
    /// Where the CURRENT target is on screen, or nil when its geometry
    /// couldn't be resolved. Read through a closure, not captured by value —
    /// a source change moves it, and closing over the value would leave a
    /// granted viewer's clicks landing on a window they've moved off. Guarded by `lock`.
    private var liveRegion: ScreenRegion?
    /// The item the live share is capturing. Held so a source change can be
    /// told apart from a restart, and so teardown releases it.
    private var liveItem: WGC.CaptureItem?
    /// The sharer's voice for this share. Owns its own lock, deliberately NOT
    /// guarded by `lock`; shared ordering hazards with the GTK engine — see
    /// `SharerVoiceSession`.
    private let voiceSession = SharerVoiceSession()
    /// Which share attempt this session is on, which grant snapshot was last
    /// applied, and who was invited before there was a server to tell.
    ///
    /// `beginSharing` releases nothing while awaiting `newServer.start()`
    /// (tsnet bring-up, minutes on an interactive login), so a `stopSharing()`
    /// can land mid-flight. Every callback carries its generation and drops
    /// itself when stale.
    ///
    /// A value type behind `lock` — the GTK engine holds the same state
    /// machine actor-isolated instead, and neither isolation model leaks
    /// into the other's.
    private var core = SharerSessionCore()

    /// IPs invited before there was a server to tell.
    var pendingPreApprovedIPs: Set<String> { lock.withLock { core.heldInvites } }

    private var status = Status()
    /// The gate to apply to the next share, and the running one. Held here
    /// (not just on the server) since the setting is chosen before pressing
    /// Share. Defaults on: the server itself defaults OFF, so this wrapper
    /// makes forgetting fail closed.
    private var requireApproval = true

    // MARK: Sharer drawing — state
    //
    // Own lock, not `lock`: arming blocks on another thread building a
    // window, and holding the status lock across that would stall every
    // unrelated publish. One-way ordering — `drawingLock` may be held while
    // taking `lock` (via `update`), never the reverse.
    private let drawingLock = NSLock()
    /// The sharer's own canvas: the same `AnnotationStore` every viewer runs.
    private let drawing = AnnotationStore()
    /// Which tool is armed, and what a refusal to arm means. Portable and
    /// tested on Linux CI — see `SharerDrawingLatch`.
    private var drawingLatch = SharerDrawingLatch()
    /// The live click-swallowing window. Nil whenever nothing is armed —
    /// the invariant the whole feature rests on.
    private var drawingSurface: SharerDrawingSurface?
    /// Where the shared content is — the same rect the injector and overlay
    /// got, so all three agree what a normalized coordinate means.
    private var drawingRegion: ScreenRegion?

    /// Whether this machine can capture at all — checked before any UI is
    /// offered, so an unsupported Windows build is a sentence rather than a
    /// share that fails halfway.
    public var isSupported: Bool { WGC.isSupported }

    /// Show the capture picker. **Main thread only** (see the type comment).
    ///
    /// - Returns: the chosen target, or nil if the user dismissed the picker
    ///   — a decision, not an error.
    @MainActor
    public func pickTarget() throws -> WGC.CaptureItem? {
        do {
            return try WGC.CaptureItem.pick(ownerWindow: nil)
        } catch WGC.Error.cancelled {
            return nil
        }
    }

    /// Bring up the sharer's tsnet node and start capturing `item`.
    ///
    /// `nonisolated`/`async`: runs on the global executor, so tsnet bring-up
    /// never occupies the UI thread. Remote control is enabled automatically
    /// when the target's screen rect can be resolved (`resolveControlRegion`);
    /// when it can't, the reason lands in the published status.
    /// - Parameter existingNode: the app's already-signed-in tsnet node.
    ///   **Supply it** — without one the server brings up a second machine
    ///   identity needing its own interactive login, and the share waits at
    ///   that login forever.
    /// - Parameter linkOnly: run with **no tsnet node at all** — started
    ///   signed out, guest tunnel as the only socket; every viewer arrives as
    ///   a guest at the mandatory approval gate.
    public func beginSharing(
        item: WGC.CaptureItem,
        hostname: String,
        statePath: String,
        quality: QualitySettings,
        existingNode: TailscaleNode? = nil,
        controlListener: TailscreenControlListener? = nil,
        linkOnly: Bool = false
    ) async throws {
        let generation = beginShareGeneration()
        // Say so before the slow parts (encoder, server, tsnet bring-up) —
        // this engine used to report all of it as "Not sharing".
        update { $0.phase = .starting }
        // A capture FACTORY, not an instance: the server respawns the backend
        // to restart capture, and closing over the item is what re-targets
        // the same window without asking the user again.
        // Resolve WHERE the target is before building the server: whether an
        // injector exists decides the advertised `.remoteControl` capability.
        let region = Self.resolveControlRegion(for: item)
        let regionNote: String
        switch region {
        case .success:
            regionNote = ""
        case .failure(let reason):
            // Names BOTH features, since both are gated on this one answer.
            regionNote = "Remote control and annotations are off — \(reason)"
        }

        // A resolved region means remote control is offered; an unresolved
        // one means no injector, so the server withholds `.remoteControl`.
        var injector: WindowsInputInjector?
        var annotationOverlay: AnnotationOverlay?
        var resolvedRegion: ScreenRegion?
        if case .success(let resolved) = region {
            resolvedRegion = resolved
            // Re-reads on every activation/source-change; unknown geometry
            // yields nil, so the injector DROPS events rather than
            // misplacing them on the previous window.
            injector = WindowsInputInjector(regionProvider: { [weak self] in
                self?.lock.withLock { self?.liveRegion }
            })
            // Annotations gate on the same rect for the same reason — a
            // target with unknown geometry gets neither, not strokes drawn wrong.
            annotationOverlay = AnnotationOverlay(
                region: AnnotationOverlay.Region(
                    x: resolved.x, y: resolved.y,
                    width: resolved.width, height: resolved.height))
        }
        lock.withLock {
            overlay = annotationOverlay
            liveRegion = resolvedRegion
            liveItem = item
        }
        let injectorAvailable = injector != nil
        let overlayAvailable = annotationOverlay != nil
        // Nothing is created yet — the click-swallowing surface comes into
        // existence only when a tool is armed.
        drawingLock.withLock {
            drawingRegion = resolvedRegion
            drawingSurface = nil
            drawingLatch = SharerDrawingLatch()
        }

        // The timings hook is on the concrete backend, not the
        // `CaptureEncoding` seam, so it's attached inside the factory —
        // meaning a restart's fresh backend keeps reporting.
        let onTimings: @Sendable (CaptureTimings) -> Void = { [weak self] timings in
            self?.update { $0.timings = timings }
        }
        let onPreview: @Sendable (ThumbnailScaler.Thumbnail) -> Void = { [weak self] thumbnail in
            self?.update { $0.preview = thumbnail }
        }
        let newServer = TailscaleScreenShareServer(
            captureFactory: {
                let encoder = WGCCaptureEncoder(item: item)
                encoder.onTimings = onTimings
                encoder.onPreviewThumbnail = onPreview
                return encoder
            },
            inputInjector: injector,
            // Advertised only when an overlay actually exists. The capability
            // means "your strokes will appear on my screen", so a share with
            // no resolvable geometry — and therefore no overlay — must not
            // claim it, exactly as it must not claim `.remoteControl`.
            rendersAnnotations: annotationOverlay != nil,
            // Always on: unlike remote control/annotations this needs no
            // resolvable geometry — it's just a prompt with a click.
            promptsForLinks: true
        )
        // The one recorder the host installed, if any. Same seam the macOS app
        // and the GTK engine use; nil when diagnostics are off, which is the
        // stable-release default.
        DiagnosticsCenter.shared.recorder?.beginSession()
        newServer.recorder = DiagnosticsCenter.shared.recorder
        // Every callback below carries `generation`: a server this session has
        // let go of must not paint over the one that replaced it. The stop
        // that drops it can land inside the `start()` await further down, which
        // spans tsnet bring-up.
        newServer.onAnnotationReceived = { [weak self] op in
            // Fires on the control-channel thread. The overlay is
            // thread-safe and redraws only when the op changed something,
            // which matters because a pen drag sends one every few
            // milliseconds.
            guard let self, self.isCurrentShare(generation) else { return }
            self.lock.withLock { self.overlay }?.apply(op)
        }
        wireSharerDrawing(overlay: annotationOverlay, server: newServer)
        let inkColor = drawing.color
        let name = item.displayName

        newServer.onViewersChanged = { [weak self] viewers in
            guard let self, self.isCurrentShare(generation) else { return }
            let rows = viewers.map {
                ConnectedViewer(
                    id: $0.id, displayName: $0.displayName,
                    stableID: $0.stableID,
                    health: $0.health, isGuest: $0.isGuest)
            }
            self.update {
                $0.viewerCount = rows.count
                $0.viewers = rows
            }
            self.noteRoster()
        }
        newServer.onPendingViewersChanged = { [weak self] pending in
            // Fires on a network thread; `update` publishes and the app hops.
            guard let self, self.isCurrentShare(generation) else { return }
            self.update {
                $0.pendingViewers = pending.map {
                    PendingViewer(
                        id: $0.id, displayName: $0.displayName,
                        stableID: $0.stableID, isGuest: $0.isGuest)
                }
            }
            self.noteRoster()
        }
        newServer.onControlRequestsChanged = { [weak self] requests in
            guard let self, self.isCurrentShare(generation) else { return }
            self.update { $0.controlRequests = requests }
        }
        newServer.onLinkOffersChanged = { [weak self] offers in
            guard let self, self.isCurrentShare(generation) else { return }
            self.update { $0.linkOffers = offers }
        }
        newServer.onControlGrantChanged = { [weak self] _, grant in
            guard let self, self.isCurrentShare(generation) else { return }
            self.update { $0.controlGrantedTo = grant?.displayName }
        }
        // Installed HERE, before `start()`, and never reassigned: the
        // server's callbacks are bare stored vars its receive thread reads with no lock.
        newServer.onAudioReceived = voiceSession.inboundHandler
        // Tunnel-level eviction: a Deny also closes the guest's tunnel and
        // denylists their node key for the link's life.
        newServer.onGuestViewerDenied = { [link] ip in
            Task { await link.evict(ip: ip) }
        }
        newServer.onCaptureStopped = { [weak self] error in
            guard let self, self.isCurrentShare(generation) else { return }
            // Ends here, not only in `stopSharing`: a link-only `beginSharing`
            // still suspended in bootstrap would otherwise republish
            // `isSharing` for a capture that already died.
            self.endShareGeneration()
            // Before the status push, so `micAvailable = false` agrees with
            // reality, and so a dead capture doesn't leave a click-swallowing
            // window over a desktop no longer sharing anything.
            self.stopVoice()
            self.teardownDrawing()
            // Captured inside the locked body: this task reaches the actor a
            // hop later, and a Stop → Start meanwhile can have minted a
            // replacement link an unscoped teardown would close.
            var minted: String?
            self.update {
                minted = $0.linkToken
                $0.phase = error.map { .failed("\($0)") } ?? .idle
                $0.viewerCount = 0
                $0.viewers = []
                $0.pendingViewers = []
                $0.linkOffers = []
                $0.message = error.map { "Sharing stopped: \($0)" } ?? ""
                $0.remoteControlAvailable = false
                $0.annotationsAvailable = false
                $0.drawingAvailable = false
                $0.micAvailable = false
                $0.micOn = false
                $0.linkToken = nil
                $0.linkBusy = false
                $0.linkIsOnlyWayIn = false
            }
            // The server drives its own teardown; only the guest node
            // remains. Passed too so a `setLinkSharing(true)` still in
            // flight can't publish a token onto a dead share's capture.
            Task { [link = self.link, server = newServer] in
                await link.teardown(for: server, mintedToken: minted)
            }
        }

        // Publish the server, then assert the gate — in that order and both
        // before `start`, or a flip landing in between finds no server to
        // push to, or leaves a window where an already-waiting peer's HELLO
        // sees an open door.
        let (gate, invited) = lock.withLock { () -> (Bool, Set<String>) in
            server = newServer
            return (requireApproval, core.drainInvites())
        }
        newServer.setRequireApproval(gate)
        // Anyone whose ask this machine accepted before the server existed.
        for ip in invited { newServer.preApproveViewer(ip: ip) }
        // Before the first HELLO can arrive, so a blocked peer is rejected on
        // its first attempt.
        newServer.setAccessPolicies(access.policies)
        update {
            $0.requireApproval = gate
            $0.target = name
            $0.message = "Starting…"
            $0.remoteControlAvailable = injectorAvailable
            $0.annotationsAvailable = overlayAvailable
            $0.drawingAvailable = overlayAvailable
            $0.activeDrawingTool = nil
            $0.drawingNote = nil
            $0.drawingInkColor = inkColor
        }

        // On Windows the item IS the selection; kind still matters — the
        // encoder rejects `.application`, which one item can't express.
        let selection = PickerSelection(
            kind: .display, displayID: nil, windowID: nil, bundleIDs: [])
        let selectionData = try JSONEncoder().encode(selection)

        // Omitting the argument when unset (rather than spelling out a
        // default) keeps `kDefaultControlURL` out of the app target.
        let controlURL = ProcessInfo.processInfo.environment["TAILSCREEN_TS_CONTROL_URL"]
        let authKey = ProcessInfo.processInfo.environment["TAILSCREEN_TS_AUTHKEY"]
        do {
            if linkOnly {
                // Guest node comes up first (it's the whole transport).
                // `startLinkOnly` unwinds its own node on failure, so the
                // catch below has only the server to clear.
                update {
                    $0.linkIsOnlyWayIn = true
                    $0.linkBusy = true
                }
                let token = try await link.startLinkOnly(
                    on: newServer, filterData: selectionData, quality: quality)
                // Only once still current — a token on screen for a stopped
                // share admits people to nothing.
                guard isCurrentShare(generation) else {
                    lock.withLock { if server === newServer { server = nil } }
                    await newServer.stop()
                    // Scoped to the token this attempt minted: a replacement
                    // share may already have minted its own link.
                    await link.teardown(mintedToken: token)
                    return
                }
                // `linkBusy` deliberately stays true — it's what the welcome
                // pane reads as "a start is in flight"; clearing it now would
                // let a second click start a second share.
                update { $0.linkToken = token }
            } else if let controlURL {
                try await newServer.start(
                    hostname: hostname, authKey: authKey, path: statePath,
                    controlURL: controlURL, filterData: selectionData, quality: quality,
                    existingNode: existingNode, controlListener: controlListener)
            } else {
                try await newServer.start(
                    hostname: hostname, authKey: authKey, path: statePath,
                    filterData: selectionData, quality: quality,
                    existingNode: existingNode, controlListener: controlListener)
            }
        } catch {
            // Clear only if this session still points at THIS server — a
            // `stopSharing()` that landed inside the await may have already
            // published a newer share.
            lock.withLock { if server === newServer { server = nil } }
            if isCurrentShare(generation) {
                update {
                    $0.phase = .failed("\(error)")
                    $0.message = ""
                    // `startLinkOnly` already closed its own guest node.
                    $0.linkToken = nil
                    $0.linkBusy = false
                    $0.linkIsOnlyWayIn = false
                }
            }
            throw error
        }
        // `start()` spans tsnet bring-up (minutes, on interactive login), so
        // a stop can have landed inside it — stop here and publish nothing.
        guard isCurrentShare(generation) else {
            await newServer.stop()
            return
        }
        startVoice(on: newServer)

        update {
            $0.phase = .sharing
            $0.message = regionNote
            // With the share now live, the bootstrap is over — published in
            // the same snapshot so no observer sees "not sharing, not busy"
            // for a link-only share that is up.
            $0.linkBusy = false
        }
    }

    /// Open a share attempt; everything stamped with an older one is ignored.
    /// The rules are `SharerSessionCore`'s and are pinned there for both hosts;
    /// what is this session's is only that they are taken under `lock`.
    ///
    /// Internal, not private, so `WindowsShareSessionTests` can drive the
    /// stamp with no node and no capture item behind it.
    func beginShareGeneration() -> UInt64 {
        lock.withLock { core.beginShare() }
    }

    /// Close the current share attempt — a stop, or a capture that died.
    func endShareGeneration() {
        lock.withLock { core.endShare() }
    }

    /// Whether `generation` is still the live share attempt.
    func isCurrentShare(_ generation: UInt64) -> Bool {
        lock.withLock { core.isCurrentShare(generation) }
    }

    /// Turn the approval gate on or off, now and for the next share.
    ///
    // MARK: Access control

    /// Remembered allow/deny, plus the queue for decisions made before a
    /// peer's identity resolved. Portable and tested on Linux CI
    /// (`SharerAccessCoordinatorTests`) — the session only forwards taps and
    /// re-publishes. Built lazily against `%LOCALAPPDATA%\Tailscreen`.
    private let injectedAccessStore: PeerAccessStore?

    private lazy var access: SharerAccessCoordinator = {
        let coordinator = SharerAccessCoordinator(
            store: injectedAccessStore
                ?? PeerAccessStore(directory: AccountProfileLayout.windowsLocalAppData().root))
        coordinator.onPoliciesChanged = { [weak self] policies in
            self?.lock.withLock { self?.server }?.setAccessPolicies(policies)
            // Re-publish: a block on somebody already watching expels them, so
            // the roster the sharer is looking at is about to be wrong.
            self?.update { _ in }
        }
        return coordinator
    }()

    /// What is remembered about a peer, for a roster row's label.
    public func remembered(stableID: String?) -> PeerPolicy? {
        access.remembered(stableID: stableID)
    }

    /// Whether a decision on this row is queued behind identity resolution.
    public func isDeferred(rowID: String) -> Bool { access.isDeferred(rowID: rowID) }

    /// "Always Allow" / "Deny & Block" on a roster row.
    public func remember(
        rowID: String, stableID: String?, displayName: String, policy: PeerPolicy
    ) {
        access.remember(
            rowID: rowID, stableID: stableID, displayName: displayName, policy: policy)
        update { _ in }
    }

    /// Drop what is remembered about a row's peer, and cancel any queued
    /// decision for it.
    public func forget(rowID: String, stableID: String?) {
        access.forget(rowID: rowID, stableID: stableID)
        update { _ in }
    }

    /// One-time disconnect of a connected viewer. Nothing is remembered —
    /// their next HELLO goes back through the normal admission gate, unlike
    /// Deny & Block.
    public func disconnectViewer(_ id: String) {
        lock.withLock { server }?.disconnectViewer(addr: id)
    }

    /// Feed the access layer both rosters together — a snapshot of only one
    /// would prune the other's queued intents when a peer moves between them.
    private func noteRoster() {
        let status = lock.withLock { self.status }
        let identities =
            status.viewers.map {
                ViewerRosterDecision.RosterIdentity(
                    id: $0.id, stableID: $0.stableID, displayName: $0.displayName)
            }
            + status.pendingViewers.map {
                ViewerRosterDecision.RosterIdentity(
                    id: $0.id, stableID: $0.stableID, displayName: $0.displayName)
            }
        if access.noteRoster(identities) { update { _ in } }
    }

    /// Takes effect mid-share: turning it off also drains anyone already
    /// parked (minus remembered-deny), admitting a queue in one click.
    public func setRequireApproval(_ enabled: Bool) {
        let server = lock.withLock { () -> TailscaleScreenShareServer? in
            requireApproval = enabled
            return self.server
        }
        server?.setRequireApproval(enabled)
        update { $0.requireApproval = enabled }
    }

    // MARK: Link sharing (share-by-token)

    /// The portable link half — guest node lifecycle, attach/detach, the
    /// deny→tunnel-evict mapping — shared verbatim with the GTK engine.
    private let link = SharerLinkSession()

    /// The card's Share via Link toggle. `on` brings the guest node up and
    /// attaches its listener to the running server; `off` drops every guest
    /// and kills the token. No-op while idle or busy.
    public func setLinkSharing(_ on: Bool) {
        let (server, busy, linkOnly) = lock.withLock {
            (self.server, self.status.linkBusy, self.status.linkIsOnlyWayIn)
        }
        // A link-only share has nothing to toggle: the link IS the share.
        guard !busy, !linkOnly, let server else { return }
        update { $0.linkBusy = true }
        Task { [link] in
            var token: String?
            if on {
                do {
                    token = try await link.enable(on: server)
                } catch {
                    FileHandle.standardError.write(
                        Data("warning: share link failed to start (\(error))\n".utf8))
                }
            } else {
                await link.disable(on: server)
            }
            self.update {
                $0.linkToken = token
                $0.linkBusy = false
            }
        }
    }

    /// New Link: the old token dies the moment this starts (current guests
    /// drop with it) and a fresh node key mints a fresh one.
    public func rotateLink() {
        let (server, state) = lock.withLock {
            (self.server, (self.status.linkBusy, self.status.linkToken))
        }
        guard !state.0, state.1 != nil, let server else { return }
        update { $0.linkBusy = true }
        Task { [link] in
            var token: String?
            do {
                token = try await link.rotate(on: server)
            } catch {
                FileHandle.standardError.write(
                    Data("warning: share link rotation failed (\(error))\n".utf8))
            }
            self.update {
                $0.linkToken = token
                $0.linkBusy = false
            }
        }
    }

    /// Waive the approval gate once for a peer this machine INVITED — else
    /// they'd be asked twice, seconds apart. Held until a server exists,
    /// since accept happens before the share starts. One-time and
    /// non-overriding: does not beat a remembered `.deny`.
    public func preApproveViewer(ip: String) {
        let server: TailscaleScreenShareServer? = lock.withLock {
            core.noteInvite(ip, hasServer: self.server != nil)
            return self.server
        }
        server?.preApproveViewer(ip: ip)
    }

    /// Admit a viewer parked at the gate. `id` is a `PendingViewer.id`.
    public func approveViewer(_ id: String) {
        let server = lock.withLock { self.server }
        server?.approveViewer(addr: id)
    }

    /// Reject a viewer parked at the gate. One-time: nothing is remembered, so
    /// the same peer's next HELLO parks again rather than being blocked.
    public func denyViewer(_ id: String) {
        let server = lock.withLock { self.server }
        server?.denyViewer(addr: id)
    }

    /// Answer a pending remote-control request. Returns false when the
    /// injector is absent (an unresolvable capture region) — Windows has no
    /// UIPI-style permission to ask for.
    @discardableResult
    public func grantControl(to requestID: UUID) -> Bool {
        let server = lock.withLock { self.server }
        return server?.grantControl(toConnectionID: requestID) ?? false
    }

    public func declineControl(_ requestID: UUID) {
        let server = lock.withLock { self.server }
        server?.declineControlRequest(connectionID: requestID)
    }

    /// Take control back. The injector's revoke seal drops anything already
    /// queued and releases a button held mid-drag.
    public func revokeControl() {
        let server = lock.withLock { self.server }
        server?.revokeControl(reason: "the sharer took control back")
    }

    /// The sharer clicked Open: removes the offer and hands back its URL for
    /// the caller to open. Returns nil if it was already taken/dismissed
    /// (double-click, or the connection dropped it first).
    @discardableResult
    public func takeLinkOffer(id: UUID) -> LinkOfferInfo? {
        let server = lock.withLock { self.server }
        return server?.takeLinkOffer(id: id)
    }

    /// The sharer clicked Dismiss: removes the offer, opens nothing.
    public func dismissLinkOffer(id: UUID) {
        let server = lock.withLock { self.server }
        server?.dismissLinkOffer(id: id)
    }

    /// Re-point a live share at a different target, keeping the viewers.
    ///
    /// Remote control/annotations are gated on the target's screen geometry,
    /// which display→window can take away (a window has no resolvable
    /// rect): `liveRegion` becomes nil (injector DROPS events instead of
    /// misplacing them), and a live grant is REVOKED with a reason the
    /// viewer can read — the `ScreenShareCaps` bit stays advertised (no way
    /// to withdraw it), matching the "Allow control requests" toggle's own behavior.
    ///
    /// The annotation overlay is rebuilt, not moved — it owns a window on its
    /// own pump thread, and dropping it is how that thread is joined.
    ///
    /// - Returns: whether the change took effect. False when nothing is sharing.
    @discardableResult
    public func changeSource(to item: WGC.CaptureItem) async throws -> Bool {
        guard let running = lock.withLock({ server }) else { return false }

        let region = Self.resolveControlRegion(for: item)
        var resolved: ScreenRegion?
        if case .success(let rect) = region { resolved = rect }

        // Rebuilt before the swap, so the strokes that arrive with the very
        // first frame of the new source already have somewhere to land.
        var newOverlay: AnnotationOverlay?
        if let resolved {
            newOverlay = AnnotationOverlay(
                region: AnnotationOverlay.Region(
                    x: resolved.x, y: resolved.y,
                    width: resolved.width, height: resolved.height))
        }

        let previousOverlay = lock.withLock { () -> AnnotationOverlay? in
            let old = overlay
            overlay = newOverlay
            liveRegion = resolved
            liveItem = item
            return old
        }
        previousOverlay?.clear()
        drawingLock.withLock { drawingRegion = resolved }

        if resolved == nil {
            // Told, not silently ignored — else the person driving would
            // keep clicking and wonder why nothing moves.
            running.revokeControl(
                reason: "the sharer switched to a window, which cannot be controlled remotely")
            teardownDrawing()  // no rectangle left to normalize against
        }

        let onTimings: @Sendable (CaptureTimings) -> Void = { [weak self] timings in
            self?.update { $0.timings = timings }
        }
        let onPreview: @Sendable (ThumbnailScaler.Thumbnail) -> Void = { [weak self] thumbnail in
            self?.update { $0.preview = thumbnail }
        }
        // Cleared so the card shows nothing until the new backend's first
        // frame, rather than the old target for another second.
        update { $0.preview = nil }
        // The factory travels with the data: swapping the selection bytes
        // alone would restart the old target.
        return try await running.changeSource(
            filterData: Self.windowsSelectionData(),
            captureFactory: {
                let encoder = WGCCaptureEncoder(item: item)
                encoder.onTimings = onTimings
                encoder.onPreviewThumbnail = onPreview
                return encoder
            })
    }

    /// The `PickerSelection` every Windows share sends. Always the same
    /// bytes — the item IS the selection — but `kind` still matters, since
    /// the encoder rejects `.application`.
    static func windowsSelectionData() -> Data {
        let selection = PickerSelection(
            kind: .display, displayID: nil, windowID: nil, bundleIDs: [])
        return (try? JSONEncoder().encode(selection)) ?? Data()
    }

    public func stopSharing() async {
        // Unconditionally first: nothing the ending server says reaches this
        // session after this.
        endShareGeneration()
        // Before anything that can await or fail — a drawing surface
        // outliving its share swallows every click with nothing to explain it.
        teardownDrawing()
        let running = lock.withLock {
            let value = server
            server = nil
            return value
        }
        let liveOverlay = lock.withLock { () -> AnnotationOverlay? in
            let value = overlay
            overlay = nil
            return value
        }
        liveOverlay?.clear()
        stopVoice()
        // Scoped to this server so a link toggled on mid-share and still
        // bootstrapping is invalidated with it, not a replacement's.
        await link.teardown(for: running)
        guard let running else {
            update {
                $0.linkToken = nil
                $0.linkBusy = false
                $0.linkIsOnlyWayIn = false
            }
            return
        }
        await running.stop()
        update {
            $0.phase = .idle
            $0.viewerCount = 0
            $0.pendingViewers = []
            $0.message = ""
            $0.remoteControlAvailable = false
            $0.annotationsAvailable = false
            $0.drawingAvailable = false
            $0.micAvailable = false
            $0.micOn = false
            $0.timings = nil
            $0.preview = nil  // else a stale preview reads exactly like a live one
            $0.linkToken = nil
            $0.linkBusy = false
            $0.linkIsOnlyWayIn = false
        }
    }

    // MARK: Sharer drawing

    /// Connect the sharer's own strokes to their screen and to the viewers.
    /// Two independent directions: a sharer with no viewers still sees their
    /// own pen, and a stroke reaching viewers doesn't depend on the overlay.
    private func wireSharerDrawing(
        overlay: AnnotationOverlay?, server: TailscaleScreenShareServer
    ) {
        drawing.resetForNewSession()
        drawing.onLocalOp = { [weak server] op in
            // Queued, never one task per op — a reordered `.undo` overtaking
            // its `.add` strands the stroke on every viewer's canvas.
            server?.enqueueAnnotationBroadcast(op)
        }
        // Bound to the overlay instance, not read back through `self.overlay`
        // — this fires on the drawing surface's pump thread and must not
        // reach for the status lock.
        drawing.setRedraw { [weak overlay, drawing] in
            overlay?.setLocalStrokes(drawing.visibleAnnotations)
        }
    }

    /// Arm a drawing tool, or disarm with nil. Re-selecting the armed tool
    /// disarms it.
    ///
    /// Arming puts a window over the shared region that swallows every
    /// click — the feature, and the hazard, since the hub window that would
    /// turn it off is now underneath it. Three things make it survivable:
    /// the surface refuses to arm without the keyboard too (Escape is always
    /// a way out); it covers the shared region, not the whole desktop; and
    /// losing the keyboard (Alt-Tab, Windows key) ends drawing rather than
    /// silently keeping the mouse.
    public func selectDrawingTool(_ tool: AnnotationTool?) {
        typealias Published = (AnnotationTool?, SharerDrawingRefusal?)
        let (activeTool, refusal) = drawingLock.withLock { () -> Published in
            // Latch the tool BEFORE the surface can exist — it starts
            // delivering the instant it's up, and a press beating this
            // assignment would commit with whatever tool was last set.
            if let tool, tool != drawingLatch.activeTool { drawing.mode = .drawing(tool) }
            drawingLatch.select(tool, surface: armDrawingSurfaceLocked)
            drawing.mode = drawingLatch.activeTool.map { .drawing($0) } ?? .off
            return (drawingLatch.activeTool, drawingLatch.refusal)
        }
        update {
            $0.activeDrawingTool = activeTool
            $0.drawingNote = refusal.map(Self.note(for:))
        }
    }

    /// The latch's surface seam, on the Windows side. **`drawingLock` held.**
    private func armDrawingSurfaceLocked(_ tool: AnnotationTool?) -> SharerDrawingArmResult {
        switch SharerDrawingSurfacePlan.plan(
            tool: tool, hasSurface: drawingSurface != nil, hasRegion: drawingRegion != nil)
        {
        case .release:
            // Destroying is the disarm — no style bit to restore, so no way
            // for it to half-happen.
            drawingSurface = nil
            return .armed
        case .keep:
            // Only the tool changed — leave the window (and its hard-won focus) alone.
            return .armed
        case .refuse(let why):
            return .refused(why)
        case .create:
            break
        }
        guard let region = drawingRegion else { return .refused(.noSurface) }

        switch SharerDrawingSurface.arm(
            region: region,
            onPointer: { [weak self] phase, x, y in
                // On the surface's pump thread. Straight into the store, which
                // is lock-guarded and whose redraw posts to the overlay's own
                // thread — no session lock is taken from here, which is what
                // keeps this off the path `drawingLock` is holding.
                guard let self else { return }
                let point = CGPoint(x: x, y: y)
                switch phase {
                case 0: self.drawing.beginStroke(at: point)
                case 1: self.drawing.extendStroke(to: point)
                default: self.drawing.endStroke()
                }
            },
            onRelease: { [weak self] in
                // Escape, or the surface losing the keyboard. **Hopped, not
                // called through.** This fires on the pump thread, and
                // disarming destroys the surface by joining that very thread —
                // calling straight through would deadlock the sharer's desktop
                // in the armed state, which is the one outcome worse than not
                // shipping the feature.
                guard let self else { return }
                DispatchQueue.global().async { self.releaseDrawing() }
            }
        ) {
        case .armed(let surface):
            drawingSurface = surface
            return .armed
        case .refused(let why):
            return .refused(why)
        }
    }

    /// The sharer pressed Escape, or the surface lost the keyboard.
    private func releaseDrawing() {
        let refusal = drawingLock.withLock { () -> SharerDrawingRefusal? in
            drawingLatch.release(surface: armDrawingSurfaceLocked)
            drawing.mode = .off
            return drawingLatch.refusal
        }
        update {
            $0.activeDrawingTool = nil
            $0.drawingNote = refusal.map(Self.note(for:))
        }
    }

    /// Undo the sharer's own last stroke. Viewers' strokes are theirs to undo.
    public func undoDrawing() {
        drawing.undo()
    }

    /// Clear every stroke, from anyone. The sharer owns the screen.
    public func clearDrawing() {
        drawing.clearAll()
        lock.withLock { overlay }?.clear()
    }

    /// Drop the drawing surface, whatever this session believes about it.
    /// Unconditional on purpose — callable from any teardown path, including
    /// one where capture died on its own.
    private func teardownDrawing() {
        drawingLock.withLock {
            drawingLatch.teardown(surface: armDrawingSurfaceLocked)
            drawing.mode = .off
        }
        update {
            $0.activeDrawingTool = nil
            $0.drawingNote = nil
        }
    }

    /// A refusal, in a sentence for the person who pressed the button.
    private static func note(for refusal: SharerDrawingRefusal) -> String {
        switch refusal {
        case .noSurface:
            return "Drawing needs a capture target this app can locate on screen."
        case .noKeyboard:
            return "Windows would not give the drawing surface the keyboard, "
                + "so Esc could not have stopped it. Click this window, then try again."
        }
    }

    // MARK: Voice

    /// Open the microphone and start hearing viewers, for this share only.
    /// Best-effort: a machine with no capture device just shows no mic
    /// control. The failure goes into the status message rather than being
    /// thrown — a working share must not be torn down over audio.
    private func startVoice(on server: TailscaleScreenShareServer) {
        guard let microphoneFactory else { return }
        do {
            try voiceSession.start(
                microphone: try microphoneFactory(),
                send: { [weak server] packet in server?.sendAudioRTP(packet) })
        } catch {
            update { $0.message = "Sharing (no microphone: \(error))" }
        }
    }

    func stopVoice() {
        voiceSession.stop()
    }

    /// Flip the sharer's microphone. A no-op with no device open, which is also
    /// when the share card draws no control.
    public func toggleMic() {
        voiceSession.toggleMic()
    }

    /// Where the picked target sits on screen, or why that is unknowable. The
    /// item carries no HMONITOR, so its SIZE is matched against enumerated
    /// monitors — the decision is `WindowsCaptureRegion` in TailscreenProtocol,
    /// tested on Linux CI (notably the two-identical-monitors case that must
    /// decline rather than guess).
    static func resolveControlRegion(
        for item: WGC.CaptureItem
    ) -> Result<SendInputInjector.Region, WindowsCaptureRegion.Failure> {
        let size = item.size
        return WindowsCaptureRegion.resolve(
            itemWidth: size.width, itemHeight: size.height,
            monitors: SendInputInjector.monitors())
    }

    /// Mutate the published status under the lock and publish the result.
    /// The callback fires OUTSIDE the lock — holding it across the main-actor
    /// hop is how a UI callback deadlocks against a capture thread.
    private func update(_ body: (inout Status) -> Void) {
        let snapshot: Status = lock.withLock {
            body(&status)
            return status
        }
        onStatus?(snapshot)
    }
}
