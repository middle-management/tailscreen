import Foundation
import SwiftCrossUI
import TailscaleKit
import TailscreenL10n
import TailscreenSharer
import TailscreenSharerLinux
import X11CaptureKit

// Targeted imports: pulling in all of TailscreenProtocol collides with
// SwiftCrossUI's own `Published` / `ObservableObject` shims on Linux.
import struct TailscreenProtocol.PickerSelection
import enum TailscreenProtocol.CaptureBackendSelection
import enum TailscreenProtocol.ThumbnailScaler
import struct TailscreenProtocol.ControlRequestInfo
import enum TailscreenProtocol.GlobalHotkeyUnavailability
import enum TailscreenProtocol.SharerNoticeKind
import struct TailscreenProtocol.NoticeCandidate
import enum TailscreenProtocol.TailscreenInstance
import protocol TailscreenSharer.CaptureEncoding
import class TailscreenSharerPortal.PortalCaptureEncoder
import class PortalCaptureKit.PortalSession

import struct TailscreenProtocol.QualitySettings
import enum TailscreenProtocol.QualitySettingsStore
import struct TailscreenProtocol.PendingShareRequest
import enum TailscreenProtocol.ViewerApprovalPreference
import enum TailscreenProtocol.PeerPolicy
import class TailscreenProtocol.AnnotationStore
import enum TailscreenProtocol.AnnotationTool
import enum TailscreenProtocol.SharerDrawingRefusal
import protocol TailscreenAudio.MicrophoneCapturing

/// The engine's row types, under the names this app has always used them by.
typealias ConnectedViewer = LinuxShareSession.ConnectedViewer
typealias PendingViewer = LinuxShareSession.PendingViewer

/// Drives the *sharing* half of the app: start/stop a share, and publish who's
/// watching so the chrome can render it.
///
/// The counterpart of `PickerModel`, and deliberately just as thin — a façade
/// over `LinuxShareSession` (Packages/TailscreenLinuxBackends), which owns the
/// engine: server lifecycle, access control, the drawing latch, voice, and the
/// idle control listener, all tested headless on Linux CI. What stays here is
/// exactly what needs the app: the `@Published` mirrors SwiftCrossUI observes,
/// the localized wording, the desktop-notification reconcile, and the portal
/// negotiation, whose consent dialog is inherently UI.
///
/// **It borrows the viewer's tsnet node** rather than bringing up its own. Two
/// nodes would mean two tailnet identities for one app: peers would see a
/// phantom second machine, and the sharer wouldn't be reachable at the address
/// the viewer half advertises. The macOS app solves this the same way —
/// `AppState` owns one node and passes it to both the server and the client.
@MainActor
final class SharerModel: ObservableObject {
    typealias Phase = LinuxShareSession.Phase

    @Published var phase: Phase = .idle
    /// Bumped whenever the remembered-policy layer changes.
    ///
    /// SwiftCrossUI's `ObservableObject` shim has no `objectWillChange`, and
    /// the thing that changed lives in the engine's `SharerAccessCoordinator`
    /// rather than in a `@Published` here — deliberately, since it is portable
    /// and this app only renders it. A counter is the shim's idiom for
    /// "something you cannot see moved"; the roster rows read the engine when
    /// they redraw.
    @Published private(set) var accessGeneration = 0

    /// Who is watching, for the sharing card's roster.
    ///
    /// Structured rather than a list of IP strings, which is what it was: this
    /// is the surface a sharer uses to change their mind about somebody
    /// already admitted, and before it existed this app could admit a viewer
    /// and then do nothing about them.
    @Published var viewers: [ConnectedViewer] = []
    /// Viewers parked awaiting approval, when the approval gate is on.
    @Published var pendingViewers: [PendingViewer] = []

    /// Viewers asking to drive this machine.
    ///
    /// The engine supplies an `X11InputInjector` whenever XTEST is present,
    /// which is what makes the server advertise `ScreenShareCaps.remoteControl`
    /// — so viewers are *offered* Request Control. Until this existed the
    /// request then reached a host that never read it: the viewer's toolbar
    /// said "requested", the sharer saw nothing, and there was no way to say
    /// yes. Advertising a capability and providing no way to exercise it is
    /// worse than not advertising it.
    @Published private(set) var controlRequests: [ControlRequestInfo] = []

    /// Who is driving this machine right now, by display name, or nil.
    ///
    /// Drives the "Take back control" action, which is the only way to end a
    /// grant from this side. Already stale-guarded by the engine — the
    /// generation bookkeeping lives there, beside the hop that makes it
    /// necessary.
    @Published private(set) var controlGrantedTo: String?

    /// Posts the sharer's notifications and routes their buttons back.
    ///
    /// Built once for the life of the app rather than per share: connecting to
    /// the bus is the expensive part, and an ask to SHARE arrives precisely
    /// when no share is running.
    private let notifications = SharerNotifications()

    /// Whether this machine has nowhere to post notifications.
    ///
    /// Said on the card, but only while sharing: a sharer who is not looking
    /// at the app is exactly who a notification would have reached, so the one
    /// moment worth telling them it will not is the moment they are about to
    /// stop looking. Off a share it is noise about a feature nobody is using.
    var notificationsUnavailable: Bool { !notifications.isAvailable }

    /// Why the system-wide mute chord could not be taken, mirrored from
    /// `MuteHotkeyController` (see the wiring in `main.swift`) so the share
    /// card can say so — the controller's own report goes to stderr, which
    /// reaches nobody mid-share. Nil while the chord is held, or before a
    /// microphone made holding it worthwhile.
    @Published private(set) var muteHotkeyUnavailability: GlobalHotkeyUnavailability?

    func setMuteHotkeyUnavailability(_ reason: GlobalHotkeyUnavailability?) {
        muteHotkeyUnavailability = reason
    }

    /// Why a grant could not be given, when one could not. Nil renders nothing.
    ///
    /// `grantControl` returning false is otherwise completely silent: the
    /// prompt row disappears (the request was consumed) and nothing happens,
    /// which reads as the button not working. On this host it means the
    /// injector stopped being trusted — XTEST went away under a live share —
    /// so it is rare, and rare-and-silent is exactly the combination that
    /// costs an afternoon.
    @Published private(set) var controlNote: String?

    /// Whether new viewers have to be let in by hand.
    ///
    /// Persisted, and read back at launch through the shared
    /// `ViewerApprovalPreference` so this app, the Windows app and the macOS
    /// app cannot disagree about the default (on) or the
    /// `TAILSCREEN_OPEN_DOOR=1` harness override. Mutate via
    /// `setRequireApproval` — assigning here would change the switch without
    /// telling the live server, which is the one place it matters.
    @Published private(set) var requireApproval: Bool = ViewerApprovalPreference.load()

    /// The encoder knobs the next share will start with.
    ///
    /// Persisted through the portable `QualitySettingsStore` — the same store
    /// and the same key the macOS Settings pane writes, so the model's clamps
    /// and its decode-with-fallback are shared rather than reimplemented.
    /// Read at start rather than pushed live: both non-mac capture backends
    /// take their settings at construction, so a mid-share change lands on the
    /// NEXT share and the card's caption says exactly that.
    @Published private(set) var quality: QualitySettings = QualitySettingsStore.load()

    /// Whether this host can share at all. X11 capture needs a display; on a
    /// Wayland-only or headless session there's nothing to capture, and the UI
    /// should say so rather than offer a button that always fails.
    let canShare: Bool
    /// Why sharing is unavailable, when it is.
    let unavailableReason: String?

    /// Peers asking this machine to share — the engine's inbox, mirrored.
    @Published private(set) var shareRequests: [PendingShareRequest] = []

    /// The share engine: server lifecycle, access control, drawing latch,
    /// voice, and the idle control listener, in
    /// `Packages/TailscreenLinuxBackends` where Linux CI tests it with no GTK.
    private let engine: LinuxShareSession

    /// Supplied by `main` — hands back the live tsnet node to share.
    var nodeProvider: (() -> TailscaleNode?)? {
        get { engine.nodeProvider }
        set { engine.nodeProvider = newValue }
    }

    /// Supplied by `main` — opens a capture device, or throws if there is none.
    ///
    /// A factory rather than an instance because a share is a session: the
    /// device is opened when sharing starts and released when it stops. A
    /// long-lived open would keep the OS microphone indicator lit while idle,
    /// which is exactly the thing a person reads as "this app is listening".
    /// Nil means this build has no capture backend at all.
    var microphoneFactory: (() throws -> MicrophoneCapturing)? {
        get { engine.microphoneFactory }
        set { engine.microphoneFactory = newValue }
    }
    /// Supplied by `main` — plays a viewer's decoded voice on the local device.
    var playRemoteVoice: (([Float]) -> Void)? {
        get { engine.playRemoteVoice }
        set { engine.playRemoteVoice = newValue }
    }

    @Published private(set) var micAvailable = false
    @Published private(set) var micOn = false

    // MARK: Sharer drawing

    /// The sharer's own drawing state — the engine's store, exposed for the
    /// toolbar's ink swatch. The stroke geometry, the undo stack and the
    /// identity-derived colour are shared code rather than a second
    /// implementation on the sharing side.
    var drawing: AnnotationStore { engine.drawing }
    /// The armed tool, or nil when the sharer is not drawing. Mirrors the
    /// engine's latch, which is not observable.
    @Published private(set) var activeTool: AnnotationTool?
    /// Why drawing could not be armed, when it could not.
    ///
    /// Shown rather than swallowed because the failure is invisible otherwise:
    /// the tool would appear selected and the pointer would keep going to the
    /// desktop, which reads as "drawing is broken" rather than "this session
    /// would not let the overlay take the keyboard".
    @Published private(set) var drawingNote: String?

    init(display: String? = nil) {
        let processEnvironment = ProcessInfo.processInfo.environment
        let display = display ?? processEnvironment["DISPLAY"]
        // Probed once, at startup, and deliberately with the call that puts
        // NOTHING on screen. Deciding which backend to use requires knowing
        // whether a portal exists, and a check that raised a consent dialog
        // would mean asking permission in order to decide whether to ask
        // permission.
        let portal = PortalSessionHost()
        let environment = CaptureBackendSelection.Environment(
            session: CaptureBackendSelection.sessionKind(fromEnvironment: processEnvironment),
            x11Display: display,
            portalAvailable: portal.probeAvailability())

        self.display = display
        self.portal = portal
        self.captureEnvironment = environment
        self.canShare = CaptureBackendSelection.canShareAnything(environment: environment)
        self.unavailableReason = CaptureBackendSelection.unavailableReason(environment: environment)
        self.engine = LinuxShareSession(display: display)

        // Worth saying out loud, because it is the case that used to fail
        // SILENTLY: `$DISPLAY` is set on Wayland by XWayland, so the old
        // display-only gate passed and the share captured the XWayland root —
        // whatever X11 apps happened to be running, often nothing at all —
        // while the UI said "Sharing" and viewers saw a blank screen.
        if environment.session == .wayland && !environment.portalAvailable {
            FileHandle.standardError.write(
                Data(
                    """
                    warning: Wayland session with no desktop portal — screen sharing is                     unavailable. (Capturing $DISPLAY here would capture only XWayland,                     which is why it is refused rather than attempted.)\n
                    """.utf8))
        }

        wireEngine()

        // A notification button answers exactly what the card's button does,
        // through the same methods — so there is one implementation of each
        // decision and the two surfaces cannot drift.
        notifications.onAnswer = { [weak self] kind, identity, accept in
            guard let self else { return }
            switch kind {
            case .viewerPending:
                // The identity IS the `"ip:port"` these take.
                accept ? self.approve(identity) : self.deny(identity)
            case .controlRequested:
                guard let requestID = UUID(uuidString: identity) else { return }
                if accept {
                    self.grantControl(to: requestID)
                } else {
                    self.declineControl(requestID)
                }
            case .requestToShare:
                guard let requestID = UUID(uuidString: identity) else { return }
                self.answerShareRequest(id: requestID, accept: accept)
            case .viewerJoined, .viewerLeft:
                // Reports carry no buttons, so nothing can arrive here.
                break
            }
        }
    }

    /// Mirror the engine into the `@Published` surface, and reconcile the
    /// notifications with every snapshot. The engine invokes everything on the
    /// main actor, so nothing here hops.
    private func wireEngine() {
        engine.makeOverlay = { [display] in Self.makeOverlay(display: display) }
        engine.onPhaseChanged = { [weak self] phase in self?.phase = phase }
        engine.onShareDidEnd = { [weak self] reason in self?.shareDidEnd(reason) }
        engine.onViewersChanged = { [weak self] rows in
            guard let self else { return }
            self.viewers = rows
            // Keyed by `ip:port`, deliberately: a genuine rejoin IS news, and
            // the mac viewer-roster path keys the same way for the same
            // reason.
            self.notifications.applyViewers(
                rows.map { NoticeCandidate(identity: $0.id, label: $0.label) })
        }
        engine.onPendingViewersChanged = { [weak self] rows in
            guard let self else { return }
            self.pendingViewers = rows
            // The identity IS the id `approve`/`deny` take, so a button press
            // routes back with nothing to re-derive.
            self.notifications.applyAsk(
                kind: .viewerPending,
                candidates: rows.map { NoticeCandidate(identity: $0.id, label: $0.label) })
        }
        engine.onControlRequestsChanged = { [weak self] rows in
            guard let self else { return }
            self.controlRequests = rows
            // The identity is the connection UUID `grantControl` takes.
            self.notifications.applyAsk(
                kind: .controlRequested,
                candidates: rows.map {
                    NoticeCandidate(identity: $0.id.uuidString, label: $0.displayName)
                })
        }
        engine.onControlGrantChanged = { [weak self] name in self?.controlGrantedTo = name }
        engine.onDrawingChanged = { [weak self] tool, refusal in
            guard let self else { return }
            self.activeTool = tool
            self.drawingNote = refusal.map {
                switch $0 {
                case .noSurface: return L("Drawing needs a compositing desktop")
                case .noKeyboard:
                    return L("This desktop would not let the overlay take the keyboard")
                }
            }
        }
        engine.onVoiceChanged = { [weak self] available, on in
            self?.micAvailable = available
            self?.micOn = on
        }
        engine.onShareRequestsChanged = { [weak self] requests in
            guard let self else { return }
            // Card AND notifications together — an ask that expires from the
            // inbox but keeps its banner is an invitation whose Share button
            // answers a connection that has already gone.
            self.shareRequests = requests
            self.notifications.applyAsk(
                kind: .requestToShare,
                candidates: requests.map {
                    NoticeCandidate(identity: $0.id.uuidString, label: $0.fromHostname)
                })
        }
        engine.onAccessChanged = { [weak self] in self?.accessGeneration &+= 1 }
        engine.onStartShareRequested = { [weak self] in self?.startSharing() }
    }

    /// The cleanup only this side can do when a share stops being live. Fired
    /// by the engine BEFORE the rosters empty, which is what keeps the
    /// notification teardown ahead of the empty-list reconcile — see
    /// `LinuxShareSession.onShareDidEnd`.
    private func shareDidEnd(_ reason: LinuxShareSession.EndReason) {
        switch reason {
        case .stopped:
            notifications.stop()
            controlNote = nil
        case .captureStopped:
            notifications.stop()
            controlNote = nil
            // Same reason as `stopSharing`: capture ending for any reason —
            // including the user pressing stop in the compositor's own
            // indicator — must take the session down with it.
            portal.close()
            canChangeSource = false
            captureMatchesOverlay = false
            // A preview that outlives its capture is the worst version of
            // this feature: a still picture of a screen that is no longer
            // going anywhere, indistinguishable from a live one.
            preview = nil
        case .startFailed:
            captureMatchesOverlay = false
            preview = nil
        }
    }

    /// Whether this machine can share ONE WINDOW OR APP, as opposed to the
    /// whole screen. Only the portal can, so this is false on a session with
    /// no portal even when screen sharing works perfectly.
    ///
    /// Derived from the same `choose` the share path runs, never asked
    /// separately: a button that offered a share the backend then refused
    /// would be the two disagreeing, which is the failure `canShareAnything`
    /// exists to prevent on the primary button.
    var canShareWindow: Bool {
        if case .unavailable = CaptureBackendSelection.choose(
            intent: .windowOrApp, environment: captureEnvironment)
        {
            return false
        }
        return true
    }

    /// Whether the LIVE share is portal-backed, and therefore re-pointable.
    ///
    /// Not the same question as `canShareWindow`: a machine can have a portal
    /// while the current share is X11 root capture, and that share has nothing
    /// to change — an X11 session captures exactly one thing.
    @Published private(set) var canChangeSource = false

    /// Whether the overlay's rectangle is genuinely what is being captured.
    ///
    /// **The outline must not lie.** `makeOverlay` sizes the window from the X
    /// display, because that is the only geometry this side reliably has — the
    /// portal hands back a stream size but no position on screen, so a share of
    /// one window gets an overlay the size of the whole desktop. For
    /// annotations that is a pre-existing coordinate problem; for the outline
    /// it is worse in kind, because a border around the entire screen while one
    /// window is being shared states the opposite of the truth.
    ///
    /// So the indicator is shown only where the two are known to agree: an X11
    /// display share. A portal share gets no outline rather than a wrong one —
    /// the same call the capability bits make everywhere else here.
    private var captureMatchesOverlay = false

    /// The most recent preview of what viewers are receiving, or nil when
    /// nothing is being captured.
    ///
    /// `ThumbnailScaler.Thumbnail` rather than the card's `HubPreview`: this
    /// model is deliberately free of the UI package, and the mapping is one
    /// line at the render site.
    @Published private(set) var preview: ThumbnailScaler.Thumbnail?

    private let display: String?
    /// Owns the D-Bus session for the whole app; see `PortalSessionHost`.
    private let portal: PortalSessionHost
    /// What this machine can capture with. Fixed at startup — a session does
    /// not become Wayland halfway through.
    private let captureEnvironment: CaptureBackendSelection.Environment

    var statusLine: String {
        switch phase {
        case .idle: return unavailableReason ?? L("Not sharing")
        case .starting: return L("Starting share…")
        case .sharing:
            if !pendingViewers.isEmpty {
                return L("\(pendingViewers.count) waiting for approval")
            }
            return viewers.isEmpty
                ? L("Sharing — nobody watching yet") : L("Sharing to \(viewers.count)")
        case .failed(let why): return L("Share failed: \(why)")
        }
    }

    /// Begin sharing this host's screen.
    ///
    /// Which backend that means is `CaptureBackendSelection`'s answer, not this
    /// method's: X11 root capture where it is genuinely an X11 session, the
    /// ScreenCast portal on Wayland. The portal branch raises a consent dialog
    /// and therefore has to go around the main thread, which is why the two
    /// paths diverge here rather than at the capture factory.
    func startSharing() {
        guard canShare, phase == .idle || isFailed else { return }
        switch CaptureBackendSelection.choose(
            intent: .entireScreen, environment: captureEnvironment)
        {
        case .x11(let display):
            // One display, one root window: nothing to re-point at.
            canChangeSource = false
            captureMatchesOverlay = true
            let sink = previewSink()
            beginShare(captureFactory: {
                let encoder = X11CaptureEncoder(display: display)
                encoder.onPreviewThumbnail = sink
                return encoder
            })
        case .portal:
            // `.monitor`: this entry point is "share my screen". Offering the
            // window picker here would mean the primary button sometimes
            // shares a window without being asked to.
            beginPortalShare(sources: [.monitor])
        case .unavailable(let reason):
            phase = .failed(reason)
        }
    }

    /// Begin sharing ONE WINDOW OR APP.
    ///
    /// Always the portal — X11 root capture cannot scope to a window, and
    /// `choose` refuses rather than widening the request to the whole screen.
    /// The portal draws its own picker, so this app deliberately does not have
    /// a window list: the compositor knows which windows exist and which the
    /// person is allowed to see, and duplicating that would be both redundant
    /// and less trustworthy.
    func startWindowShare() {
        guard canShareWindow, phase == .idle || isFailed else { return }
        switch CaptureBackendSelection.choose(
            intent: .windowOrApp, environment: captureEnvironment)
        {
        case .portal:
            // `.window` alone, not `[.monitor, .window]`: the person asked for
            // a window, and portals render the requested source types as tabs
            // — offering Screen back would be the app second-guessing a choice
            // already made on the card.
            beginPortalShare(sources: [.window])
        case .x11, .unavailable:
            // Unreachable while `canShareWindow` gates the button, and handled
            // rather than force-unwrapped because the gate and this switch are
            // two reads of one decision that could drift.
            phase = .failed(L("this session cannot share a single window"))
        }
    }

    /// Ask for consent, then share what the portal granted.
    ///
    /// The negotiation is awaited rather than blocked on: the dialog is a
    /// person, `negotiate` blocks its thread until they answer, and this is the
    /// GTK main thread. Blocking here would freeze the whole app for as long as
    /// the dialog was up.
    private func beginPortalShare(sources: PortalSession.SourceTypes = [.monitor]) {
        phase = .starting
        let portal = self.portal
        Task { @MainActor in
            switch await portal.negotiate(sources: sources) {
            case .granted(let nodeID):
                canChangeSource = true
                // See `captureMatchesOverlay`: the portal gives a stream size
                // but no position, so the overlay's rectangle is the desktop's
                // and the capture's may be a single window inside it.
                captureMatchesOverlay = false
                let sink = previewSink()
                beginShare(captureFactory: {
                    let encoder = PortalCaptureEncoder(
                        nodeID: nodeID,
                        openFileDescriptor: { try portal.openPipeWireFileDescriptor() })
                    encoder.onPreviewThumbnail = sink
                    return encoder
                })
            case .cancelled:
                // A person declining to share their screen is not a failure,
                // and an error placard would be the app arguing with a
                // deliberate choice. Straight back to idle, saying nothing.
                phase = .idle
            case .failed(let reason):
                phase = .failed(reason)
            }
        }
    }

    /// Re-point a live share at something else, without dropping the viewers
    /// already watching.
    ///
    /// Portal-only, and it necessarily raises a second consent dialog: the
    /// portal grants a session for what the person picked, so picking
    /// something else is a new grant. That is the portal's design and not
    /// something to route around — the alternative would be a share that could
    /// silently widen its own scope after consent was given.
    ///
    /// Offers BOTH monitors and windows regardless of what the share started
    /// as: this is the moment the person is explicitly re-choosing, so
    /// narrowing them to the kind they picked last time would be the app
    /// deciding for them.
    ///
    /// Declining leaves the existing share running and untouched — the
    /// dialog was about a *change*, so refusing it means "keep what I have",
    /// not "stop sharing".
    func changeSource() {
        guard canChangeSource, phase == .sharing else { return }
        let portal = self.portal
        Task { @MainActor in
            switch await portal.negotiate(sources: [.monitor, .window]) {
            case .granted(let nodeID):
                let selection = PickerSelection(
                    kind: .display, displayID: 0, windowID: nil, bundleIDs: [])
                guard let selectionData = try? JSONEncoder().encode(selection) else { return }
                do {
                    // The new factory travels WITH the data: this backend is
                    // built against a PipeWire node id, so swapping the
                    // selection bytes alone would restart the old source.
                    _ = try await engine.changeSource(
                        filterData: selectionData,
                        captureFactory: { [sink = previewSink()] in
                            let encoder = PortalCaptureEncoder(
                                nodeID: nodeID,
                                openFileDescriptor: { try portal.openPipeWireFileDescriptor() })
                            encoder.onPreviewThumbnail = sink
                            return encoder
                        })
                } catch {
                    phase = .failed(L("could not change the shared source: \(error)"))
                }
            case .cancelled:
                // Keep sharing what we were already sharing. Saying nothing is
                // the whole point: they declined a change, not the share.
                break
            case .failed(let reason):
                phase = .failed(reason)
            }
        }
    }

    /// The callback every capture backend publishes its preview through.
    ///
    /// Attached inside each capture factory rather than passed through
    /// `beginShare`, because the property lives on the concrete backend and the
    /// factory is the only place its type is known — and because a factory that
    /// carries the sink keeps publishing across the server's restart budget,
    /// which is the whole reason `onTimings` on Windows is shaped this way too.
    ///
    /// Fires on a capture thread (PipeWire's, for the portal), so it hops.
    private func previewSink() -> @Sendable (ThumbnailScaler.Thumbnail) -> Void {
        { [weak self] thumbnail in
            Task { @MainActor in self?.preview = thumbnail }
        }
    }

    /// Everything after "which backend": hand the engine the node and the
    /// capture factory. The engine owns the rest of the start sequence.
    private func beginShare(captureFactory: @escaping @Sendable () -> CaptureEncoding) {
        guard let node = nodeProvider?() else {
            phase = .failed(L("Tailscale isn't up yet"))
            return
        }
        let selection = PickerSelection(kind: .display, displayID: 0, windowID: nil, bundleIDs: [])
        guard let selectionData = try? JSONEncoder().encode(selection) else {
            phase = .failed(L("could not describe the display to capture"))
            return
        }
        engine.beginShare(
            node: node,
            selectionData: selectionData,
            quality: quality,
            // Only true when the overlay's rectangle is genuinely the
            // captured one — see `captureMatchesOverlay`.
            showsOutline: captureMatchesOverlay,
            captureFactory: captureFactory)
    }

    func stopSharing() {
        // Ending the portal session is what makes the compositor drop its own
        // "your screen is being shared" indicator. Leaving it open would tell
        // the person their screen is still going out after they stopped it —
        // and on some desktops leaves the indicator until the process dies.
        portal.close()
        canChangeSource = false
        preview = nil
        captureMatchesOverlay = false
        engine.stopSharing()
    }

    // MARK: Drawing

    /// Arm a drawing tool, or disarm with nil. Selecting the armed tool again
    /// disarms it, matching the viewer's toolbar. The arm/disarm ordering —
    /// and the refusal when the overlay cannot also take the keyboard — is the
    /// engine's `SharerDrawingLatch`; this only forwards and words the
    /// refusal.
    func selectTool(_ tool: AnnotationTool?) {
        engine.selectTool(tool)
    }

    /// Undo the sharer's own last stroke. Viewers' strokes are theirs to undo.
    func undoDrawing() {
        engine.undoDrawing()
    }

    /// Clear every stroke, from anyone. The sharer owns the screen.
    func clearDrawing() {
        engine.clearDrawing()
    }

    // MARK: Voice

    /// Flip the sharer's microphone.
    func toggleMic() {
        engine.toggleMic()
    }

    /// Build the overlay at the capture's exact pixel geometry, or nil if this
    /// session cannot host one.
    ///
    /// The size comes from an `X11ScreenCapture` rather than from GDK's
    /// monitor list because it must match what the encoder actually sends:
    /// `captureWidth`/`captureHeight` round down to even for I420, and
    /// annotations are normalized against the encoded frame.
    private static func makeOverlay(display: String?) -> SharerOverlaySurface? {
        guard SharerAnnotationOverlay.isSupported else { return nil }
        guard let probe = try? X11ScreenCapture(display: display) else { return nil }
        return SharerAnnotationOverlay(
            width: probe.captureWidth, height: probe.captureHeight)
    }

    // MARK: Incoming asks to share

    /// Bring up (or re-point) the idle control listener.
    ///
    /// Idempotent per node and safe to call on every node change — which is
    /// how it is called, because there is no single moment when "the node is
    /// ready" that this model observes. A listener already bound to the same
    /// node is left alone.
    func ensureControlListener() {
        engine.ensureControlListener()
    }

    /// Answer an ask: reply on its own connection, and on accept pre-approve
    /// the asker and start sharing (the engine calls back into
    /// `startSharing()` for the last step — picking a backend is this side's
    /// job).
    func answerShareRequest(id: UUID, accept: Bool) {
        engine.answerShareRequest(id: id, accept: accept)
    }

    /// What is remembered about a row's peer, for the roster's label.
    func remembered(stableID: String?) -> PeerPolicy? { engine.remembered(stableID: stableID) }

    /// Whether a decision on this row is queued behind identity resolution.
    func isDeferred(rowID: String) -> Bool { engine.isDeferred(rowID: rowID) }

    /// "Always Allow" / "Deny & Block" on a roster row.
    ///
    /// Persisting fires the engine's `onPoliciesChanged`, which pushes the map
    /// at the live server — which is what makes a block on somebody already
    /// watching actually expel them, rather than merely stop them coming back.
    func remember(rowID: String, stableID: String?, label: String, policy: PeerPolicy) {
        engine.remember(rowID: rowID, stableID: stableID, label: label, policy: policy)
    }

    /// Drop what is remembered about a row's peer.
    func forget(rowID: String, stableID: String?) {
        engine.forget(rowID: rowID, stableID: stableID)
    }

    /// One-time disconnect of a connected viewer — the roster's Disconnect.
    ///
    /// Nothing is remembered: their next HELLO goes back through the normal
    /// admission gate. That is the difference between this and Deny & Block,
    /// and it is why both exist.
    func disconnect(_ addr: String) { engine.disconnect(addr) }

    /// Admit a viewer parked at the approval gate. `addr` is the
    /// `PendingViewer.id` (`"ip:port"`), never a bare IP.
    func approve(_ addr: String) { engine.approve(addr) }
    /// Reject a viewer parked at the approval gate.
    func deny(_ addr: String) { engine.deny(addr) }

    // MARK: Remote control

    /// Hand the pointer and keyboard to a viewer who asked for them.
    ///
    /// The server holds ONE grantee at a time and gates injection on that
    /// exact connection id, so this is the whole of the decision — there is no
    /// second switch to also set. It returns false when the request is already
    /// gone (the viewer gave up, or disconnected), which is not an error worth
    /// an alert: the row disappears on the next snapshot either way.
    ///
    /// **Keyboard reaches the whole machine, not the shared window.** X11
    /// delivers a synthetic key to whatever has focus, and scoping it is not
    /// something XTEST can do — the same warning the macOS grant carries.
    @discardableResult
    func grantControl(to requestID: UUID) -> Bool {
        let granted = engine.grantControl(to: requestID)
        controlNote = granted ? nil : L("Remote control isn't available for this share.")
        return granted
    }

    /// Refuse a request without granting anything. The viewer is told.
    func declineControl(_ requestID: UUID) {
        engine.declineControl(requestID)
    }

    /// End a live grant. The viewer is told why, so a pointer that stops
    /// moving reads as a decision rather than a fault.
    func revokeControl() {
        engine.revokeControl()
    }

    /// Change the encoder knobs and remember them.
    ///
    /// Deliberately does NOT touch a running share: the capture backend was
    /// built with the old values and there is no re-push path on this host, so
    /// pretending otherwise would be a control that appears to work.
    func setQuality(_ new: QualitySettings) {
        let normalized = new.normalized()
        guard normalized != quality else { return }
        quality = normalized
        QualitySettingsStore.save(normalized)
    }

    /// Flip the approval gate, persist it, and push it at a live share.
    ///
    /// Applied mid-share on purpose: `setRequireApproval(false)` drains
    /// whoever is already parked (minus anyone remembered-deny), so turning
    /// the gate off is also how you admit a queue in one click. Turning it on
    /// mid-share affects the next HELLO — viewers already admitted stay
    /// admitted, exactly as on macOS.
    func setRequireApproval(_ enabled: Bool) {
        guard enabled != requireApproval else { return }
        requireApproval = enabled
        ViewerApprovalPreference.save(enabled)
        engine.setRequireApproval(enabled)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}

/// A stable, tailnet-legal node name for this host's share-capable node.
///
/// Stable across launches on purpose: a peer that reconnects should find the
/// same screen rather than a new one each time the app restarts. Sanitised by
/// the shared `TailscreenInstance.nodeLabel` — tsnet hostnames are DNS labels,
/// and this rule used to be written per-app with only this copy correct.
@MainActor
func localShareName() -> String {
    TailscreenInstance.nodeLabel(from: ProcessInfo.processInfo.hostName, fallback: "linux")
}
