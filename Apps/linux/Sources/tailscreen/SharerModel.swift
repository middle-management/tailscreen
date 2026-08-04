import Foundation
import SwiftCrossUI
import TailscaleKit
import TailscreenSharer
import TailscreenSharerLinux
import TailscreenViewerTsnet
import X11CaptureKit

// Targeted imports: pulling in all of TailscreenProtocol collides with
// SwiftCrossUI's own `Published` / `ObservableObject` shims on Linux.
import struct TailscreenProtocol.AccountProfileLayout
import enum TailscreenProtocol.PeerPolicy
import class TailscreenProtocol.PeerAccessStore
import class TailscreenProtocol.SharerAccessCoordinator
import struct TailscreenProtocol.PickerSelection
import enum TailscreenProtocol.CaptureBackendSelection
import enum TailscreenProtocol.ThumbnailScaler
import protocol TailscreenSharer.CaptureEncoding
import class TailscreenSharerPortal.PortalCaptureEncoder
import class PortalCaptureKit.PortalSession

import struct TailscreenProtocol.QualitySettings
import enum TailscreenProtocol.QualitySettingsStore
import struct TailscreenProtocol.PendingShareRequest
import enum TailscreenProtocol.ScreenShareMessage
import struct TailscreenProtocol.ShareRequestInbox
import enum TailscreenProtocol.ViewerApprovalPreference
import enum TailscreenProtocol.ViewerRosterDecision
import class TailscreenTransport.TailscreenControlListener
import class TailscreenProtocol.AnnotationStore
import enum TailscreenProtocol.AnnotationMode
import enum TailscreenProtocol.AnnotationTool
import enum TailscreenProtocol.AnnotationOp
import struct TailscreenProtocol.SharerDrawingLatch
import enum TailscreenProtocol.SharerDrawingArmResult
import enum TailscreenProtocol.SharerDrawingRefusal
import class TailscreenAudio.OpusVoiceEncoder
import class TailscreenAudio.SharerVoice
import protocol TailscreenAudio.MicrophoneCapturing

/// Somebody currently watching, as the share card needs them.
///
/// `stableID` rides along because the roster's remember/forget actions are
/// about the PERSON, not the connection: the store is keyed by Tailscale
/// StableNodeID and nothing else is safe to key on. It is nil until the netmap
/// lookup lands, which is what `SharerAccessCoordinator` queues around.
///
/// File scope, like `PendingViewer` and for the same reason: the server's
/// callback is not on the main actor and it is the code that builds these.
struct ConnectedViewer: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let stableID: String?
    let health: String?
}

/// A viewer parked at the approval gate, as the share card needs it.
///
/// `id` is the server's own viewer key — `"ip:port"`, not the bare IP. That
/// distinction is the whole reason this is a struct rather than a string:
/// `approveViewer` and `denyViewer` look the address up in the pending map, and
/// an IP with the port dropped matches nothing, so both silently no-op. The
/// sharer gets a row with two buttons that do nothing and the viewer waits
/// forever. `label` is the readable half — a hostname once the netmap lookup
/// lands, the IP until then.
///
/// File scope rather than nested in `SharerModel`, which is `@MainActor`: the
/// server's pending callback is not, and it is the code that builds these.
struct PendingViewer: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    /// See `ConnectedViewer.stableID` — "Always Allow" / "Deny & Block" on a
    /// pending row persists under this, not under the hostname a peer sends.
    let stableID: String?
}

/// Drives the *sharing* half of the app: start/stop a share, and publish who's
/// watching so the chrome can render it.
///
/// The counterpart of `PickerModel`, and deliberately just as thin. Everything
/// that makes sharing work — admission, RTP fan-out, NACK/FEC, congestion
/// control, the idle sweep — is the portable `TailscaleScreenShareServer`; this
/// only decides *what* to capture and marshals state onto the main actor for
/// the UI.
///
/// **It borrows the viewer's tsnet node** rather than bringing up its own. Two
/// nodes would mean two tailnet identities for one app: peers would see a
/// phantom second machine, and the sharer wouldn't be reachable at the address
/// the viewer half advertises. The macOS app solves this the same way —
/// `AppState` owns one node and passes it to both the server and the client.
@MainActor
final class SharerModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case sharing
        case failed(String)
    }

    @Published var phase: Phase = .idle
    /// Bumped whenever the remembered-policy layer changes.
    ///
    /// SwiftCrossUI's `ObservableObject` shim has no `objectWillChange`, and
    /// the thing that changed lives in `SharerAccessCoordinator` rather than in
    /// a `@Published` here — deliberately, since it is portable and this app
    /// only renders it. A counter is the shim's idiom for "something you cannot
    /// see moved"; the roster rows read the coordinator when they redraw.
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

    private var server: TailscaleScreenShareServer?

    /// Peers asking this machine to share, coalesced and bounded by the
    /// portable `ShareRequestInbox`.
    @Published private(set) var shareRequests: [PendingShareRequest] = []
    private var inbox = ShareRequestInbox()

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

    /// IPs accepted before there was a server to tell.
    ///
    /// Accepting an ask has to pre-approve the requester, or they arrive at
    /// this machine's own approval gate a second later and get asked to wait —
    /// having just been invited. But accept happens *before* the share starts,
    /// so there is no server yet: the IP is held here and replayed the moment
    /// one exists.
    private var pendingPreApprovedIPs: Set<String> = []

    /// Remembered allow/deny, and the queue for decisions made before a peer's
    /// identity resolved. Portable and tested on Linux CI — this app only
    /// renders rows and forwards taps.
    ///
    /// Built once and outliving each share on purpose: what a sharer decided
    /// about somebody is not a property of the session they decided it in.
    private let access = SharerAccessCoordinator(
        store: PeerAccessStore(directory: AccountProfileLayout.xdg().root))
    /// Viewers' strokes, drawn on this machine's own screen. Nil when the
    /// session cannot host one — see `SharerAnnotationOverlay.isSupported`.
    private var overlay: SharerAnnotationOverlay?
    /// Granted viewers' input, replayed on this machine. Nil when this X
    /// server has no XTEST extension.
    ///
    /// Held for the share's lifetime rather than handed to the server and
    /// forgotten, because the server's own teardown is asynchronous and the
    /// grant must be sealed the moment sharing stops — see `teardownOverlay`,
    /// which does the same for the same reason.
    private var injector: X11InputInjector?
    /// Supplied by `main` — hands back the live tsnet node to share.
    var nodeProvider: (() -> TailscaleNode?)?

    /// Supplied by `main` — opens a capture device, or throws if there is none.
    ///
    /// A factory rather than an instance because a share is a session: the
    /// device is opened when sharing starts and released when it stops. A
    /// long-lived open would keep the OS microphone indicator lit while idle,
    /// which is exactly the thing a person reads as "this app is listening".
    /// Nil means this build has no capture backend at all.
    var microphoneFactory: (() throws -> MicrophoneCapturing)?
    /// Supplied by `main` — plays a viewer's decoded voice on the local device.
    var playRemoteVoice: (([Float]) -> Void)?

    /// Live voice for the current share. Nil while idle, and nil when the
    /// device could not be opened — which is what `micAvailable` reports, so
    /// the control is absent rather than present-and-inert.
    private var voice: SharerVoice?
    @Published private(set) var micAvailable = false
    @Published private(set) var micOn = false

    // MARK: Sharer drawing

    /// The sharer's own drawing state — the same store the viewers run, so the
    /// stroke geometry, the undo stack and the identity-derived colour are
    /// shared code rather than a second implementation on the sharing side.
    let drawing = AnnotationStore()
    /// Which tool is armed and what a refusal to arm means.
    ///
    /// The decisions live in the portable tier — where Linux CI tests them with
    /// no window, no compositor and no X server — because the Windows sharer
    /// has the same hazard in a different shape and a second copy of this
    /// ordering is where the two would drift. The consequence of drifting is
    /// not a cosmetic difference; it is a desktop nobody can click.
    private var latch = SharerDrawingLatch()
    /// The armed tool, or nil when the sharer is not drawing. Mirrors
    /// `drawing.mode`, which is not observable.
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
        case .idle: return unavailableReason ?? "Not sharing"
        case .starting: return "Starting share…"
        case .sharing:
            if !pendingViewers.isEmpty {
                return "\(pendingViewers.count) waiting for approval"
            }
            return viewers.isEmpty ? "Sharing — nobody watching yet" : "Sharing to \(viewers.count)"
        case .failed(let why): return "Share failed: \(why)"
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
            phase = .failed("this session cannot share a single window")
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
        guard canChangeSource, phase == .sharing, let server else { return }
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
                    _ = try await server.changeSource(
                        filterData: selectionData,
                        captureFactory: { [sink = previewSink()] in
                            let encoder = PortalCaptureEncoder(
                                nodeID: nodeID,
                                openFileDescriptor: { try portal.openPipeWireFileDescriptor() })
                            encoder.onPreviewThumbnail = sink
                            return encoder
                        })
                } catch {
                    phase = .failed("could not change the shared source: \(error)")
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

    /// Everything after "which backend": identical for both.
    private func beginShare(captureFactory: @escaping @Sendable () -> CaptureEncoding) {
        guard let node = nodeProvider?() else {
            phase = .failed("Tailscale isn't up yet")
            return
        }
        phase = .starting

        let selection = PickerSelection(kind: .display, displayID: 0, windowID: nil, bundleIDs: [])
        guard let selectionData = try? JSONEncoder().encode(selection) else {
            phase = .failed("could not describe the display to capture")
            return
        }

        let display = self.display

        // The annotation overlay has to exist BEFORE the server, because
        // whether it exists is what the server advertises. Sized from the
        // capture's own geometry, not the monitor's: annotations arrive
        // normalized against the frame a viewer sees, and the capture rounds
        // both dimensions down to even for I420, so a screen with an odd
        // dimension would put every stroke a pixel out.
        let overlay = Self.makeOverlay(display: display)
        if overlay == nil {
            // Worth a line: the share works perfectly and viewers simply find
            // their drawing tools greyed out, with nothing on either end
            // saying why. Matches this app's other diagnostics (stderr, not a
            // logger — there is no TSLogger convention on this side).
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
            // compositor there is none (see `SharerAnnotationOverlay`), and a
            // sharer that claims `.annotations` it cannot render leaves every
            // viewer drawing strokes that reach nobody — silently, which is
            // exactly the failure Phase 0 flipped this default to prevent.
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
        server.onCaptureStopped = { error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.phase = .failed("\(error)")
                } else {
                    self.phase = .idle
                }
                self.viewers = []
                self.pendingViewers = []
                self.teardownOverlay()
                self.stopVoice()
                // Same reason as `stopSharing`: capture ending for any reason
                // — including the user pressing stop in the compositor's own
                // indicator — must take the session down with it.
                self.portal.close()
                self.canChangeSource = false
                // A preview that outlives its capture is the worst version of
                // this feature: a still picture of a screen that is no longer
                // going anywhere, indistinguishable from a live one.
                self.preview = nil
            }
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
                phase = .sharing
                // Only once the share is genuinely up: an indicator that
                // appeared while the capture was still opening would say
                // "they can see this" before anyone could.
                overlay?.setShowsOutline(captureMatchesOverlay)
                startVoice(on: server)
            } catch {
                phase = .failed("\(error)")
                self.server = nil
                self.teardownOverlay()
                self.stopVoice()
                self.preview = nil
            }
        }
    }

    func stopSharing() {
        // Ending the portal session is what makes the compositor drop its own
        // "your screen is being shared" indicator. Leaving it open would tell
        // the person their screen is still going out after they stopped it —
        // and on some desktops leaves the indicator until the process dies.
        portal.close()
        canChangeSource = false
        preview = nil
        guard let server else {
            phase = .idle
            teardownOverlay()
            return
        }
        self.server = nil
        viewers = []
        pendingViewers = []
        phase = .idle
        // Queued decisions do not outlive the share they were made during:
        // the rows are gone, and an intent that survived would land on whoever
        // connects to the NEXT share from the same address.
        access.reset()
        teardownOverlay()
        stopVoice()
        Task { await server.stop() }
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
        overlay: SharerAnnotationOverlay?, server: TailscaleScreenShareServer
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
    func selectTool(_ tool: AnnotationTool?) {
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
        activeTool = latch.activeTool
        drawing.mode = latch.activeTool.map { .drawing($0) } ?? .off
        drawingNote = latch.refusal.map {
            switch $0 {
            case .noSurface: return "Drawing needs a compositing desktop"
            case .noKeyboard: return "This desktop would not let the overlay take the keyboard"
            }
        }
    }

    /// Undo the sharer's own last stroke. Viewers' strokes are theirs to undo.
    func undoDrawing() {
        drawing.undo()
    }

    /// Clear every stroke, from anyone. The sharer owns the screen.
    func clearDrawing() {
        drawing.clearAll()
        overlay?.clear()
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
                    self?.micAvailable = false
                    self?.micOn = false
                }
            }
            // Inbound viewer audio, already vetted by the server's anti-spoof
            // gate. Fires on the receive thread; `VoiceDownlink` does
            // arithmetic only and hands the result on.
            server.onAudioReceived = { [weak voice] packet in voice?.receive(packet) }
            try voice.start()
            self.voice = voice
            micAvailable = true
            micOn = false
        } catch {
            FileHandle.standardError.write(
                Data("warning: no microphone (\(error)) — viewers will not hear you\n".utf8))
        }
    }

    private func stopVoice() {
        voice?.stop()
        voice = nil
        micAvailable = false
        micOn = false
    }

    /// Flip the sharer's microphone.
    func toggleMic() {
        guard let voice else { return }
        let nowOn = voice.isMuted
        voice.isMuted = !nowOn
        micOn = nowOn
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
        // succeeded leaves this model believing nothing is armed.
        latch.teardown(surface: armOverlay)
        publishLatch()
        overlay?.setShowsOutline(false)
        captureMatchesOverlay = false
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

    /// Build the overlay at the capture's exact pixel geometry, or nil if this
    /// session cannot host one.
    ///
    /// The size comes from an `X11ScreenCapture` rather than from GDK's
    /// monitor list because it must match what the encoder actually sends:
    /// `captureWidth`/`captureHeight` round down to even for I420, and
    /// annotations are normalized against the encoded frame.
    private static func makeOverlay(display: String?) -> SharerAnnotationOverlay? {
        guard SharerAnnotationOverlay.isSupported else { return nil }
        guard let probe = try? X11ScreenCapture(display: display) else { return nil }
        return SharerAnnotationOverlay(
            width: probe.captureWidth, height: probe.captureHeight)
    }

    // MARK: Roster

    /// Publish a connected-roster snapshot and let the access layer see it.
    ///
    /// The roster is re-emitted whenever anything about it changes — including
    /// a StableNodeID finishing resolution, which is precisely the event a
    /// queued "Deny & Block" is waiting for. So feeding it here, rather than
    /// only on join and leave, is what makes the queue drain at all.
    private func applyConnected(_ rows: [ConnectedViewer]) {
        viewers = rows
        noteRoster()
    }

    private func applyPending(_ rows: [PendingViewer]) {
        pendingViewers = rows
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
            accessGeneration &+= 1
        }
    }

    // MARK: Incoming asks to share

    /// Bring up (or re-point) the idle control listener.
    ///
    /// Idempotent per node and safe to call on every node change — which is
    /// how it is called, because there is no single moment when "the node is
    /// ready" that this model observes. A listener already bound to the same
    /// node is left alone.
    func ensureControlListener() {
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

    private func noteShareRequest(from hostname: String, sourceAddr: String?, connectionID: UUID) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        // Expire first, so a two-minute-old row that the asker has already
        // given up on cannot occupy a slot against a live one.
        _ = inbox.pruneExpired(nowNs: nowNs, ttlNs: Self.shareRequestTTLNs)
        guard
            inbox.record(
                fromHostname: hostname, sourceAddr: sourceAddr,
                connectionID: connectionID, nowNs: nowNs)
        else { return }
        shareRequests = inbox.requests
    }

    /// Matches the requester's own wait (`TailscreenRequestToShareClient`'s
    /// 120 s default). A row that outlives it is a button that does nothing.
    private static let shareRequestTTLNs: UInt64 = 120 * 1_000_000_000

    /// Answer an ask: reply on its own connection, and on accept pre-approve
    /// the asker and start sharing.
    func answerShareRequest(id: UUID, accept: Bool) {
        guard let request = inbox.remove(id: id) else { return }
        shareRequests = inbox.requests

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
        startSharing()
    }

    /// Forget every parked ask — the share started by another route, or the
    /// node went away.
    func clearShareRequests() {
        guard !inbox.requests.isEmpty else { return }
        inbox.removeAll()
        shareRequests = []
    }

    /// What is remembered about a row's peer, for the roster's label.
    func remembered(stableID: String?) -> PeerPolicy? { access.remembered(stableID: stableID) }

    /// Whether a decision on this row is queued behind identity resolution.
    func isDeferred(rowID: String) -> Bool { access.isDeferred(rowID: rowID) }

    /// "Always Allow" / "Deny & Block" on a roster row.
    ///
    /// Persisting fires `onPoliciesChanged`, which pushes the map at the live
    /// server — which is what makes a block on somebody already watching
    /// actually expel them, rather than merely stop them coming back.
    func remember(rowID: String, stableID: String?, label: String, policy: PeerPolicy) {
        access.remember(
            rowID: rowID, stableID: stableID, displayName: label, policy: policy)
        accessGeneration &+= 1
    }

    /// Drop what is remembered about a row's peer.
    func forget(rowID: String, stableID: String?) {
        access.forget(rowID: rowID, stableID: stableID)
        accessGeneration &+= 1
    }

    /// One-time disconnect of a connected viewer — the roster's Disconnect.
    ///
    /// Nothing is remembered: their next HELLO goes back through the normal
    /// admission gate. That is the difference between this and Deny & Block,
    /// and it is why both exist.
    func disconnect(_ addr: String) { server?.disconnectViewer(addr: addr) }

    /// Admit a viewer parked at the approval gate. `addr` is the
    /// `PendingViewer.id` (`"ip:port"`), never a bare IP.
    func approve(_ addr: String) { server?.approveViewer(addr: addr) }
    /// Reject a viewer parked at the approval gate.
    func deny(_ addr: String) { server?.denyViewer(addr: addr) }

    /// Flip the approval gate, persist it, and push it at a live share.
    ///
    /// Applied mid-share on purpose: `setRequireApproval(false)` drains
    /// whoever is already parked (minus anyone remembered-deny), so turning
    /// the gate off is also how you admit a queue in one click. Turning it on
    /// mid-share affects the next HELLO — viewers already admitted stay
    /// admitted, exactly as on macOS.
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

    func setRequireApproval(_ enabled: Bool) {
        guard enabled != requireApproval else { return }
        requireApproval = enabled
        ViewerApprovalPreference.save(enabled)
        server?.setRequireApproval(enabled)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}

/// A stable, tailnet-legal node name for this host's share-capable node.
///
/// Stable across launches on purpose: a peer that reconnects should find the
/// same screen rather than a new one each time the app restarts. Sanitised
/// because tsnet hostnames are DNS labels — anything outside `[a-z0-9-]` would
/// be rejected or silently mangled by the control plane.
@MainActor
func localShareName() -> String {
    let raw = ProcessInfo.processInfo.hostName
    let cleaned = raw.lowercased().map { ch -> Character in
        ch.isLetter || ch.isNumber ? ch : "-"
    }
    let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "linux" : String(trimmed.prefix(48))
}
