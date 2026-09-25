import Foundation
import SwiftCrossUI
import TailscaleKit
import TailscreenL10n
import TailscreenSharer
import TailscreenSharerLinux
import X11CaptureKit

import class PortalCaptureKit.PortalSession
import protocol TailscreenAudio.MicrophoneCapturing
import class TailscreenProtocol.AnnotationStore
import enum TailscreenProtocol.AnnotationTool
import enum TailscreenProtocol.CaptureBackendSelection
import struct TailscreenProtocol.ControlRequestInfo
import enum TailscreenProtocol.GlobalHotkeyUnavailability
import struct TailscreenProtocol.NoticeCandidate
import enum TailscreenProtocol.PeerPolicy
import struct TailscreenProtocol.PendingShareRequest
// Targeted imports: importing all of TailscreenProtocol would collide with
// SwiftCrossUI's own `Published`/`ObservableObject` shims on Linux.
import struct TailscreenProtocol.PickerSelection
import struct TailscreenProtocol.QualitySettings
import enum TailscreenProtocol.QualitySettingsStore
import enum TailscreenProtocol.SharerDrawingRefusal
import enum TailscreenProtocol.SharerNoticeKind
import enum TailscreenProtocol.TailscreenInstance
import enum TailscreenProtocol.ThumbnailScaler
import enum TailscreenProtocol.ViewerApprovalPreference
import protocol TailscreenSharer.CaptureEncoding
import class TailscreenSharerPortal.PortalCaptureEncoder

/// The engine's row types, under the names this app has always used them by.
typealias ConnectedViewer = LinuxShareSession.ConnectedViewer
typealias PendingViewer = LinuxShareSession.PendingViewer

/// Drives the *sharing* half of the app: start/stop a share, and publish who's
/// watching so the chrome can render it.
///
/// A thin façade over `LinuxShareSession` (which owns the engine: server
/// lifecycle, access control, drawing latch, voice, idle control listener,
/// tested headless on Linux CI). What stays here is what needs the UI: the
/// `@Published` mirrors, localized wording, notification reconcile, and the
/// portal negotiation (its consent dialog is inherently UI).
///
/// **Borrows the viewer's tsnet node** rather than bringing up its own — two
/// nodes would mean two tailnet identities for one app. Same solution as
/// macOS's `AppState`.
@MainActor
final class SharerModel: ObservableObject {
    typealias Phase = LinuxShareSession.Phase

    @Published var phase: Phase = .idle
    /// Bumped whenever the remembered-policy layer changes. SwiftCrossUI's
    /// `ObservableObject` shim has no `objectWillChange`, and the change lives
    /// in the engine's `SharerAccessCoordinator`, not a `@Published` here —
    /// a counter is the shim's idiom for "something you can't see moved".
    @Published private(set) var accessGeneration = 0

    /// Who is watching, for the sharing card's roster.
    @Published var viewers: [ConnectedViewer] = []
    /// Viewers parked awaiting approval, when the approval gate is on.
    @Published var pendingViewers: [PendingViewer] = []

    /// Viewers asking to drive this machine. The engine only advertises
    /// `ScreenShareCaps.remoteControl` (offering Request Control at all) when
    /// XTEST gives it an `X11InputInjector`.
    @Published private(set) var controlRequests: [ControlRequestInfo] = []

    /// Who is driving this machine right now, by display name, or nil. Drives
    /// "Take back control". Already stale-guarded by the engine's generation
    /// bookkeeping.
    @Published private(set) var controlGrantedTo: String?

    /// Posts the sharer's notifications and routes their buttons back. Built
    /// once for the app's life, not per share: connecting to the bus is the
    /// expensive part, and an ask to share arrives precisely when none is
    /// running.
    private let notifications = SharerNotifications()

    /// Whether this machine has nowhere to post notifications. Shown only
    /// while sharing — off a share it's noise about a feature nobody is
    /// using.
    var notificationsUnavailable: Bool { !notifications.isAvailable }

    /// Why the system-wide mute chord could not be taken, mirrored from
    /// `MuteHotkeyController` so the share card can say so (its own report
    /// goes to stderr, which reaches nobody mid-share).
    @Published private(set) var muteHotkeyUnavailability: GlobalHotkeyUnavailability?

    func setMuteHotkeyUnavailability(_ reason: GlobalHotkeyUnavailability?) {
        muteHotkeyUnavailability = reason
    }

    /// Whether notifications post but their daemon drops the buttons — real on
    /// several minimal daemons: the banner appears but the one-click Accept
    /// doesn't exist, so the card says so.
    var notificationsLackActions: Bool {
        notifications.isAvailable && !notifications.rendersActions
    }

    /// Why a grant could not be given. `grantControl` returning false is
    /// otherwise silent (the prompt row just disappears); on this host it
    /// means XTEST stopped being trusted mid-share.
    @Published private(set) var controlNote: String?

    /// Why the last "Change source…" did not take — a note on a share that's
    /// STILL RUNNING, kept separate from `.failed` because `changeSource`
    /// doesn't stop the server on failure; writing `.failed` here would wrongly
    /// flip `canStart`/`isSharing` while viewers keep watching.
    @Published private(set) var sourceChangeNote: String?

    /// Whether new viewers have to be let in by hand. Persisted via the shared
    /// `ViewerApprovalPreference` so all three apps agree on the default (on)
    /// and the `TAILSCREEN_OPEN_DOOR=1` override. Mutate via
    /// `setRequireApproval`, not by assigning directly — that would skip
    /// telling the live server.
    @Published private(set) var requireApproval: Bool = ViewerApprovalPreference.load()

    /// The encoder knobs the next share will start with. Persisted through
    /// the portable `QualitySettingsStore` (shared with macOS Settings). Read
    /// at start, not pushed live: capture backends take settings at
    /// construction, so a mid-share change lands on the NEXT share.
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
    /// voice, idle control listener; tested headless on Linux CI.
    private let engine: LinuxShareSession

    /// Supplied by `main` — hands back the live tsnet node to share.
    var nodeProvider: (() -> TailscaleNode?)? {
        get { engine.nodeProvider }
        set { engine.nodeProvider = newValue }
    }

    /// Supplied by `main` — opens a capture device, or throws if there's none.
    /// A factory, not an instance: a long-lived open would keep the OS
    /// microphone indicator lit while idle. Nil means no capture backend at
    /// all.
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

    /// The live share link's token + busy flag, mirrored off the engine. Nil
    /// token = link off.
    @Published private(set) var linkToken: String?
    @Published private(set) var linkBusy = false
    /// True while a LINK-ONLY share is running (started signed out — the
    /// guest tunnel is the server's only socket). The card states the mode
    /// rather than drawing a toggle that couldn't be flipped off.
    @Published private(set) var isLinkOnlyShare = false

    /// Supplied by `main` — whether starting a share *right now*, with no
    /// tsnet node, should mint a link-only share rather than refuse. True
    /// exactly on the signed-out pane; deliberately not "is the node nil"
    /// (also nil mid-bring-up, which means "share on my tailnet in a
    /// moment", not "share by link").
    var linkOnlyShareAllowed: (() -> Bool)?

    /// The card's Share via Link toggle / New Link, forwarded to the engine.
    func setLinkSharing(_ on: Bool) { engine.setLinkSharing(on) }
    func rotateLink() { engine.rotateLink() }

    // MARK: Sharer drawing

    /// The sharer's own drawing state — the engine's store, exposed for the
    /// toolbar's ink swatch.
    var drawing: AnnotationStore { engine.drawing }
    /// The armed tool, or nil. Mirrors the engine's latch, which is not
    /// observable.
    @Published private(set) var activeTool: AnnotationTool?
    /// Why drawing could not be armed. Shown, not swallowed: otherwise the
    /// tool would appear selected while clicks kept going to the desktop.
    @Published private(set) var drawingNote: String?

    init(display: String? = nil) {
        let processEnvironment = ProcessInfo.processInfo.environment
        let display = display ?? processEnvironment["DISPLAY"]
        // Probed once at startup, with the call that puts NOTHING on screen —
        // deciding a backend must not itself raise a consent dialog.
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

        // $DISPLAY is set on Wayland by XWayland, so a display-only gate would
        // pass and capture the (likely empty) XWayland root while viewers saw
        // a blank screen — warn instead.
        if environment.session == .wayland && !environment.portalAvailable {
            FileHandle.standardError.write(
                Data(
                    """
                    warning: Wayland session with no desktop portal — screen sharing is                     unavailable. (Capturing $DISPLAY here would capture only XWayland,                     which is why it is refused rather than attempted.)\n
                    """.utf8))
        }

        wireEngine()

        // A notification button routes through the same methods as the
        // card's button, so the two surfaces can't drift.
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

    /// Mirror the engine into the `@Published` surface, and reconcile
    /// notifications with every snapshot. The engine invokes everything on the
    /// main actor, so nothing here hops.
    private func wireEngine() {
        engine.makeOverlay = { [display] in Self.makeOverlay(display: display) }
        engine.onPhaseChanged = { [weak self] phase in self?.phase = phase }
        engine.onShareDidEnd = { [weak self] reason in self?.shareDidEnd(reason) }
        engine.onViewersChanged = { [weak self] rows in
            guard let self else { return }
            self.viewers = rows
            // Keyed by `ip:port`: a genuine rejoin IS news.
            self.notifications.applyViewers(
                rows.map { NoticeCandidate(identity: $0.id, label: $0.label) })
        }
        engine.onPendingViewersChanged = { [weak self] rows in
            guard let self else { return }
            self.pendingViewers = rows
            // The identity IS the id `approve`/`deny` take.
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
        engine.onLinkSharingChanged = { [weak self] token, busy, isLinkOnly in
            self?.linkToken = token
            self?.linkBusy = busy
            self?.isLinkOnlyShare = isLinkOnly
        }
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
            // Card AND notifications together, or an expired ask could keep a
            // banner whose Share button answers a connection already gone.
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
    /// by the engine BEFORE the rosters empty, keeping notification teardown
    /// ahead of the empty-list reconcile.
    private func shareDidEnd(_ reason: LinuxShareSession.EndReason) {
        switch reason {
        case .stopped:
            notifications.stop()
            controlNote = nil
            sourceChangeNote = nil
        case .captureStopped:
            notifications.stop()
            controlNote = nil
            sourceChangeNote = nil
            // Capture ending for any reason (including the compositor's own
            // stop indicator) must take the session down with it.
            portal.close()
            canChangeSource = false
            captureMatchesOverlay = false
            // A preview that outlives its capture would look indistinguishable
            // from a live one.
            preview = nil
        case .startFailed:
            captureMatchesOverlay = false
            preview = nil
        }
    }

    /// Whether this machine can share ONE WINDOW OR APP, as opposed to the
    /// whole screen. Only the portal can. Derived from the same `choose` the
    /// share path runs, never asked separately, so the button and the backend
    /// can't disagree.
    var canShareWindow: Bool {
        if case .unavailable = CaptureBackendSelection.choose(
            intent: .windowOrApp, environment: captureEnvironment)
        {
            return false
        }
        return true
    }

    /// Whether the LIVE share is portal-backed, and therefore re-pointable.
    /// Not the same as `canShareWindow`: a machine can have a portal while the
    /// current share is X11 root capture, which has nothing to change.
    @Published private(set) var canChangeSource = false

    /// Whether the overlay's rectangle is genuinely what is being captured.
    /// `makeOverlay` sizes the window from the X display — the only geometry
    /// this side reliably has, since the portal gives a stream size but no
    /// position — so a single-window portal share gets an overlay the size of
    /// the whole desktop. The outline is shown only when the two are known to
    /// agree (X11 display share); a portal share gets none rather than a
    /// wrong one.
    private var captureMatchesOverlay = false

    /// The most recent preview of what viewers are receiving, or nil.
    /// `ThumbnailScaler.Thumbnail` rather than the card's `HubPreview`: this
    /// model stays free of the UI package.
    @Published private(set) var preview: ThumbnailScaler.Thumbnail?

    private let display: String?
    /// Owns the D-Bus session for the whole app; see `PortalSessionHost`.
    private let portal: PortalSessionHost
    /// What this machine can capture with. Fixed at startup — a session does
    /// not become Wayland halfway through.
    private let captureEnvironment: CaptureBackendSelection.Environment

    /// The card's headline: what this machine is DOING. The viewer count is
    /// the card's own pill beside this line (same split as macOS), so this
    /// stays a constant while sharing rather than rewriting per join.
    var statusLine: String {
        switch phase {
        case .idle: return unavailableReason ?? L("Not sharing")
        case .starting: return L("Starting share…")
        case .sharing: return L("Sharing your screen")
        case .failed(let why): return L("Share failed: \(why)")
        }
    }

    /// The line under the headline. Only ever one thing; the more urgent wins
    /// (someone parked at the approval gate outranks "nobody watching yet").
    /// Nil while idle.
    var statusDetail: String? {
        guard phase == .sharing else { return nil }
        if !pendingViewers.isEmpty {
            return L("\(pendingViewers.count) waiting for approval")
        }
        return viewers.isEmpty ? L("Nobody watching yet") : nil
    }

    /// Seed the sharing-state chrome for `--ui-preview-sharing` — fake data,
    /// no engine, no capture. The one caller allowed to write the
    /// `private(set)` fields without the engine behind them.
    func seedForUIPreview(
        preview thumbnail: ThumbnailScaler.Thumbnail?,
        viewers rows: [ConnectedViewer],
        pending: [PendingViewer],
        micAvailable mic: Bool
    ) {
        phase = .sharing
        preview = thumbnail
        viewers = rows
        pendingViewers = pending
        micAvailable = mic
    }

    /// Begin sharing this host's screen. Which backend is
    /// `CaptureBackendSelection`'s answer; the portal branch raises a consent
    /// dialog and has to go around the main thread, so the two paths diverge
    /// here rather than at the capture factory.
    func startSharing() {
        guard canShare, phase.canStart else { return }
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
            // `.monitor`: this is "share my screen" — offering the window
            // picker here would share a window without being asked.
            beginPortalShare(sources: [.monitor])
        case .unavailable(let reason):
            phase = .failed(reason)
        }
    }

    /// Begin sharing ONE WINDOW OR APP. Always the portal — X11 root capture
    /// can't scope to a window. The portal draws its own picker; this app has
    /// no window list of its own, since the compositor is the trustworthy
    /// source of which windows exist.
    func startWindowShare() {
        guard canShareWindow, phase.canStart else { return }
        switch CaptureBackendSelection.choose(
            intent: .windowOrApp, environment: captureEnvironment)
        {
        case .portal:
            // `.window` alone, not `[.monitor, .window]`: offering Screen back
            // would second-guess a choice already made on the card.
            beginPortalShare(sources: [.window])
        case .x11, .unavailable:
            // Unreachable while `canShareWindow` gates the button; handled
            // rather than force-unwrapped since the two are separate reads of
            // one decision that could drift.
            phase = .failed(L("this session cannot share a single window"))
        }
    }

    /// Ask for consent, then share what the portal granted. Awaited, not
    /// blocked on: `negotiate` blocks its thread until the person answers, and
    /// this is the GTK main thread.
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
                // Not a failure — a deliberate choice. Straight back to idle,
                // saying nothing.
                phase = .idle
            case .failed(let reason):
                phase = .failed(reason)
            }
        }
    }

    /// Re-point a live share at something else, without dropping the viewers
    /// already watching. Portal-only, and necessarily a second consent
    /// dialog: a new selection is a new grant, by the portal's own design.
    /// Offers BOTH monitors and windows, since the person is explicitly
    /// re-choosing. Declining leaves the existing share running untouched.
    func changeSource() {
        guard canChangeSource, phase == .sharing else { return }
        sourceChangeNote = nil
        let portal = self.portal
        Task { @MainActor in
            switch await portal.negotiate(sources: [.monitor, .window]) {
            case .granted(let nodeID):
                let selection = PickerSelection(
                    kind: .display, displayID: 0, windowID: nil, bundleIDs: [])
                guard let selectionData = try? JSONEncoder().encode(selection) else { return }
                do {
                    // The new factory travels WITH the data: swapping only
                    // the selection bytes would restart the old PipeWire node.
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
                    sourceChangeNote = L("could not change the shared source: \(error)")
                }
            case .cancelled:
                break  // declined a change, not the share
            case .failed(let reason):
                sourceChangeNote = reason
            }
        }
    }

    /// The callback every capture backend publishes its preview through.
    /// Attached inside each capture factory, not passed through `beginShare`,
    /// so it keeps publishing across the server's restart budget (same reason
    /// Windows' `onTimings` is shaped this way).
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
        // Nil node is a real mode (signed-out link-only share), not always a
        // failure — `linkOnlyShareAllowed` tells the two apart.
        let node = nodeProvider?()
        if node == nil, linkOnlyShareAllowed?() != true {
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
        // Ending the portal session drops the compositor's sharing indicator;
        // some desktops leave it lit until the process dies otherwise.
        portal.close()
        canChangeSource = false
        preview = nil
        captureMatchesOverlay = false
        engine.stopSharing()
    }

    // MARK: Drawing

    /// Arm a drawing tool, or disarm with nil. Selecting the armed tool again
    /// disarms it. Arm/disarm ordering and the keyboard-focus refusal are the
    /// engine's `SharerDrawingLatch`; this only forwards and words it.
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
    /// session cannot host one. Sized from `X11ScreenCapture`, not GDK's
    /// monitor list, since `captureWidth`/`captureHeight` round down to even
    /// for I420 and annotations are normalized against the encoded frame.
    private static func makeOverlay(display: String?) -> SharerOverlaySurface? {
        guard SharerAnnotationOverlay.isSupported else { return nil }
        guard let probe = try? X11ScreenCapture(display: display) else { return nil }
        return SharerAnnotationOverlay(
            width: probe.captureWidth, height: probe.captureHeight)
    }

    // MARK: Incoming asks to share

    /// Bring up (or re-point) the idle control listener. Idempotent per node
    /// and safe to call on every node change (there's no single "node ready"
    /// moment this model observes).
    func ensureControlListener() {
        engine.ensureControlListener()
    }

    /// Answer an ask: reply on its own connection, and on accept pre-approve
    /// the asker and start sharing (the engine calls back into
    /// `startSharing()` for the last step, since picking a backend is this
    /// side's job).
    func answerShareRequest(id: UUID, accept: Bool) {
        engine.answerShareRequest(id: id, accept: accept)
    }

    /// What is remembered about a row's peer, for the roster's label.
    func remembered(stableID: String?) -> PeerPolicy? { engine.remembered(stableID: stableID) }

    /// Whether a decision on this row is queued behind identity resolution.
    func isDeferred(rowID: String) -> Bool { engine.isDeferred(rowID: rowID) }

    /// "Always Allow" / "Deny & Block" on a roster row. Persisting fires the
    /// engine's `onPoliciesChanged`, pushing the map at the live server — what
    /// makes a block on someone already watching actually expel them.
    func remember(rowID: String, stableID: String?, label: String, policy: PeerPolicy) {
        engine.remember(rowID: rowID, stableID: stableID, label: label, policy: policy)
    }

    /// Drop what is remembered about a row's peer.
    func forget(rowID: String, stableID: String?) {
        engine.forget(rowID: rowID, stableID: stableID)
    }

    /// One-time disconnect of a connected viewer — the roster's Disconnect.
    /// Nothing is remembered: their next HELLO goes back through the normal
    /// admission gate (unlike Deny & Block).
    func disconnect(_ addr: String) { engine.disconnect(addr) }

    /// Admit a viewer parked at the approval gate. `addr` is the
    /// `PendingViewer.id` (`"ip:port"`), never a bare IP.
    func approve(_ addr: String) { engine.approve(addr) }
    /// Reject a viewer parked at the approval gate.
    func deny(_ addr: String) { engine.deny(addr) }

    // MARK: Remote control

    /// Hand the pointer and keyboard to a viewer who asked for them. The
    /// server holds ONE grantee at a time, gated on that connection id.
    /// Returns false when the request is already gone (not worth an alert).
    ///
    /// **Keyboard reaches the whole machine, not the shared window** — X11
    /// delivers synthetic keys to whatever has focus, and XTEST can't scope
    /// that (same warning as the macOS grant).
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

    /// Change the encoder knobs and remember them. Deliberately does NOT
    /// touch a running share: there's no re-push path on this host.
    func setQuality(_ new: QualitySettings) {
        let normalized = new.normalized()
        guard normalized != quality else { return }
        quality = normalized
        QualitySettingsStore.save(normalized)
    }

    /// Flip the approval gate, persist it, and push it at a live share.
    /// Applied mid-share on purpose: `setRequireApproval(false)` drains
    /// whoever is parked (minus remembered-deny), admitting a queue in one
    /// click. Turning it on affects only the next HELLO — as on macOS.
    func setRequireApproval(_ enabled: Bool) {
        guard enabled != requireApproval else { return }
        requireApproval = enabled
        ViewerApprovalPreference.save(enabled)
        engine.setRequireApproval(enabled)
    }

    /// A start that failed. Not private: `startSharing()` and the welcome
    /// pane's retry button both need this same read.
    var isFailed: Bool { phase.hasFailed }
}

/// A stable, tailnet-legal node name for this host's share-capable node.
/// Stable across launches so a reconnecting peer finds the same screen.
/// Sanitised by the shared `TailscreenInstance.nodeLabel` (tsnet hostnames are
/// DNS labels).
@MainActor
func localShareName() -> String {
    TailscreenInstance.nodeLabel(from: ProcessInfo.processInfo.hostName, fallback: "linux")
}
