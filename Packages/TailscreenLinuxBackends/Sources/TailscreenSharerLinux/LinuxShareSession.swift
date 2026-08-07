import Foundation
import TailscaleKit
import TailscreenAudio
import TailscreenProtocol
import TailscreenSharer
import TailscreenTransport

/// Runs a share on Linux: the portable `TailscaleScreenShareServer` driven by
/// whichever capture backend the app chose, plus everything around it that
/// used to live untested in the GTK app — access control, the drawing latch,
/// voice, the idle control listener and its ask-to-share inbox, and the
/// server's whole lifecycle.
///
/// The Linux twin of `TailscreenSharerWGC.WindowsShareSession`, and a package
/// type for the same reason that one is: nothing here imports a UI toolkit, so
/// Linux CI builds and tests it headless. The app keeps only the thin
/// observable façade (`SharerModel`) — the `@Published` mirrors, the
/// localized wording, the notification reconcile, and the portal negotiation
/// whose consent dialog is inherently UI.
///
/// **One deliberate difference from the Windows session:** this engine is
/// `@MainActor` rather than lock-guarded. The GTK app services its transport
/// and every callback on the main thread, the node already exists by the time
/// a share starts (no bring-up to keep off the UI thread), and staying on the
/// actor preserves the exact hop-and-reorder behavior the grant-generation
/// guard below exists for. Do not "unify" the two shapes without re-reading
/// `onControlGrantChanged`.
@MainActor
public final class LinuxShareSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting
        case sharing
        case failed(String)
    }

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
    /// `stableID` rides along because the roster's remember/forget actions are
    /// about the PERSON, not the connection: the store is keyed by Tailscale
    /// StableNodeID and nothing else is safe to key on. It is nil until the
    /// netmap lookup lands, which is what `SharerAccessCoordinator` queues
    /// around.
    public struct ConnectedViewer: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let stableID: String?
        public let health: String?

        public init(id: String, label: String, stableID: String?, health: String?) {
            self.id = id
            self.label = label
            self.stableID = stableID
            self.health = health
        }
    }

    /// A viewer parked at the approval gate, as the share card needs it.
    ///
    /// `id` is the server's own viewer key — `"ip:port"`, not the bare IP.
    /// That distinction is the whole reason this is a struct rather than a
    /// string: `approveViewer` and `denyViewer` look the address up in the
    /// pending map, and an IP with the port dropped matches nothing, so both
    /// silently no-op. The sharer gets a row with two buttons that do nothing
    /// and the viewer waits forever. `label` is the readable half — a hostname
    /// once the netmap lookup lands, the IP until then.
    public struct PendingViewer: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        /// See `ConnectedViewer.stableID` — "Always Allow" / "Deny & Block" on
        /// a pending row persists under this, not under the hostname a peer
        /// sends.
        public let stableID: String?

        public init(id: String, label: String, stableID: String?) {
            self.id = id
            self.label = label
            self.stableID = stableID
        }
    }

    // MARK: Host seams

    /// Supplied by the host — hands back the live tsnet node to share.
    public var nodeProvider: (() -> TailscaleNode?)?

    /// Supplied by the host — opens a capture device, or throws if there is
    /// none.
    ///
    /// A factory rather than an instance because a share is a session: the
    /// device is opened when sharing starts and released when it stops. A
    /// long-lived open would keep the OS microphone indicator lit while idle,
    /// which is exactly the thing a person reads as "this app is listening".
    /// Nil means this build has no capture backend at all.
    public var microphoneFactory: (() throws -> MicrophoneCapturing)?
    /// Supplied by the host — plays a viewer's decoded voice on the local
    /// device.
    public var playRemoteVoice: (([Float]) -> Void)?

    /// Supplied by the host — builds the annotation overlay at the capture's
    /// exact pixel geometry, or nil if this session cannot host one. Called at
    /// the start of every share, before the server exists, because whether it
    /// exists is what the server advertises.
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
    /// The sharer's own drawing state — the same store the viewers run, so the
    /// stroke geometry, the undo stack and the identity-derived colour are
    /// shared code rather than a second implementation on the sharing side.
    public let drawing = AnnotationStore()
    public private(set) var micAvailable = false
    public private(set) var micOn = false

    private let display: String?
    private var server: TailscaleScreenShareServer?
    private var viewers: [ConnectedViewer] = []
    private var pendingViewers: [PendingViewer] = []

    /// The gate to apply to the next share, and to the running one. The host
    /// persists the preference; this only asserts it at the server, because
    /// the server's own default is OFF — right for the headless CLI sharer,
    /// wrong for anything with a person in front of it.
    private var requireApproval = ViewerApprovalPreference.load()

    /// Viewers' strokes, drawn on this machine's own screen. Nil when the
    /// session cannot host one — the host's factory said so.
    private var overlay: SharerOverlaySurface?
    /// Granted viewers' input, replayed on this machine. Nil when this X
    /// server has no XTEST extension.
    ///
    /// Held for the share's lifetime rather than handed to the server and
    /// forgotten, because the server's own teardown is asynchronous and the
    /// grant must be sealed the moment sharing stops — see `teardownOverlay`,
    /// which does the same for the same reason.
    private var injector: X11InputInjector?

    /// Which tool is armed and what a refusal to arm means.
    ///
    /// The decisions live in the portable tier — where Linux CI tests them
    /// with no window, no compositor and no X server — because the Windows
    /// sharer has the same hazard in a different shape and a second copy of
    /// this ordering is where the two would drift. The consequence of drifting
    /// is not a cosmetic difference; it is a desktop nobody can click.
    private var latch = SharerDrawingLatch()

    /// Live voice for the current share. Nil while idle, and nil when the
    /// device could not be opened — which is what `micAvailable` reports, so
    /// the control is absent rather than present-and-inert.
    private var voice: SharerVoice?

    /// The generation of the last grant snapshot applied.
    ///
    /// The server stamps every `onControlGrantChanged` with a monotonic
    /// counter precisely because a host like this one hops the callback to its
    /// UI thread, and a hop can reorder. Applying a stale `nil` last would
    /// clear a grant that is still live — the sharer would be told nobody is
    /// controlling their machine while somebody is. `SharerNoticeDecision.isStale`
    /// owns the comparison; this is the field it compares against. It resets
    /// on teardown — see `clearControlState`.
    private var lastGrantGeneration: UInt64 = 0

    /// Remembered allow/deny, and the queue for decisions made before a peer's
    /// identity resolved. Portable and tested on Linux CI — the host only
    /// renders rows and forwards taps.
    ///
    /// Built once and outliving each share on purpose: what a sharer decided
    /// about somebody is not a property of the session they decided it in.
    private let access: SharerAccessCoordinator

    /// The app's OWN control listener, alive for as long as the node is —
    /// not the one the share creates.
    ///
    /// This distinction is the whole feature. `TailscaleScreenShareServer`
    /// builds a listener when none is supplied, but only for the share's
    /// lifetime, and a request to share arrives precisely when this machine is
    /// NOT sharing. With no long-lived listener the port answers nothing while
    /// idle and every ask reads to the asker as "no answer" — indistinguishable
    /// from a peer that is away.
    private var controlListener: TailscreenControlListener?
    /// The node the listener was started against, so a profile switch (which
    /// brings a different node up) restarts it rather than leaving it bound to
    /// a node that is going away.
    private var listenerNode: TailscaleNode?

    /// Peers asking this machine to share, coalesced and bounded by the
    /// portable `ShareRequestInbox`.
    private var inbox = ShareRequestInbox()

    /// IPs accepted before there was a server to tell.
    ///
    /// Accepting an ask has to pre-approve the requester, or they arrive at
    /// this machine's own approval gate a second later and get asked to wait —
    /// having just been invited. But accept happens *before* the share starts,
    /// so there is no server yet: the IP is held here and replayed the moment
    /// one exists. Internal-get so the package tests can pin the held-IP
    /// contract with no server.
    private(set) var pendingPreApprovedIPs: Set<String> = []

    /// - Parameters:
    ///   - display: the X display shares run against; nil means `$DISPLAY`.
    ///   - accessStore: injectable for tests. The default is the same XDG root
    ///     the account registry uses — one place a user's Tailscreen state
    ///     lives.
    public init(display: String?, accessStore: PeerAccessStore? = nil) {
        self.display = display
        self.access = SharerAccessCoordinator(
            store: accessStore ?? PeerAccessStore(directory: AccountProfileLayout.xdg().root))
    }

    // MARK: Share lifecycle

    /// Everything after "which backend": identical for both capture paths.
    ///
    /// - Parameters:
    ///   - showsOutline: whether the overlay's rectangle is genuinely what is
    ///     being captured — the host's `captureMatchesOverlay` answer. The
    ///     outline must not lie, so a portal share passes false and gets no
    ///     indicator rather than a wrong one.
    public func beginShare(
        node: TailscaleNode,
        selectionData: Data,
        quality: QualitySettings,
        showsOutline: Bool,
        captureFactory: @escaping @Sendable () -> CaptureEncoding
    ) {
        setPhase(.starting)

        // The annotation overlay has to exist BEFORE the server, because
        // whether it exists is what the server advertises.
        let overlay = makeOverlay?() ?? nil
        if overlay == nil {
            // Worth a line: the share works perfectly and viewers simply find
            // their drawing tools greyed out, with nothing on either end
            // saying why. Matches this engine's other diagnostics (stderr, not
            // a logger — there is no TSLogger convention on this side).
            FileHandle.standardError.write(
                Data(
                    """
                    warning: no annotation overlay (needs a compositing X11 session) — \
                    viewers' drawing tools will be disabled\n
                    """.utf8))
        }
        self.overlay = overlay

        // Likewise the injector, and for the same reason: supplying one is
        // what makes the server advertise `.remoteControl`. Nil when this X
        // server has no XTEST extension — optional in the protocol, absent on
        // some remote and kiosk servers — in which case every injected click
        // would silently vanish, so viewers must not be invited to try.
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
            // Present iff XTEST is: the server derives `.remoteControl` from
            // whether this is non-nil, so a host that cannot inject withholds
            // the bit and viewers hide Request Control rather than sending
            // requests nothing can serve.
            inputInjector: injector,
            // Claimed only when there is a real surface to draw on. Without a
            // compositor there is none, and a sharer that claims
            // `.annotations` it cannot render leaves every viewer drawing
            // strokes that reach nobody — silently, which is exactly the
            // failure Phase 0 flipped this default to prevent.
            rendersAnnotations: overlay != nil
        )
        // Fires on the server's control-channel thread; the overlay marshals
        // onto the GTK main thread itself.
        server.onAnnotationReceived = { [overlay] op in overlay?.apply(op) }
        wireSharerDrawing(overlay: overlay, server: server)
        // The server's own default is OFF — right for the headless CLI sharer
        // that automation drives, wrong for anything with a person in front of
        // it — so the gate has to be asserted here on every start. Assert the
        // user's setting rather than a literal `true`, or the toggle would be
        // a switch the share ignores.
        server.setRequireApproval(requireApproval)
        // Push what is already remembered BEFORE the first HELLO can arrive,
        // so a blocked peer is rejected on its first attempt rather than
        // admitted and then swept out a moment later.
        server.setAccessPolicies(access.policies)
        access.onPoliciesChanged = { [weak server] policies in
            server?.setAccessPolicies(policies)
        }
        server.onViewersChanged = { infos in
            // Mapped off the main actor (the callback is not on it), then
            // handed over whole. `stableID` travels with each row because the
            // remember/forget actions key on it.
            let rows = infos.map {
                ConnectedViewer(
                    id: $0.id, label: $0.hostname ?? $0.tailscaleIP, stableID: $0.stableID,
                    health: $0.health == .good ? nil : "\($0.health)")
            }
            Task { @MainActor [weak self] in self?.applyConnected(rows) }
        }
        server.onPendingViewersChanged = { pending in
            // Keyed by the server's `"ip:port"` id, NOT the bare IP — see
            // `PendingViewer`. Fires off the main actor; hop.
            let waiting = pending.map {
                PendingViewer(
                    id: $0.id, label: $0.hostname ?? $0.tailscaleIP, stableID: $0.stableID)
            }
            Task { @MainActor [weak self] in self?.applyPending(waiting) }
        }
        server.onControlRequestsChanged = { [weak self] requests in
            // Fires off the main actor; hop. No mapping needed — the card
            // renders `ControlRequestInfo.displayName` directly, the same
            // shape the Windows app passes through.
            Task { @MainActor [weak self] in self?.onControlRequestsChanged?(requests) }
        }
        server.onControlGrantChanged = { [weak self] generation, grant in
            Task { @MainActor [weak self] in
                guard let self,
                    !SharerNoticeDecision.isStale(
                        generation: generation, lastApplied: self.lastGrantGeneration)
                else { return }
                self.lastGrantGeneration = generation
                self.onControlGrantChanged?(grant?.displayName)
            }
        }
        server.onCaptureStopped = { error in
            Task { @MainActor [weak self] in self?.handleCaptureStopped(error) }
        }
        // Anyone whose ask was accepted before this server existed. Replayed
        // BEFORE start, so the gate already knows them when their HELLO lands.
        for ip in pendingPreApprovedIPs { server.preApproveViewer(ip: ip) }
        pendingPreApprovedIPs.removeAll()
        self.server = server

        // Whatever else was parked is stale now: those askers wanted a share
        // and there is one, but it is not the one they asked for and their
        // connections have no answer coming. Leaving the rows would offer
        // buttons that start a second share.
        clearShareRequests()

        Task { @MainActor in
            do {
                try await server.start(
                    filterData: selectionData,
                    quality: quality,
                    existingNode: node,
                    // The app's long-lived listener, so the share does not
                    // create a second one competing for port 7447 — and so
                    // `onRequestToShare` keeps pointing here rather than being
                    // rebound to the share's own.
                    controlListener: controlListener
                )
                setPhase(.sharing)
                // Only once the share is genuinely up: an indicator that
                // appeared while the capture was still opening would say
                // "they can see this" before anyone could.
                overlay?.setShowsOutline(showsOutline)
                startVoice(on: server)
            } catch {
                setPhase(.failed("\(error)"))
                self.server = nil
                self.teardownOverlay()
                self.stopVoice()
                self.onShareDidEnd?(.startFailed)
            }
        }
    }

    public func stopSharing() {
        guard let server else {
            setPhase(.idle)
            teardownOverlay()
            return
        }
        self.server = nil
        // Before the rosters empty — the host stops its notifications here;
        // see `onShareDidEnd`.
        onShareDidEnd?(.stopped)
        viewers = []
        onViewersChanged?([])
        pendingViewers = []
        onPendingViewersChanged?([])
        clearControlState()
        setPhase(.idle)
        // Queued decisions do not outlive the share they were made during:
        // the rows are gone, and an intent that survived would land on whoever
        // connects to the NEXT share from the same address.
        access.reset()
        teardownOverlay()
        stopVoice()
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
        // against a PipeWire node id, so swapping the selection bytes alone
        // would restart the old source.
        return try await server.changeSource(
            filterData: filterData, captureFactory: captureFactory)
    }

    /// The capture ended on its own — an error, or the person pressing stop in
    /// the compositor's own indicator.
    private func handleCaptureStopped(_ error: Error?) {
        if let error {
            setPhase(.failed("\(error)"))
        } else {
            setPhase(.idle)
        }
        // BEFORE the rosters empty: stopping a share expels every viewer at
        // once, and reconciling against the resulting empty list would fire
        // one "stopped watching" banner per viewer at the moment the sharer
        // already decided to stop.
        onShareDidEnd?(.captureStopped)
        viewers = []
        onViewersChanged?([])
        pendingViewers = []
        onPendingViewersChanged?([])
        clearControlState()
        teardownOverlay()
        stopVoice()
    }

    private func setPhase(_ new: Phase) {
        phase = new
        onPhaseChanged?(new)
    }

    // MARK: Drawing

    /// Connect the sharer's own strokes to the overlay and to the viewers.
    ///
    /// Two directions, and they are deliberately separate: the overlay shows
    /// the stroke so the sharer can see what they are drawing, and the server
    /// broadcasts it so viewers see the same thing. Neither is derived from the
    /// other — a sharer whose viewers have all left still gets to see their own
    /// pen, and a stroke reaching viewers does not depend on the overlay
    /// existing.
    private func wireSharerDrawing(
        overlay: SharerOverlaySurface?, server: TailscaleScreenShareServer
    ) {
        drawing.resetForNewSession()
        drawing.onLocalOp = { [weak overlay, weak server] op in
            overlay?.apply(op)
            Task { await server?.broadcastAnnotation(op) }
        }
        overlay?.onPointer = { [weak self] phase, point in
            // The C layer fires these on the GTK main thread, which is this
            // actor's executor — so the hop is a formality the compiler wants
            // rather than a real thread change.
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
    /// disarms it, matching the viewer's toolbar.
    ///
    /// **Arming makes the overlay swallow every click on this machine** — it is
    /// a fullscreen, override-redirect window. That is the feature, and it is
    /// why the overlay refuses to arm unless it can also take the keyboard:
    /// Escape is then the way back out, and without it the sharer would be
    /// stuck behind a window with no visible way to dismiss it. A refusal
    /// leaves the tool unarmed and says so.
    public func selectTool(_ tool: AnnotationTool?) {
        latch.select(tool, surface: armOverlay)
        publishLatch()
    }

    /// The latch's surface seam on X11. `setInteractive(true)` is the call that
    /// can half-succeed — it flips the input region and then checks with
    /// `XGetInputFocus` whether the keyboard came too — so a false here is
    /// exactly the `.noKeyboard` case, and the latch's response to it is to
    /// disarm anyway.
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

    /// Hide the overlay and seal the injector.
    ///
    /// Both are torn down explicitly rather than left to `deinit`, and for the
    /// same reason: the server holds them too, and its own teardown is
    /// asynchronous. Dropping only this reference would leave viewers' strokes
    /// on screen and — much worse — a live control grant, for however long the
    /// server took to finish stopping. "Stop Sharing" has to mean the remote
    /// hands are off *now*.
    ///
    /// `deactivate()` also releases any button held mid-drag, so stopping a
    /// share while a viewer is dragging cannot leave a button stuck down. On
    /// X11 that matters more than elsewhere: a held button grabs the pointer,
    /// so a stuck one makes the whole desktop unusable.
    private func teardownOverlay() {
        // Disarm FIRST, and unconditionally. An interactive overlay that is
        // merely dropped leaves a fullscreen click-swallowing window on screen
        // for as long as it takes the reference to die — and the whole desktop
        // is unusable meanwhile. Unconditional because an arm that half-
        // succeeded leaves this engine believing nothing is armed.
        latch.teardown(surface: armOverlay)
        publishLatch()
        overlay?.setShowsOutline(false)
        overlay?.clear()
        overlay = nil
        injector?.deactivate()
        injector = nil
    }

    /// Build the injector, or nil when this X server cannot inject.
    ///
    /// `isTrusted()` is the real question and it is asked HERE, before the
    /// server exists, because its answer decides whether `.remoteControl` goes
    /// out on the wire at all. Asking later would mean advertising a
    /// capability and then declining every request that arrived because of it.
    private static func makeInjector(display: String?) -> X11InputInjector? {
        let injector = X11InputInjector(display: display)
        return injector.isTrusted() ? injector : nil
    }

    // MARK: Voice

    /// Open the microphone and start hearing viewers, for this share only.
    ///
    /// Best-effort: a machine with no capture device shares perfectly well and
    /// simply shows no mic control. The failure is written to stderr for the
    /// same reason the overlay's and the injector's are — the share works, so
    /// nothing else would ever say why the button is missing.
    private func startVoice(on server: TailscaleScreenShareServer) {
        guard let microphoneFactory else { return }
        do {
            let microphone = try microphoneFactory()
            let voice = try SharerVoice(
                microphone: microphone, encoder: OpusVoiceEncoder(),
                send: { [weak server] packet in server?.sendAudioRTP(packet) })
            voice.onRemotePCM = { [weak self] _, pcm in
                // The SSRC is dropped here: there is one local output device,
                // and the mix is what a person hears. A sharer UI that wanted
                // a speaking indicator would keep it.
                Task { @MainActor in self?.playRemoteVoice?(pcm) }
            }
            voice.onStopped = { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in
                    // Both flags together: a live indicator over a device
                    // recording nothing is the one wrong answer here.
                    self?.setVoiceState(available: false, on: false)
                }
            }
            // Inbound viewer audio, already vetted by the server's anti-spoof
            // gate. Fires on the receive thread; `VoiceDownlink` does
            // arithmetic only and hands the result on.
            server.onAudioReceived = { [weak voice] packet in voice?.receive(packet) }
            try voice.start()
            self.voice = voice
            setVoiceState(available: true, on: false)
        } catch {
            FileHandle.standardError.write(
                Data("warning: no microphone (\(error)) — viewers will not hear you\n".utf8))
        }
    }

    private func stopVoice() {
        voice?.stop()
        voice = nil
        setVoiceState(available: false, on: false)
    }

    /// Flip the sharer's microphone.
    public func toggleMic() {
        guard let voice else { return }
        let nowOn = voice.isMuted
        voice.isMuted = !nowOn
        setVoiceState(available: micAvailable, on: nowOn)
    }

    private func setVoiceState(available: Bool, on: Bool) {
        micAvailable = available
        micOn = on
        onVoiceChanged?(available, on)
    }

    // MARK: Roster

    /// Record a connected-roster snapshot and let the access layer see it.
    ///
    /// The roster is re-emitted whenever anything about it changes — including
    /// a StableNodeID finishing resolution, which is precisely the event a
    /// queued "Deny & Block" is waiting for. So feeding it here, rather than
    /// only on join and leave, is what makes the queue drain at all.
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

    /// Both lists together: a peer moves between them (pending → connected on
    /// Accept), and feeding one at a time would prune the other's queued
    /// intents as "gone" the instant it moved.
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
            // A queued decision just landed; the roster's own rows now render
            // differently (the standing decision replaces the two buttons).
            onAccessChanged?()
        }
    }

    // MARK: Incoming asks to share

    /// Bring up (or re-point) the idle control listener.
    ///
    /// Idempotent per node and safe to call on every node change — which is
    /// how it is called, because there is no single moment when "the node is
    /// ready" that this engine observes. A listener already bound to the same
    /// node is left alone.
    public func ensureControlListener() {
        guard let node = nodeProvider?() else { return }
        if controlListener != nil, listenerNode === node { return }
        let previous = controlListener
        if let previous { Task { await previous.stop() } }

        let listener = TailscreenControlListener()
        listener.onRequestToShare = { [weak self] hostname, connectionID, sourceAddr in
            // Fires on the listener's own thread; the inbox and its published
            // projection are main-actor state.
            Task { @MainActor [weak self] in
                self?.noteShareRequest(
                    from: hostname, sourceAddr: sourceAddr, connectionID: connectionID)
            }
        }
        controlListener = listener
        listenerNode = node
        Task {
            do {
                try await listener.start(node: node)
            } catch {
                // Worth a line rather than silence: the share still works and
                // this machine simply never hears an ask, which from the other
                // end is indistinguishable from nobody being home.
                FileHandle.standardError.write(
                    Data("warning: could not listen for share requests: \(error)\n".utf8))
            }
        }
    }

    func noteShareRequest(from hostname: String, sourceAddr: String?, connectionID: UUID) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        // Expire first, so a two-minute-old row that the asker has already
        // given up on cannot occupy a slot against a live one.
        _ = inbox.pruneExpired(nowNs: nowNs, ttlNs: Self.shareRequestTTLNs)
        guard
            inbox.record(
                fromHostname: hostname, sourceAddr: sourceAddr,
                connectionID: connectionID, nowNs: nowNs)
        else { return }
        publishShareRequests()
    }

    /// Push the inbox to the host — card and notifications together, because
    /// the two must not drift: an ask that expires from the inbox but keeps
    /// its banner is an invitation whose Share button answers a connection
    /// that has already gone.
    private func publishShareRequests() {
        onShareRequestsChanged?(inbox.requests)
    }

    /// Matches the requester's own wait (`TailscreenRequestToShareClient`'s
    /// 120 s default). A row that outlives it is a button that does nothing.
    static let shareRequestTTLNs: UInt64 = 120 * 1_000_000_000

    /// Answer an ask: reply on its own connection, and on accept pre-approve
    /// the asker and have the host start sharing.
    public func answerShareRequest(id: UUID, accept: Bool) {
        guard let request = inbox.remove(id: id) else { return }
        publishShareRequests()

        if let connectionID = request.connectionID, let listener = controlListener {
            Task {
                // Best effort: the asker may have given up and closed. Sending
                // into a dead connection is not an error worth surfacing —
                // their side already settled on `.noAnswer`.
                await listener.send(.shareResponse(accepted: accept), to: connectionID)
            }
        }
        guard accept else { return }

        // Pre-approve BEFORE starting, because the HELLO can arrive as soon as
        // the share is up — and a peer this machine just invited must not then
        // be parked at its approval gate.
        pendingPreApprovedIPs.insert(request.sourceKey)
        server?.preApproveViewer(ip: request.sourceKey)
        onStartShareRequested?()
    }

    /// Forget every parked ask — the share started by another route, or the
    /// node went away.
    public func clearShareRequests() {
        guard !inbox.requests.isEmpty else { return }
        inbox.removeAll()
        publishShareRequests()
    }

    // MARK: Access control

    /// What is remembered about a row's peer, for the roster's label.
    public func remembered(stableID: String?) -> PeerPolicy? {
        access.remembered(stableID: stableID)
    }

    /// Whether a decision on this row is queued behind identity resolution.
    public func isDeferred(rowID: String) -> Bool { access.isDeferred(rowID: rowID) }

    /// "Always Allow" / "Deny & Block" on a roster row.
    ///
    /// Persisting fires `onPoliciesChanged`, which pushes the map at the live
    /// server — which is what makes a block on somebody already watching
    /// actually expel them, rather than merely stop them coming back.
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

    /// One-time disconnect of a connected viewer — the roster's Disconnect.
    ///
    /// Nothing is remembered: their next HELLO goes back through the normal
    /// admission gate. That is the difference between this and Deny & Block,
    /// and it is why both exist.
    public func disconnect(_ addr: String) { server?.disconnectViewer(addr: addr) }

    /// Admit a viewer parked at the approval gate. `addr` is the
    /// `PendingViewer.id` (`"ip:port"`), never a bare IP.
    public func approve(_ addr: String) { server?.approveViewer(addr: addr) }
    /// Reject a viewer parked at the approval gate.
    public func deny(_ addr: String) { server?.denyViewer(addr: addr) }

    // MARK: Remote control

    /// Hand the pointer and keyboard to a viewer who asked for them.
    ///
    /// The server holds ONE grantee at a time and gates injection on that
    /// exact connection id, so this is the whole of the decision — there is no
    /// second switch to also set. It returns false when the request is already
    /// gone (the viewer gave up, or disconnected), which is not an error worth
    /// an alert: the row disappears on the next snapshot either way. On this
    /// host false can also mean the injector stopped being trusted — XTEST
    /// went away under a live share — which the host words for the person.
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

    /// Drop every control row on teardown.
    ///
    /// The generation counter resets too: a fresh server starts its own
    /// sequence at zero, so carrying the old high-water mark forward would
    /// make `isStale` discard the new share's first snapshots — a grant that
    /// silently never appears in the UI.
    private func clearControlState() {
        onControlRequestsChanged?([])
        onControlGrantChanged?(nil)
        lastGrantGeneration = 0
    }

    // MARK: Settings

    /// Flip the approval gate and push it at a live share.
    ///
    /// Applied mid-share on purpose: `setRequireApproval(false)` drains
    /// whoever is already parked (minus anyone remembered-deny), so turning
    /// the gate off is also how you admit a queue in one click. Turning it on
    /// mid-share affects the next HELLO — viewers already admitted stay
    /// admitted, exactly as on macOS. Persistence is the host's — this engine
    /// owns no preferences.
    public func setRequireApproval(_ enabled: Bool) {
        requireApproval = enabled
        server?.setRequireApproval(enabled)
    }
}
