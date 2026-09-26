import Foundation
import TailscaleKit
import TailscreenAudio
import TailscreenProtocol
import TailscreenSharer
import TailscreenTransport

/// Runs a share on Linux: the portable `TailscaleScreenShareServer` driven by
/// whichever capture backend the app chose, plus access control, the drawing
/// latch, voice, the idle control listener's ask-to-share inbox, and the
/// server's whole lifecycle.
///
/// The Linux twin of `TailscreenSharerWGC.WindowsShareSession` — a package
/// type so Linux CI builds/tests it headless with no UI toolkit. The app
/// keeps only the thin observable façade (`SharerModel`).
///
/// **Deliberate difference from Windows:** this engine is `@MainActor` rather
/// than lock-guarded — the node already exists by share start (no bring-up to
/// keep off the UI thread). Do not "unify" the two shapes without re-reading
/// `onControlGrantChanged`.
@MainActor
public final class LinuxShareSession {
    /// The shared sharer lifecycle (`ShareBringUpPhase`, TailscreenProtocol).
    /// These four cases were written here first and the portable type lifted
    /// them unchanged, so this is a rename of the TYPE only — every case, and
    /// every call site, is what it was.
    public typealias Phase = ShareBringUpPhase

    /// Why a share stopped being live — the façade's cue for the cleanup only
    /// it can do (notifications, the portal session, the preview).
    public enum EndReason: Sendable {
        /// `stopSharing()` — the person pressed stop.
        case stopped
        /// The capture died on its own (or the compositor's own stop button).
        case captureStopped
        /// `beginShare`'s server start threw; nothing ever went live.
        case startFailed
    }

    /// Somebody currently watching, as the share card needs them.
    ///
    /// `stableID` rides along because remember/forget actions key on Tailscale
    /// StableNodeID, not the connection. Nil until the netmap lookup lands
    /// (`SharerAccessCoordinator` queues around that).
    public struct ConnectedViewer: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let stableID: String?
        /// A share-by-token guest: no StableNodeID ever resolves (the
        /// remember actions don't apply), and the row carries a badge.
        public let isGuest: Bool
        /// The link's state, straight off the server. Passed as the ENUM
        /// rather than a rendered string: this package has no string catalog,
        /// so interpolating it here put an untranslated lowercase `degraded`
        /// beside somebody's hostname in the UI. The host words it.
        public let health: ViewerHealth

        public init(
            id: String, label: String, stableID: String?, health: ViewerHealth,
            isGuest: Bool = false
        ) {
            self.id = id
            self.label = label
            self.stableID = stableID
            self.health = health
            self.isGuest = isGuest
        }
    }

    /// A viewer parked at the approval gate, as the share card needs it.
    ///
    /// `id` is the server's own viewer key — `"ip:port"`, not the bare IP.
    /// `approveViewer`/`denyViewer` look it up in the pending map, and a
    /// port-dropped IP matches nothing and silently no-ops. `label` is a
    /// hostname once the netmap lookup lands, the IP until then.
    public struct PendingViewer: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        /// See `ConnectedViewer.isGuest`.
        public let isGuest: Bool
        /// "Always Allow" / "Deny & Block" on a pending row persists under
        /// this, not the hostname a peer sends.
        public let stableID: String?

        public init(id: String, label: String, stableID: String?, isGuest: Bool = false) {
            self.id = id
            self.label = label
            self.stableID = stableID
            self.isGuest = isGuest
        }
    }

    // MARK: Host seams

    /// Supplied by the host — hands back the live tsnet node to share.
    public var nodeProvider: (() -> TailscaleNode?)?

    /// Supplied by the host — opens a capture device, or throws if there is
    /// none. A factory, not an instance: opened at share start, released at
    /// stop, so the OS mic indicator isn't lit while idle. Nil means this
    /// build has no capture backend.
    public var microphoneFactory: (() throws -> MicrophoneCapturing)?
    /// Supplied by the host — plays a viewer's decoded voice on the local
    /// device.
    public var playRemoteVoice: (([Float]) -> Void)?

    /// Supplied by the host — builds the annotation overlay at the capture's
    /// exact pixel geometry, or nil if this session cannot host one. Called
    /// before the server exists, since whether it exists is what the server advertises.
    public var makeOverlay: (() -> SharerOverlaySurface?)?

    // MARK: Host callbacks — all invoked on the main actor

    public var onPhaseChanged: ((Phase) -> Void)?
    /// Fired the moment a share stops being live, BEFORE the rosters empty —
    /// the hook where the host must stop its notifications, so reconciling the
    /// empty snapshots that follow cannot fire one "stopped watching" banner
    /// per viewer at the exact moment the sharer already decided to stop.
    public var onShareDidEnd: ((EndReason) -> Void)?
    public var onViewersChanged: (([ConnectedViewer]) -> Void)?
    public var onPendingViewersChanged: (([PendingViewer]) -> Void)?
    public var onControlRequestsChanged: (([ControlRequestInfo]) -> Void)?
    /// Links viewers sent with `.openLink`, awaiting the sharer's Open /
    /// Dismiss (TS-LNK-010: opening one is always the host's own click).
    public var onLinkOffersChanged: (([LinkOfferInfo]) -> Void)?
    /// The display name of whoever is driving this machine, or nil. Already
    /// stale-guarded — see the generation note on `lastGrantGeneration`.
    public var onControlGrantChanged: ((String?) -> Void)?
    /// The armed tool and why arming was refused, when it was. The host words
    /// the refusal; the decision stays here.
    public var onDrawingChanged: ((AnnotationTool?, SharerDrawingRefusal?) -> Void)?
    public var onVoiceChanged: ((_ micAvailable: Bool, _ micOn: Bool) -> Void)?
    public var onShareRequestsChanged: (([PendingShareRequest]) -> Void)?
    /// Something about the remembered-policy layer changed and roster rows may
    /// render differently.
    public var onAccessChanged: (() -> Void)?
    /// An ask to share was accepted — the host should start a share the way
    /// its primary button would. The asker is already pre-approved by the time
    /// this fires.
    public var onStartShareRequested: (() -> Void)?

    // MARK: State

    public private(set) var phase: Phase = .idle

    // MARK: Link sharing (share-by-token)

    /// The live share link's token, nil while the link is off. Published
    /// through `onLinkSharingChanged` so the host's card can render
    /// toggle/link/count without owning the lifecycle.
    public private(set) var linkToken: String?
    /// True while the link is being created or rotated (the relay bootstrap
    /// blocks for the network). Toggle flips are ignored meanwhile.
    public private(set) var linkBusy = false
    /// This share was started signed out: the guest tunnel is its only
    /// socket, so the link is the only way in and there is no off position
    /// short of stopping. The card states the mode rather than drawing a
    /// toggle that would refuse to flip.
    public private(set) var isLinkOnlyShare = false
    /// Fired on every (token, busy, link-only) movement, on the main actor.
    public var onLinkSharingChanged: ((String?, Bool, Bool) -> Void)?
    private let link = SharerLinkSession()

    /// The share-by-token toggle. `on` brings the guest node up and attaches
    /// its listener to the running server; `off` drops every guest and kills
    /// the token. No-op while idle — the link is minted per share.
    public func setLinkSharing(_ on: Bool) {
        // A link-only share has nothing to toggle: the link IS the share.
        guard !linkBusy, !isLinkOnlyShare, let server else { return }
        linkBusy = true
        publishLink()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if on {
                do {
                    self.linkToken = try await self.link.enable(on: server)
                } catch {
                    FileHandle.standardError.write(
                        Data("warning: share link failed to start (\(error))\n".utf8))
                    self.linkToken = nil
                }
            } else {
                await self.link.disable(on: server)
                self.linkToken = nil
            }
            self.linkBusy = false
            self.publishLink()
        }
    }

    /// New Link: the old token dies the moment this starts (current guests
    /// drop with it) and a fresh node key mints a fresh one.
    public func rotateLink() {
        guard !linkBusy, linkToken != nil, let server else { return }
        linkBusy = true
        publishLink()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.linkToken = try await self.link.rotate(on: server)
            } catch {
                FileHandle.standardError.write(
                    Data("warning: share link rotation failed (\(error))\n".utf8))
                self.linkToken = nil
            }
            self.linkBusy = false
            self.publishLink()
        }
    }

    private func publishLink() {
        onLinkSharingChanged?(linkToken, linkBusy, isLinkOnlyShare)
    }

    /// The share ended (any path): the server already told every guest, so
    /// only the guest node is left to close. Synchronous state first so the
    /// card's toggle drops with the share rather than a beat later.
    private func teardownLink(server: TailscaleScreenShareServer?) {
        // Captured before state is blanked: this task reaches the actor a
        // hop later, and an immediate Stop → Start can have minted a
        // replacement link by then. Scoped by token.
        //
        // Passing the SERVER too invalidates an in-flight `setLinkSharing(true)`
        // whose `enable` attached the listener but hadn't yet returned a
        // token when the stop landed — otherwise that mint would publish onto
        // an already-idle engine.
        let minted = linkToken
        linkToken = nil
        linkBusy = false
        isLinkOnlyShare = false
        publishLink()
        guard server != nil || minted != nil else { return }
        Task { [link] in await link.teardown(for: server, mintedToken: minted) }
    }
    /// The sharer's own drawing state — the same store the viewers run.
    public let drawing = AnnotationStore()
    public private(set) var micAvailable = false
    public private(set) var micOn = false

    private let display: String?
    private var server: TailscaleScreenShareServer?
    private var viewers: [ConnectedViewer] = []
    private var pendingViewers: [PendingViewer] = []

    /// The gate to apply to the next share, and the running one. The host
    /// persists the preference; the server's own default is OFF (right for
    /// the headless CLI sharer), so this must assert it explicitly.
    private var requireApproval = ViewerApprovalPreference.load()

    /// Viewers' strokes, drawn on this machine's own screen. Nil when the
    /// session cannot host one.
    private var overlay: SharerOverlaySurface?
    /// Granted viewers' input, replayed on this machine. Nil when this X
    /// server has no XTEST extension. Held for the share's lifetime (not
    /// handed to the server and forgotten) because the server's teardown is
    /// async and the grant must be sealed the moment sharing stops.
    private var injector: X11InputInjector?

    /// Which tool is armed and what a refusal to arm means. Decisions live in
    /// the portable tier (tested on Linux CI headless), shared with the
    /// Windows sharer to avoid the two drifting.
    private var latch = SharerDrawingLatch()

    /// The sharer's voice for this share. Shared ordering (route before
    /// device, `onStopped` before `start()`) with the Windows engine — see
    /// `SharerVoiceSession`.
    private let voiceSession = SharerVoiceSession()

    /// Which share attempt the engine is on, which grant snapshot was last
    /// applied, and who was invited before there was a server to tell.
    ///
    /// A struct (not a shared object) because the Windows engine holds the
    /// same state machine behind a lock instead, and neither isolation model
    /// leaks into the other's. Server callbacks and `beginShare`'s own
    /// continuation reach this actor through a hop the actor is released
    /// across, so a stop or a second share can land mid-flight — each closure
    /// captures its generation and drops itself when stale.
    private var core = SharerSessionCore()

    /// Remembered allow/deny, and the queue for decisions made before a
    /// peer's identity resolved. Built once and outliving each share — what a
    /// sharer decided about somebody is not a property of the session.
    private let access: SharerAccessCoordinator

    /// The whole ask-to-share flow, shared with the Windows and macOS hosts.
    private let askToShare = SharerAskToShareCoordinator()

    /// IPs accepted before there was a server to tell. Accept happens before
    /// the share starts, so the IP is held in `core` and replayed once a
    /// server exists — otherwise the invited peer would land at its own
    /// approval gate a moment after being invited.
    var pendingPreApprovedIPs: Set<String> { core.heldInvites }

    /// - Parameters:
    ///   - display: the X display shares run against; nil means `$DISPLAY`.
    ///   - accessStore: injectable for tests. The default is the same XDG root
    ///     the account registry uses — one place a user's Tailscreen state
    ///     lives.
    public init(display: String?, accessStore: PeerAccessStore? = nil) {
        self.display = display
        self.access = SharerAccessCoordinator(
            store: accessStore ?? PeerAccessStore(directory: AccountProfileLayout.xdg().root))

        askToShare.onRequestsChanged = { [weak self] requests in
            self?.onShareRequestsChanged?(requests)
        }
        askToShare.onPreApproveViewer = { [weak self] sourceKey in
            guard let self else { return }
            // Pre-approve before starting: a peer just invited must not land
            // at its own approval gate. Held for replay if no server exists
            // yet; told directly (and not remembered) if one is already running.
            self.core.noteInvite(sourceKey, hasServer: self.server != nil)
            self.server?.preApproveViewer(ip: sourceKey)
        }
        askToShare.onStartShare = { [weak self] in self?.onStartShareRequested?() }
        // Both hop: the latch moves from whichever thread opened, closed or
        // lost the device, and this actor owns the published pair.
        voiceSession.onStateChanged = { [weak self] available, on in
            Task { @MainActor in self?.applyVoiceState(available: available, on: on) }
        }
        voiceSession.onRemotePCM = { [weak self] pcm in
            Task { @MainActor in self?.playRemoteVoice?(pcm) }
        }
        askToShare.onListenerError = { (error: Error) in
            FileHandle.standardError.write(
                Data("warning: could not listen for share requests: \(error)\n".utf8))
        }
    }

    // MARK: Share lifecycle

    /// Everything after "which backend": identical for both capture paths.
    ///
    /// - Parameters:
    ///   - showsOutline: whether the overlay's rectangle genuinely matches
    ///     what's captured — a portal share passes false rather than showing
    ///     a wrong indicator.
    ///   - node: the app's signed-in tsnet node, or nil for a **link-only
    ///     share** (started signed out, guest tunnel as the only socket) —
    ///     every viewer then arrives as a guest at the mandatory approval gate.
    public func beginShare(
        node: TailscaleNode?,
        selectionData: Data,
        quality: QualitySettings,
        showsOutline: Bool,
        captureFactory: @escaping @Sendable () -> CaptureEncoding
    ) {
        let generation = beginShareGeneration()
        setPhase(.starting)

        // Overlay must exist BEFORE the server — whether it exists is what
        // the server advertises.
        let overlay = makeOverlay?() ?? nil
        if overlay == nil {
            FileHandle.standardError.write(
                Data(
                    """
                    warning: no annotation overlay (needs a compositing X11 session) — \
                    viewers' drawing tools will be disabled\n
                    """.utf8))
        }
        self.overlay = overlay

        // Likewise the injector: supplying one is what makes the server
        // advertise `.remoteControl`. Nil when this X server has no XTEST
        // extension — an injected click would otherwise silently vanish.
        let injector = Self.makeInjector(display: display)
        if injector == nil {
            FileHandle.standardError.write(
                Data(
                    """
                    warning: no input injection (this X server has no XTEST extension) — \
                    viewers will not be offered Request Control\n
                    """.utf8))
        }
        self.injector = injector

        let server = TailscaleScreenShareServer(
            captureFactory: captureFactory,
            // Server derives `.remoteControl` from whether this is non-nil.
            inputInjector: injector,
            // Claimed only when there's a real surface to draw on — otherwise
            // viewers' strokes would reach nobody, silently.
            rendersAnnotations: overlay != nil,
            // This host always shows offers to the user with Open/Dismiss —
            // never auto-opens (TS-LNK-010).
            promptsForLinks: true
        )
        // Nil when diagnostics are off (stable-release default).
        DiagnosticsCenter.shared.recorder?.beginSession()
        server.recorder = DiagnosticsCenter.shared.recorder
        // Fires on the server's control-channel thread; the overlay marshals
        // onto the GTK main thread itself.
        server.onAnnotationReceived = { [overlay] op in overlay?.apply(op) }
        wireSharerDrawing(overlay: overlay, server: server)
        // Server's own default is OFF; assert the user's setting on every start.
        server.setRequireApproval(requireApproval)
        // Push what's remembered BEFORE the first HELLO can arrive, so a
        // blocked peer is rejected on its first attempt.
        server.setAccessPolicies(access.policies)
        access.onPoliciesChanged = { [weak server] policies in
            server?.setAccessPolicies(policies)
        }
        // Each hop carries `generation` and drops itself once stale, or a
        // snapshot from a stopped server would repopulate a dead roster.
        server.onViewersChanged = { infos in
            let rows = infos.map {
                ConnectedViewer(
                    id: $0.id, label: $0.displayName, stableID: $0.stableID,
                    health: $0.health, isGuest: $0.isGuest)
            }
            Task { @MainActor [weak self] in
                guard let self, self.core.isCurrentShare(generation) else { return }
                self.applyConnected(rows)
            }
        }
        server.onPendingViewersChanged = { pending in
            // Keyed by the server's `"ip:port"` id, NOT the bare IP — see
            // `PendingViewer`. Fires off the main actor; hop.
            let waiting = pending.map {
                PendingViewer(
                    id: $0.id, label: $0.displayName, stableID: $0.stableID,
                    isGuest: $0.isGuest)
            }
            Task { @MainActor [weak self] in
                guard let self, self.core.isCurrentShare(generation) else { return }
                self.applyPending(waiting)
            }
        }
        server.onControlRequestsChanged = { [weak self] requests in
            Task { @MainActor [weak self] in
                guard let self, self.core.isCurrentShare(generation) else { return }
                self.onControlRequestsChanged?(requests)
            }
        }
        server.onLinkOffersChanged = { [weak self] offers in
            Task { @MainActor [weak self] in
                guard let self, self.core.isCurrentShare(generation) else { return }
                self.onLinkOffersChanged?(offers)
            }
        }
        server.onControlGrantChanged = { [weak self] grantGeneration, grant in
            Task { @MainActor [weak self] in
                self?.applyControlGrant(
                    share: generation, generation: grantGeneration,
                    displayName: grant?.displayName)
            }
        }
        server.onCaptureStopped = { error in
            Task { @MainActor [weak self] in
                guard let self, self.core.isCurrentShare(generation) else { return }
                self.handleCaptureStopped(error)
            }
        }
        // Tunnel-level eviction: a Deny also closes the guest's tunnel and
        // denylists their node key for the link's life.
        server.onGuestViewerDenied = { [link] ip in
            Task { await link.evict(ip: ip) }
        }
        // Installed HERE, before `start()`, and never reassigned: the
        // server's callbacks are bare stored vars its receive thread reads
        // with no lock.
        server.onAudioReceived = voiceSession.inboundHandler
        // Anyone whose ask was accepted before this server existed, replayed
        // BEFORE start so the gate already knows them.
        for ip in core.drainInvites() { server.preApproveViewer(ip: ip) }
        self.server = server

        // Whatever else was parked is stale now — leaving the rows would
        // offer buttons that start a second share.
        clearShareRequests()

        Task { @MainActor in
            do {
                // Non-nil only on the link-only path, published only once
                // the share is still current.
                var minted: String?
                if let node {
                    try await server.start(
                        filterData: selectionData,
                        quality: quality,
                        existingNode: node,
                        // The app's long-lived listener, so the share doesn't
                        // create a second one competing for port 7447.
                        controlListener: askToShare.controlListener
                    )
                } else {
                    // Link-only: guest node comes up first (it's the whole
                    // transport). `startLinkOnly` unwinds its own node on
                    // failure, so the catch below has only the server to clear.
                    self.isLinkOnlyShare = true
                    self.linkBusy = true
                    self.publishLink()
                    minted = try await self.link.startLinkOnly(
                        on: server, filterData: selectionData, quality: quality)
                }
                // The actor is released across that await, so a stop (or a
                // second `beginShare`) can have landed meanwhile.
                guard self.core.isCurrentShare(generation) else {
                    await server.stop()
                    // Scoped to the token THIS attempt minted: the
                    // replacement share may already have its own link, so an
                    // unconditional teardown would close the live one instead.
                    if let minted { await self.link.teardown(mintedToken: minted) }
                    return
                }
                if let minted {
                    self.linkToken = minted
                    self.linkBusy = false
                    self.publishLink()
                }
                setPhase(.sharing)
                // Only once genuinely up — an indicator during capture
                // opening would claim "they can see this" too early.
                overlay?.setShowsOutline(showsOutline)
                startVoice(on: server)
            } catch {
                guard self.core.isCurrentShare(generation) else { return }
                endShareGeneration()
                setPhase(.failed("\(error)"))
                self.server = nil
                self.teardownOverlay()
                self.stopVoice()
                self.teardownLink(server: server)
                self.onShareDidEnd?(.startFailed)
            }
        }
    }

    /// Open a share generation: everything stamped with an older one is
    /// ignored from here on. Internal so the engine suite can drive the
    /// guards with no node/server; rules are `SharerSessionCore`'s.
    @discardableResult
    func beginShareGeneration() -> UInt64 {
        core.beginShare()
    }

    /// Close the current share generation — a stop, a capture death, or a
    /// start that failed. Anything still in flight from the server that just
    /// ended is dropped when it lands.
    func endShareGeneration() {
        core.endShare()
    }

    /// Apply one grant snapshot, dropping it when stale or superseded — both
    /// guards live in `SharerSessionCore.shouldApplyGrant`.
    func applyControlGrant(share: UInt64, generation: UInt64, displayName: String?) {
        guard core.shouldApplyGrant(share: share, generation: generation) else { return }
        onControlGrantChanged?(displayName)
    }

    public func stopSharing() {
        // Unconditionally first: nothing the ending server says reaches this
        // engine after this, including a `beginShare` continuation still
        // parked inside `server.start()`.
        endShareGeneration()
        guard let server else {
            setPhase(.idle)
            teardownOverlay()
            return
        }
        self.server = nil
        onShareDidEnd?(.stopped)
        viewers = []
        onViewersChanged?([])
        pendingViewers = []
        onPendingViewersChanged?([])
        clearControlState()
        onLinkOffersChanged?([])
        setPhase(.idle)
        // Queued decisions do not outlive the share — an intent that survived
        // would land on whoever connects to the NEXT share from that address.
        access.reset()
        teardownOverlay()
        stopVoice()
        teardownLink(server: server)
        Task { await server.stop() }
    }

    /// Re-point the live share at a replacement capture backend. The host owns
    /// the negotiation that produced it (on this platform, a portal consent
    /// dialog); this only rides the server's tracked restart.
    @discardableResult
    public func changeSource(
        filterData: Data,
        captureFactory: @escaping @Sendable () -> CaptureEncoding
    ) async throws -> Bool {
        guard let server else { return false }
        // The new factory travels WITH the data: the portal backend is built
        // against a PipeWire node id, so the selection bytes alone aren't enough.
        return try await server.changeSource(
            filterData: filterData, captureFactory: captureFactory)
    }

    /// The capture ended on its own — an error, or the person pressing stop in
    /// the compositor's own indicator.
    private func handleCaptureStopped(_ error: Error?) {
        // `self.server` is deliberately left alone: the server drives its own
        // teardown, and this only empties the engine's control/roster surface.
        endShareGeneration()
        if let error {
            setPhase(.failed("\(error)"))
        } else {
            setPhase(.idle)
        }
        onShareDidEnd?(.captureStopped)
        viewers = []
        onViewersChanged?([])
        pendingViewers = []
        onPendingViewersChanged?([])
        clearControlState()
        onLinkOffersChanged?([])
        teardownOverlay()
        stopVoice()
        // `self.server` is still set (see above), which lets teardown
        // invalidate a link mint this share started and hasn't finished.
        teardownLink(server: server)
    }

    private func setPhase(_ new: Phase) {
        phase = new
        onPhaseChanged?(new)
    }

    // MARK: Drawing

    /// Connect the sharer's own strokes to the overlay and to the viewers.
    /// Two independent directions: a sharer with no viewers still sees their
    /// own pen, and a stroke reaching viewers doesn't depend on the overlay.
    private func wireSharerDrawing(
        overlay: SharerOverlaySurface?, server: TailscaleScreenShareServer
    ) {
        drawing.resetForNewSession()
        drawing.onLocalOp = { [weak overlay, weak server] op in
            overlay?.apply(op)
            // Queued, never one task per op — a reordered `.undo` overtaking
            // its `.add` would leave the stroke stuck on every viewer's canvas.
            server?.enqueueAnnotationBroadcast(op)
        }
        overlay?.onPointer = { [weak self] phase, point in
            // The C layer fires these on the GTK main thread, this actor's
            // executor, so this hop is a formality.
            MainActor.assumeIsolated {
                guard let self else { return }
                switch phase {
                case 0: self.drawing.beginStroke(at: point)
                case 1: self.drawing.extendStroke(to: point)
                default: self.drawing.endStroke()
                }
            }
        }
        overlay?.onEscape = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.latch.release(surface: self.armOverlay)
                self.publishLatch()
            }
        }
    }

    /// Arm a drawing tool, or disarm with nil. Selecting the armed tool again
    /// disarms it.
    ///
    /// Arming makes the overlay (a fullscreen override-redirect window)
    /// swallow every click — the feature — which is why it refuses to arm
    /// unless it can also take the keyboard: Escape is the only way out.
    public func selectTool(_ tool: AnnotationTool?) {
        latch.select(tool, surface: armOverlay)
        publishLatch()
    }

    /// `setInteractive(true)` can half-succeed — flips the input region, then
    /// checks `XGetInputFocus` for the keyboard — so false means `.noKeyboard`.
    private func armOverlay(_ tool: AnnotationTool?) -> SharerDrawingArmResult {
        guard let overlay else { return tool == nil ? .armed : .refused(.noSurface) }
        guard tool != nil else {
            _ = overlay.setInteractive(false)
            return .armed
        }
        return overlay.setInteractive(true) ? .armed : .refused(.noKeyboard)
    }

    private func publishLatch() {
        drawing.mode = latch.activeTool.map { .drawing($0) } ?? .off
        onDrawingChanged?(latch.activeTool, latch.refusal)
    }

    /// Undo the sharer's own last stroke. Viewers' strokes are theirs to undo.
    public func undoDrawing() {
        drawing.undo()
    }

    /// Clear every stroke, from anyone. The sharer owns the screen.
    public func clearDrawing() {
        drawing.clearAll()
        overlay?.clear()
    }

    /// Hide the overlay and seal the injector, torn down explicitly rather
    /// than left to `deinit` (the server's own teardown is async) — "Stop
    /// Sharing" must mean the remote hands are off NOW.
    ///
    /// `deactivate()` also releases any button held mid-drag: on X11 a held
    /// button grabs the pointer, so a stuck one makes the whole desktop unusable.
    private func teardownOverlay() {
        // Disarm FIRST, unconditionally — a merely-dropped interactive
        // overlay leaves a fullscreen click-swallowing window on screen.
        latch.teardown(surface: armOverlay)
        publishLatch()
        overlay?.setShowsOutline(false)
        overlay?.clear()
        overlay = nil
        injector?.deactivate()
        injector = nil
    }

    /// Build the injector, or nil when this X server cannot inject.
    /// `isTrusted()` is asked HERE, before the server exists, since its
    /// answer decides whether `.remoteControl` is advertised at all.
    private static func makeInjector(display: String?) -> X11InputInjector? {
        let injector = X11InputInjector(display: display)
        return injector.isTrusted() ? injector : nil
    }

    // MARK: Voice

    /// Open the microphone and start hearing viewers, for this share only.
    /// Best-effort: a machine with no capture device just shows no mic
    /// control. Ordering (route before device) is `SharerVoiceSession`'s.
    private func startVoice(on server: TailscaleScreenShareServer) {
        guard let microphoneFactory else { return }
        do {
            try voiceSession.start(
                microphone: try microphoneFactory(),
                send: { [weak server] packet in server?.sendAudioRTP(packet) })
        } catch {
            FileHandle.standardError.write(
                Data("warning: no microphone (\(error)) — viewers will not hear you\n".utf8))
        }
    }

    private func stopVoice() {
        voiceSession.stop()
    }

    /// Flip the sharer's microphone. A no-op with no device open, which is also
    /// when the GTK share card draws no control.
    public func toggleMic() {
        voiceSession.toggleMic()
    }

    /// Mirror one latch transition onto this actor's published pair (both
    /// flags must move together — the device can go away mid-share).
    private func applyVoiceState(available: Bool, on: Bool) {
        micAvailable = available
        micOn = on
        onVoiceChanged?(available, on)
    }

    // MARK: Roster

    /// Record a connected-roster snapshot and let the access layer see it —
    /// re-emitted on any change (including StableNodeID resolving), which is
    /// what drains a queued "Deny & Block".
    private func applyConnected(_ rows: [ConnectedViewer]) {
        viewers = rows
        onViewersChanged?(rows)
        noteRoster()
    }

    private func applyPending(_ rows: [PendingViewer]) {
        pendingViewers = rows
        onPendingViewersChanged?(rows)
        noteRoster()
    }

    /// Both lists together — feeding one at a time would prune the other's
    /// queued intents the instant a peer moved between them.
    private func noteRoster() {
        let identities =
            viewers.map {
                ViewerRosterDecision.RosterIdentity(
                    id: $0.id, stableID: $0.stableID, displayName: $0.label)
            }
            + pendingViewers.map {
                ViewerRosterDecision.RosterIdentity(
                    id: $0.id, stableID: $0.stableID, displayName: $0.label)
            }
        if access.noteRoster(identities) {
            onAccessChanged?()
        }
    }

    // MARK: Incoming asks to share

    /// Bring up (or re-point) the idle control listener. Idempotent per
    /// node, safe to call on every node change.
    public func ensureControlListener() {
        guard let node = nodeProvider?() else { return }
        askToShare.ensureListener(node: node)
    }

    /// Test seam onto the coordinator's inbox, so the engine suite can drive
    /// an ask without a listener.
    func noteShareRequest(from hostname: String, sourceAddr: String?, connectionID: UUID) {
        askToShare.noteRequest(
            from: hostname, sourceAddr: sourceAddr, connectionID: connectionID)
    }

    /// Answer an ask: reply on its own connection, and on accept pre-approve
    /// the asker and start sharing.
    public func answerShareRequest(id: UUID, accept: Bool) {
        askToShare.answer(id: id, accept: accept)
    }

    /// Forget every parked ask — the share started by another route, or the
    /// node went away.
    public func clearShareRequests() {
        askToShare.clearRequests()
    }

    // MARK: Access control

    /// What is remembered about a row's peer, for the roster's label.
    public func remembered(stableID: String?) -> PeerPolicy? {
        access.remembered(stableID: stableID)
    }

    /// Whether a decision on this row is queued behind identity resolution.
    public func isDeferred(rowID: String) -> Bool { access.isDeferred(rowID: rowID) }

    /// "Always Allow" / "Deny & Block" on a roster row. Persisting fires
    /// `onPoliciesChanged`, pushing the map at the live server — this is what
    /// makes a block on someone already watching actually expel them.
    public func remember(rowID: String, stableID: String?, label: String, policy: PeerPolicy) {
        access.remember(
            rowID: rowID, stableID: stableID, displayName: label, policy: policy)
        onAccessChanged?()
    }

    /// Drop what is remembered about a row's peer.
    public func forget(rowID: String, stableID: String?) {
        access.forget(rowID: rowID, stableID: stableID)
        onAccessChanged?()
    }

    /// One-time disconnect of a connected viewer. Nothing is remembered —
    /// their next HELLO goes back through the normal admission gate, unlike
    /// Deny & Block.
    public func disconnect(_ addr: String) { server?.disconnectViewer(addr: addr) }

    /// Admit a viewer parked at the approval gate. `addr` is the
    /// `PendingViewer.id` (`"ip:port"`), never a bare IP.
    public func approve(_ addr: String) { server?.approveViewer(addr: addr) }
    /// Reject a viewer parked at the approval gate.
    public func deny(_ addr: String) { server?.denyViewer(addr: addr) }

    // MARK: Remote control

    /// Hand the pointer and keyboard to a viewer who asked for them. The
    /// server holds ONE grantee, gated on that exact connection id. Returns
    /// false if the request is already gone, or if XTEST stopped being
    /// trusted mid-share — the host words the refusal.
    @discardableResult
    public func grantControl(to requestID: UUID) -> Bool {
        server?.grantControl(toConnectionID: requestID) ?? false
    }

    /// Refuse a request without granting anything. The viewer is told.
    public func declineControl(_ requestID: UUID) {
        server?.declineControlRequest(connectionID: requestID)
    }

    /// End a live grant. The viewer is told why, so a pointer that stops
    /// moving reads as a decision rather than a fault.
    public func revokeControl() {
        server?.revokeControl(reason: "the sharer took control back")
    }

    // MARK: Open link on sharer

    /// Take the offer for the host to open in its browser, removing it. Nil
    /// means it's already gone (the viewer left, or it was evicted).
    public func takeLinkOffer(id: UUID) -> LinkOfferInfo? {
        server?.takeLinkOffer(id: id)
    }

    /// Take an offer back off the prompt without opening it.
    public func dismissLinkOffer(id: UUID) {
        server?.dismissLinkOffer(id: id)
    }

    /// Drop every control row on teardown. The high-water mark resets too —
    /// a fresh server starts its sequence at zero, so carrying the old mark
    /// forward would discard the new share's first grant snapshots. The
    /// share stamp (`SharerSessionCore.shouldApplyGrant`) rejects any
    /// snapshot still in flight from the server that just ended.
    private func clearControlState() {
        onControlRequestsChanged?([])
        onControlGrantChanged?(nil)
        core.clearGrantHistory()
    }

    // MARK: Settings

    /// Flip the approval gate and push it at a live share. Applied mid-share
    /// on purpose: turning it off drains whoever is parked (minus
    /// remembered-deny) in one click; turning it on affects only the next
    /// HELLO. Persistence is the host's.
    public func setRequireApproval(_ enabled: Bool) {
        requireApproval = enabled
        server?.setRequireApproval(enabled)
    }
}
