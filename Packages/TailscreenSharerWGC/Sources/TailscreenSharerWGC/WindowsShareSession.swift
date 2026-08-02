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
/// A package type rather than an app file for two reasons. The first is that
/// this half must not touch the UI thread. The sign-in freeze earlier in
/// this port was exactly that mistake — a `@MainActor`-isolated async method
/// whose non-suspending body ran tsnet bring-up on the UI thread — and a
/// screen-share server brings up its own tsnet node the same way. So the
/// controller is NOT `@MainActor`; it publishes back through a callback the
/// caller hops for itself.
///
/// The picker is the deliberate exception. It is modal system UI that needs an
/// owner window and a message pump, so `pick` is called from the main thread
/// (the shim pumps while it waits) and nothing else is.
///
/// The second reason is the package's: nothing here imports a UI toolkit, so
/// Linux CI typechecks it. That matters most for exactly the concurrency
/// reasoning above, which is the part a Windows-only build would let through
/// unread until someone ran it.
///
/// Remote control is offered only when the caller can say WHERE the shared
/// content is on screen (`controlRegion`). A WGC `GraphicsCaptureItem` does
/// not expose its HMONITOR or HWND, so a picker-chosen target has no known
/// geometry and normalized coordinates cannot be mapped onto it — and a click
/// landing somewhere the viewer did not aim it is worse than a click that does
/// not happen. Without a region no injector is supplied, the server withholds
/// `ScreenShareCaps.remoteControl`, and viewers hide Request Control rather
/// than sending requests this host cannot serve. That conditional capability
/// is what the portable server gained when it stopped being macOS-only, and it
/// is what makes an incomplete platform honest rather than broken.
public final class WindowsShareSession: @unchecked Sendable {
    /// What the UI needs to render, pushed on every change.
    public struct Status: Sendable {
        public var isSharing = false
        /// The picker's own name for the target — "Screen 1", a window title.
        public var target = ""
        public var viewerCount = 0
        /// Who is watching, and enough about each to act on them.
        ///
        /// A roster rather than only a count, because this is the surface a
        /// sharer uses to change their mind about somebody already admitted —
        /// and without it this app could admit a viewer and then do nothing
        /// about them, which the alignment plan calls the worst gap in the
        /// matrix.
        public var viewers: [ConnectedViewer] = []
        public var message = ""
        /// Viewers asking for remote control, awaiting an answer.
        ///
        /// The server surfaces these and does nothing else with them: a grant
        /// is a decision only the person at the keyboard can make. The Windows
        /// app had an injector, advertised the capability and then had nowhere
        /// to show the request — so a viewer pressed Request Control and
        /// nothing happened at either end.
        public var controlRequests: [ControlRequestInfo] = []
        /// Viewers parked at the approval gate, awaiting Accept or Deny.
        ///
        /// Surfaced for exactly the reason above, one step earlier in the same
        /// story: the gate is useless if the prompt it produces has nowhere to
        /// appear. A parked viewer sees a Connecting placard and waits
        /// forever.
        public var pendingViewers: [PendingViewer] = []
        /// Whether new viewers have to be let in by hand.
        ///
        /// Mirrored into the status so the UI's switch reads back from the
        /// thing it controls rather than from a second copy that can drift out
        /// of step with the live share.
        public var requireApproval = true
        /// Who currently holds control, if anyone.
        public var controlGrantedTo: String?
        /// Whether a capture device was opened for this share — the capability
        /// the mic control's existence rides on. False on a machine with no
        /// microphone, or one whose device failed, and the control is then
        /// absent rather than present-and-inert.
        public var micAvailable = false
        /// Whether the sharer's voice is reaching viewers. Starts off:
        /// starting a share must not put somebody on the air.
        public var micOn = false
        /// Whether viewers can ask to control this machine.
        ///
        /// Reported rather than left implicit because its absence is otherwise
        /// invisible from both ends: the viewer simply does not offer Request
        /// Control, and the sharer sees a share that looks completely normal.
        public var remoteControlAvailable = false
        /// Whether viewers' strokes appear on this screen. Gated on the same
        /// resolved geometry as control — a stroke's coordinates are normalized
        /// against what the viewer SEES, so a target whose rect is unknown gets
        /// neither rather than getting strokes drawn somewhere plausible and
        /// wrong.
        public var annotationsAvailable = false
        /// Live capture timings, so "it's slow" can be answered with which
        /// stage rather than a guess.
        public var timings: CaptureTimings?

        public init() {}
    }

    /// Somebody currently watching.
    ///
    /// A local type for the same reason `PendingViewer` is one, plus a second:
    /// `stableID` needs saying out loud. The remember/forget actions are about
    /// the PERSON, and the persistent store is keyed by Tailscale StableNodeID
    /// — never by `displayName`, which is a hostname the peer supplies and can
    /// therefore choose. It is nil until the sharer's own netmap lookup lands.
    public struct ConnectedViewer: Sendable, Identifiable, Hashable {
        /// The server's `"ip:port"` viewer key — what `disconnectViewer` takes.
        public let id: String
        public let displayName: String
        public let stableID: String?
        /// Connection health, when it is worth showing. Nil for a healthy
        /// viewer: a chip on every row makes the one that matters invisible.
        public let health: String?

        public init(id: String, displayName: String, stableID: String?, health: String?) {
            self.id = id
            self.displayName = displayName
            self.stableID = stableID
            self.health = health
        }
    }

    /// A viewer waiting on the sharer's Accept / Deny.
    ///
    /// A local type rather than the server's `PendingViewerInfo` so the app
    /// does not have to take a direct dependency on `TailscreenSharer` — and,
    /// more usefully, so `id` is documented at the point the app touches it:
    /// it is the server's `"ip:port"` viewer key, and `approveViewer` /
    /// `denyViewer` match on exactly that. Hand them the bare IP and both
    /// silently do nothing, which reads as two dead buttons.
    public struct PendingViewer: Sendable, Identifiable, Hashable {
        public let id: String
        /// Hostname when the netmap lookup has landed, the Tailscale IP until
        /// then. Cosmetic — never use it to identify the viewer.
        public let displayName: String
        /// See `ConnectedViewer.stableID`: "Always Allow" / "Deny & Block" on a
        /// pending row persists under this, not under `displayName`.
        public let stableID: String?

        public init(id: String, displayName: String, stableID: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.stableID = stableID
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

    public init() {}

    /// One-time process setup. **Call at startup, before any window exists.**
    ///
    /// Only DPI awareness, but it is not optional for this app: without it
    /// Windows reports scaled coordinates for every display while
    /// Windows.Graphics.Capture reports capture items in physical pixels, so
    /// on any display above 100 % scaling nothing this app measures agrees
    /// with anything it captures — `resolveControlRegion` finds no matching
    /// monitor and the share loses remote control and annotations together,
    /// with no error anywhere to explain it.
    ///
    /// A process-wide setting exposed here because this package owns the
    /// coordinate space it governs; the app calls it once and never thinks
    /// about it again.
    public static func prepareProcess() {
        SendInputInjector.enablePerMonitorDPIAwareness()
    }

    private let lock = NSLock()
    private var server: TailscaleScreenShareServer?
    private var overlay: AnnotationOverlay?
    /// Live voice for the current share. Guarded by `lock`, like `server`.
    private var voice: SharerVoice?
    private var status = Status()
    /// The gate to apply to the next share, and to the running one.
    ///
    /// Held here rather than only on the server because the server exists only
    /// while a share does, and the setting is something the user sets *before*
    /// pressing Share. Defaults to on: `TailscaleScreenShareServer` defaults
    /// it OFF — correct for a headless automation sharer, catastrophic for a
    /// desktop app that forgets to say otherwise — so this wrapper's job is to
    /// make forgetting fail closed.
    private var requireApproval = true
    /// IPs invited before there was a server to tell. Guarded by `lock`.
    private var pendingPreApprovedIPs: Set<String> = []

    /// Whether this machine can capture at all — checked before any UI is
    /// offered, so an unsupported Windows build is a sentence rather than a
    /// share that fails halfway.
    public var isSupported: Bool { WGC.isSupported }

    /// Show the capture picker. **Main thread only** (see the type comment).
    ///
    /// - Returns: the chosen target, or nil if the user dismissed the picker —
    ///   which is a decision, not an error, and must not raise an alert.
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
    /// `nonisolated` and `async`: called from a `Task` on the main actor, it
    /// runs on the global executor, so the node bring-up inside `start` never
    /// occupies the UI thread.
    /// Remote control is enabled automatically when the picked target's
    /// screen rect can be resolved — see `resolveControlRegion`. It cannot
    /// always be, and the reason lands in the published status rather than
    /// being swallowed.
    /// - Parameter existingNode: the app's already-signed-in tsnet node.
    ///   **Supply it.** Without one the server brings up its own, which needs
    ///   its own state directory — and a state directory holds a machine key,
    ///   so that is a second machine, needing a second interactive browser
    ///   login the user is never prompted for. The share then waits at that
    ///   login forever and never appears on anyone's tailnet. Sharing the
    ///   node is also what gives the app ONE identity, as the macOS app has.
    public func beginSharing(
        item: WGC.CaptureItem,
        hostname: String,
        statePath: String,
        quality: QualitySettings,
        existingNode: TailscaleNode? = nil,
        controlListener: TailscreenControlListener? = nil
    ) async throws {
        // A capture FACTORY, not an instance, because the server respawns the
        // backend to restart capture. Closing over the item is what makes a
        // restart re-target the same window without asking the user again —
        // the equivalent of the macOS helper re-resolving its cached selection,
        // which a `GraphicsCaptureItem` cannot be turned back into.
        // Resolve WHERE the target is before building the server: whether an
        // injector exists at all is what decides the advertised
        // `.remoteControl` capability, and that is fixed for the session.
        let region = Self.resolveControlRegion(for: item)
        let regionNote: String
        switch region {
        case .success:
            regionNote = ""
        case .failure(let reason):
            // Names BOTH features, because both are gated on this one answer
            // and a message about remote control alone left the missing
            // annotations looking like a separate, unexplained fault.
            regionNote = "Remote control and annotations are off — \(reason)"
        }

        // A resolved region means remote control is offered; an unresolved one
        // means no injector, so the server withholds `.remoteControl` and
        // viewers hide Request Control rather than sending requests that would
        // land in the wrong place.
        var injector: WindowsInputInjector?
        var annotationOverlay: AnnotationOverlay?
        if case .success(let resolved) = region {
            injector = WindowsInputInjector(regionProvider: { resolved })
            // Annotations need the same rect as remote control, and for the
            // same reason: a stroke's coordinates are normalized against what
            // the viewer can SEE. So they gate together — a target whose
            // geometry is unknown gets neither, rather than getting strokes
            // drawn somewhere plausible and wrong.
            annotationOverlay = AnnotationOverlay(
                region: AnnotationOverlay.Region(
                    x: resolved.x, y: resolved.y,
                    width: resolved.width, height: resolved.height))
        }
        lock.withLock { overlay = annotationOverlay }
        let injectorAvailable = injector != nil
        let overlayAvailable = annotationOverlay != nil

        // The timings hook is on the concrete backend rather than the
        // `CaptureEncoding` seam, so it is attached inside the factory — which
        // also means a restart's fresh backend keeps reporting.
        let onTimings: @Sendable (CaptureTimings) -> Void = { [weak self] timings in
            self?.update { $0.timings = timings }
        }
        let newServer = TailscaleScreenShareServer(
            captureFactory: {
                let encoder = WGCCaptureEncoder(item: item)
                encoder.onTimings = onTimings
                return encoder
            },
            inputInjector: injector,
            // Advertised only when an overlay actually exists. The capability
            // means "your strokes will appear on my screen", so a share with
            // no resolvable geometry — and therefore no overlay — must not
            // claim it, exactly as it must not claim `.remoteControl`.
            rendersAnnotations: annotationOverlay != nil
        )
        newServer.onAnnotationReceived = { [weak self] op in
            // Fires on the control-channel thread. The overlay is
            // thread-safe and redraws only when the op changed something,
            // which matters because a pen drag sends one every few
            // milliseconds.
            self?.lock.withLock { self?.overlay }?.apply(op)
        }
        let name = item.displayName

        newServer.onViewersChanged = { [weak self] viewers in
            let rows = viewers.map {
                ConnectedViewer(
                    id: $0.id, displayName: $0.hostname ?? $0.tailscaleIP,
                    stableID: $0.stableID,
                    health: $0.health == .good ? nil : "\($0.health)")
            }
            self?.update {
                $0.viewerCount = rows.count
                $0.viewers = rows
            }
            self?.noteRoster()
        }
        newServer.onPendingViewersChanged = { [weak self] pending in
            // Fires on a network thread; `update` publishes and the app hops.
            self?.update {
                $0.pendingViewers = pending.map {
                    PendingViewer(
                        id: $0.id, displayName: $0.hostname ?? $0.tailscaleIP,
                        stableID: $0.stableID)
                }
            }
            self?.noteRoster()
        }
        newServer.onControlRequestsChanged = { [weak self] requests in
            self?.update { $0.controlRequests = requests }
        }
        newServer.onControlGrantChanged = { [weak self] _, grant in
            self?.update { $0.controlGrantedTo = grant?.hostname ?? grant?.viewerIP }
        }
        newServer.onCaptureStopped = { [weak self] error in
            // Before the status push: a capture that died must not leave the
            // microphone open, and the status it publishes says `micAvailable
            // = false`, so the two would otherwise disagree.
            self?.stopVoice()
            self?.update {
                $0.isSharing = false
                $0.viewerCount = 0
                $0.viewers = []
                $0.pendingViewers = []
                $0.message = error.map { "Sharing stopped: \($0)" } ?? ""
                $0.remoteControlAvailable = false
                $0.annotationsAvailable = false
                $0.micAvailable = false
                $0.micOn = false
            }
        }

        // Publish the server, then assert the gate — in that order, and both
        // before `start`. Reading the setting first and publishing after would
        // lose a flip that landed in between: `setRequireApproval` would find
        // no server to push to, and this server would already be holding the
        // stale value. Doing it after `start` would leave a window, short but
        // exactly the one an already-waiting peer's HELLO arrives in, where
        // the share is open door.
        let (gate, invited) = lock.withLock { () -> (Bool, Set<String>) in
            server = newServer
            let invited = pendingPreApprovedIPs
            pendingPreApprovedIPs.removeAll()
            return (requireApproval, invited)
        }
        newServer.setRequireApproval(gate)
        // Anyone whose ask this machine accepted before the server existed.
        // Replayed here, in the same window as the gate and the policies, so
        // an invitee's HELLO cannot arrive before the server knows about them.
        for ip in invited { newServer.preApproveViewer(ip: ip) }
        // Before the first HELLO can arrive, so a blocked peer is rejected on
        // its first attempt rather than admitted and swept out a moment later.
        newServer.setAccessPolicies(access.policies)
        update {
            $0.requireApproval = gate
            $0.target = name
            $0.message = "Starting…"
            $0.remoteControlAvailable = injectorAvailable
            $0.annotationsAvailable = overlayAvailable
        }

        // A display target with no ID: on Windows the item IS the selection,
        // and the backend was constructed with it. The kind still matters —
        // the encoder rejects `.application`, which one item cannot express.
        let selection = PickerSelection(
            kind: .display, displayID: nil, windowID: nil, bundleIDs: [])
        let selectionData = try JSONEncoder().encode(selection)

        // `TAILSCREEN_TS_CONTROL_URL` is honoured the way the rest of the
        // repo's e2e tooling honours it, but by OMITTING the argument when
        // unset rather than spelling out a default — that keeps
        // `kDefaultControlURL`, and therefore a whole TailscaleKit dependency,
        // out of the app target for the sake of one constant.
        let controlURL = ProcessInfo.processInfo.environment["TAILSCREEN_TS_CONTROL_URL"]
        let authKey = ProcessInfo.processInfo.environment["TAILSCREEN_TS_AUTHKEY"]
        do {
            if let controlURL {
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
            lock.withLock { server = nil }
            update {
                $0.isSharing = false
                $0.message = ""
            }
            throw error
        }
        startVoice(on: newServer)

        update {
            $0.isSharing = true
            $0.message = regionNote
        }
    }

    /// Turn the approval gate on or off, now and for the next share.
    ///
    // MARK: Access control

    /// Remembered allow/deny, plus the queue for decisions made before a peer's
    /// identity resolved.
    ///
    /// Portable and tested on Linux CI (`SharerAccessCoordinatorTests`), which
    /// is the whole reason this app has the feature at a fraction of the cost:
    /// the session only forwards taps and re-publishes.
    ///
    /// Built lazily against `%LOCALAPPDATA%\Tailscreen`, the same root the
    /// account registry uses — one place a user's Tailscreen state lives.
    private lazy var access: SharerAccessCoordinator = {
        let coordinator = SharerAccessCoordinator(
            store: PeerAccessStore(directory: AccountProfileLayout.windowsLocalAppData().root))
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

    /// One-time disconnect of a connected viewer.
    ///
    /// Nothing is remembered — their next HELLO goes back through the normal
    /// admission gate. That difference is why this and Deny & Block both exist.
    public func disconnectViewer(_ id: String) {
        lock.withLock { server }?.disconnectViewer(addr: id)
    }

    /// Feed the access layer both rosters together.
    ///
    /// Both, not one at a time: a peer moves from pending to connected on
    /// Accept, and a snapshot of only one list would prune the other's queued
    /// intents as "gone" at exactly that moment.
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

    /// Takes effect mid-share: `setRequireApproval(false)` also drains anyone
    /// already parked (minus remembered-deny peers), so turning it off is how
    /// a sharer admits a queue in one click. Persistence is the caller's —
    /// this package owns no preferences.
    public func setRequireApproval(_ enabled: Bool) {
        let server = lock.withLock { () -> TailscaleScreenShareServer? in
            requireApproval = enabled
            return self.server
        }
        server?.setRequireApproval(enabled)
        update { $0.requireApproval = enabled }
    }

    /// Waive the approval gate once for a peer this machine INVITED.
    ///
    /// Accepting somebody's ask to share and then making them wait at the
    /// approval gate is the same person being asked twice, seconds apart, and
    /// the second prompt arrives with no context. Held until a server exists,
    /// because accept necessarily happens before the share starts — the whole
    /// point of accepting is that there is not one yet.
    ///
    /// One-time and non-overriding: `preApproveViewer` does not beat a
    /// remembered `.deny`, so inviting somebody previously blocked does not
    /// silently unblock them.
    public func preApproveViewer(ip: String) {
        let server: TailscaleScreenShareServer? = lock.withLock {
            if self.server == nil { pendingPreApprovedIPs.insert(ip) }
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

    /// Answer a pending remote-control request.
    ///
    /// Returns false when the grant was refused by the platform — which on
    /// Windows means the injector is absent (an unresolvable capture region),
    /// since UIPI has no permission to ask for.
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

    public func stopSharing() async {
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
        guard let running else { return }
        await running.stop()
        update {
            $0.isSharing = false
            $0.viewerCount = 0
            $0.pendingViewers = []
            $0.message = ""
            $0.remoteControlAvailable = false
            $0.annotationsAvailable = false
            $0.micAvailable = false
            $0.micOn = false
            $0.timings = nil
        }
    }

    // MARK: Voice

    /// Open the microphone and start hearing viewers, for this share only.
    ///
    /// Best-effort, exactly like the overlay and the injector: a machine with
    /// no capture device shares perfectly well and simply shows no mic
    /// control. The failure goes into the status message rather than being
    /// thrown, because a share that is otherwise working must not be torn down
    /// over audio.
    private func startVoice(on server: TailscaleScreenShareServer) {
        guard let microphoneFactory else { return }
        let voice: SharerVoice
        do {
            voice = try SharerVoice(
                microphone: try microphoneFactory(), encoder: OpusVoiceEncoder(),
                send: { [weak server] packet in server?.sendAudioRTP(packet) })
            try voice.start()
        } catch {
            update { $0.message = "Sharing (no microphone: \(error))" }
            return
        }
        voice.onRemotePCM = { [weak self] _, pcm in self?.playRemoteVoice?(pcm) }
        voice.onStopped = { [weak self] error in
            guard error != nil else { return }
            // Both flags together: a live indicator over a device recording
            // nothing is the one wrong answer a mute control can give.
            self?.update {
                $0.micAvailable = false
                $0.micOn = false
            }
        }
        // Inbound viewer audio, already vetted by the server's anti-spoof
        // gate. Fires on the receive thread; the downlink does arithmetic only.
        server.onAudioReceived = { [weak voice] packet in voice?.receive(packet) }
        lock.withLock { self.voice = voice }
        update {
            $0.micAvailable = true
            $0.micOn = false
        }
    }

    private func stopVoice() {
        let live = lock.withLock { () -> SharerVoice? in
            let value = voice
            voice = nil
            return value
        }
        live?.stop()
    }

    /// Flip the sharer's microphone.
    public func toggleMic() {
        guard let voice = lock.withLock({ self.voice }) else { return }
        let nowOn = voice.isMuted
        voice.isMuted = !nowOn
        update { $0.micOn = nowOn }
    }

    /// Where the picked target sits on screen, or why that is unknowable.
    ///
    /// The item carries no HMONITOR, so its SIZE is matched against the
    /// enumerated monitors — the decision itself is `WindowsCaptureRegion` in
    /// TailscreenProtocol, where Linux CI tests the cases that matter,
    /// especially the two-identical-monitors one that must decline rather than
    /// guess.
    static func resolveControlRegion(
        for item: WGC.CaptureItem
    ) -> Result<SendInputInjector.Region, WindowsCaptureRegion.Failure> {
        let size = item.size
        return WindowsCaptureRegion.resolve(
            itemWidth: size.width, itemHeight: size.height,
            monitors: SendInputInjector.monitors())
    }

    /// Mutate the published status under the lock and publish the result.
    ///
    /// The callback fires OUTSIDE the lock: it hops to the main actor, and
    /// holding a lock across that hand-off is how a UI callback ends up
    /// deadlocking against a capture thread.
    private func update(_ body: (inout Status) -> Void) {
        let snapshot: Status = lock.withLock {
            body(&status)
            return status
        }
        onStatus?(snapshot)
    }
}
