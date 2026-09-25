import DefaultBackend
import Foundation
import SwiftCrossUI
// The hub's look, shared with the GTK viewer — header, screen rows with their
// detail panes, cards, placards, tokens. Safe to import wholesale: it does not
// re-export TailscreenProtocol, so the `Published` / `ObservableObject`
// collision the targeted imports below exist to dodge does not arrive with it.
import TailscreenHubUI
import TailscreenL10n

// Targeted imports: pulling all of TailscreenProtocol collides with SwiftCrossUI's
// own `Published` / `ObservableObject` shims, the same collision the GTK app
// hits and solves the same way.
import struct TailscreenAudio.VoiceLatch
import class TailscreenAudio.VoiceUplink
import struct TailscreenProtocol.AccountProfileLayout
import class TailscreenProtocol.AccountProfileStore
import enum TailscreenProtocol.AnnotationTool
import struct TailscreenProtocol.CaptureTimings
import struct TailscreenProtocol.ControlRequestInfo
import enum TailscreenProtocol.DiagnosticsHost
import enum TailscreenProtocol.GlobalHotkeyUnavailability
import enum TailscreenProtocol.NodeBringUpPhase
import struct TailscreenProtocol.NoticeCandidate
import struct TailscreenProtocol.PeerListFilter
import enum TailscreenProtocol.PeerListFilterStore
import enum TailscreenProtocol.PeerPolicy
import enum TailscreenProtocol.PeerShareStatusMap
import enum TailscreenProtocol.PeerSharingState
import struct TailscreenProtocol.PendingShareRequest
import class TailscreenProtocol.PortableMuteHotkey
import struct TailscreenProtocol.QualitySettings
import enum TailscreenProtocol.QualitySettingsStore
import enum TailscreenProtocol.ShareBringUpPhase
import enum TailscreenProtocol.ShareLinkFormat
import enum TailscreenProtocol.TailscreenInstance
import struct TailscreenProtocol.TailscreenMetadata
import enum TailscreenProtocol.ViewerApprovalPreference
import enum TailscreenProtocol.ViewerSessionEndReason
import struct TailscreenProtocol.ViewerSessionLifecycle
import struct TailscreenProtocol.ViewerSessionTarget
import enum TailscreenProtocol.WelcomePaneDecision
import class TailscreenSharer.SharerAskToShareCoordinator
// Targeted, like its neighbours: one enum, to word a viewer's link state.
import enum TailscreenSharer.ViewerHealth
import class TailscreenSharerWGC.WindowsShareSession
import class TailscreenVideoFFmpeg.FFmpegVideoDecoder
import class TailscreenViewer.FrameStore
import class TailscreenViewer.FrameStoreVideoSink
import class TailscreenViewer.ThreadedAudioSink
import enum TailscreenViewer.ViewerCloseReason
import struct TailscreenViewerTsnet.DiscoveredSharer
import struct TailscreenViewerTsnet.PeerProbe
import class TailscreenViewerTsnet.TsnetTransport
import struct TailscreenViewerTsnet.ViewerConfig
import enum WGCCaptureKit.WGC

// NOT named main.swift on purpose: Swift rejects `@main` in a file with that
// name, because main.swift is itself top-level code.

/// The Windows app: sign in, pick a peer, watch and hear it, or share.
///
/// Very little of this is Windows-specific: the decoder is the same
/// `FFmpegVideoDecoder` the Linux viewer runs, the colour conversion is
/// `I420Converter`, the PCM conversion is `MonoPCMConverter`, and the
/// off-thread audio wrapper is `ThreadedAudioSink` — all portable and tested
/// on Linux. What's genuinely new is the WinUI surface and the WASAPI sink.
@main
struct TailscreenWindowsApp: App {
    @State var state = AppUIState()

    /// This init must NOT call `WindowsShareSession.prepareProcess()` (DPI
    /// awareness) — it runs BEFORE swift-winui's `WindowsAppRuntimeInitializer`,
    /// whose own `SetProcessDpiAwareness` call then returns E_ACCESSDENIED and
    /// fatalErrors, since awareness was already set. swift-winui's own
    /// per-monitor (v1) awareness is sufficient for the capture-region math;
    /// `prepareProcess()` stays available for non-WinUI hosts (tests, probes).
    ///
    /// `ConsoleBridge` DOES belong here: it touches no DPI/COM/WinUI state, so
    /// it can't re-create the collision above, and stdio needs attaching
    /// before anything prints (GUI-subsystem binary).
    init() {
        ConsoleBridge.attachOrRedirect()
        // Recording is on/off per `DiagnosticsPreference`; no settings toggle
        // on this host yet — `TAILSCREEN_DIAGNOSTICS=1`/`=0` forces it.
        DiagnosticsHost.start(environment: BuildInfo.diagnosticsEnvironment)
    }

    // The view is split into many small, individually-typed pieces rather
    // than one nested expression: inlining ternaries for optional arguments
    // made the Windows compiler give up with "failed to produce diagnostic
    // for expression" against the whole `body`. Same reason the GTK app is
    // written this way.
    var body: some Scene {
        WindowGroup("Tailscreen") {
            VStack(spacing: 0) {
                // The hub header is suppressed while a session owns the
                // window: its subtitle mirrors `status`, which during a
                // session reads the same sentence the session bar already
                // shows next to Stop.
                if state.watching == nil {
                    header
                    Divider()
                }
                content
                Divider()
                footer
            }
        }
        // Opens hub-narrow, like the macOS window and the GTK viewer.
        .defaultSize(width: 480, height: 700)
    }

    private var header: some View {
        ViewerHeader(
            subtitle: state.status,
            showSpinner: state.showsSpinner,
            filter: headerFilter,
            onRefresh: headerRefresh,
            accountName: state.accountMenuLabel,
            accounts: state.accountMenuEntries,
            activeAccountID: state.activeAccountID,
            onSelectAccount: headerSelectAccount,
            onAddAccount: headerAddAccount)
    }

    /// The peer-list filter, offered from the same settled signed-in state as
    /// Refresh. All three axes are live: `peers` keeps offline machines,
    /// `DiscoveredSharer` carries netmap ACL tags, and `sweepShareStatus`
    /// fills the sharing axis off every discovery.
    private var headerFilter: HubFilter? {
        guard state.phase.isReady, state.watching == nil else { return nil }
        let model = state
        return HubFilter(
            filter: model.filter,
            tags: model.knownTags,
            onChange: { model.setFilter($0) })
    }

    /// Refresh, offered only from the settled signed-in state.
    ///
    /// Every action closure captures the MODEL, never `self` — these are
    /// `@MainActor @Sendable`, and a view struct is the wrong thing to send.
    private var headerRefresh: (@MainActor @Sendable () -> Void)? {
        guard state.canRefresh else { return nil }
        let model = state
        return { model.refreshPeers() }
    }

    /// Sign out rides INSIDE the account menu as a row (see
    /// `AppUIState.accountMenuEntries`), since the shared header takes a list
    /// of accounts and one selection callback and nothing else.
    private var headerSelectAccount: (@MainActor @Sendable (String) -> Void)? {
        guard state.showsAccountMenu else { return nil }
        let model = state
        return { model.selectAccountMenuEntry($0) }
    }

    private var headerAddAccount: (@MainActor @Sendable () -> Void)? {
        guard state.showsAccountMenu else { return nil }
        let model = state
        return { model.addAccount() }
    }

    @ViewBuilder private var content: some View {
        if let host = state.watching {
            // The session owns the window from dial to dismissal, but the
            // video UI only renders once ADMITTED — before that the honest
            // state is a placard (connecting / waiting for approval, with a
            // working Cancel), and after a non-user end it is the ended
            // placard with the reason + Reconnect / Back, never a silent
            // snap back to the hub.
            if let phase = state.sessionPhase, phase != .viewing {
                sessionPlacard(host: host, phase: phase)
            } else {
                watching(host: host)
            }
        } else if state.isSignedOut && state.sharing.phase.isLive {
            // Signed out with a share running OR STARTING: the sharing view
            // owns the window rather than stacking with "get started."
            // `isLive` (not `isSharing`) matters because link-only bring-up
            // (relay bootstrap, guest node, server) is the slowest path, and
            // the welcome pane would otherwise sit unresponsive through it.
            signedOutSharing
        } else if state.isSignedOut {
            signIn
        } else {
            hub
        }
    }

    /// The live share, alone, in the hub's own column. Signed out this is the
    /// only surface its link, roster and approvals could be on, so it reads as
    /// the whole window rather than as a postscript to an empty state.
    @ViewBuilder private var signedOutSharing: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let card = state.shareCard {
                    card
                }
            }
            .frame(maxWidth: HubStyle.contentMaxWidth)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The shared session placard, with every action routed at the model. The
    /// placard itself decides which buttons each phase shows (Cancel while
    /// connecting/pending; Reconnect + Back once ended/failed).
    private func sessionPlacard(host: String, phase: HubSessionPhase) -> some View {
        let model = state
        return SessionPlacard(
            phase: phase,
            host: host,
            onReconnect: { model.reconnectSession() },
            onBack: { model.dismissEndedSession() },
            onCancel: { model.disconnect() })
    }

    /// Watching: the video gets the window, with one way out.
    ///
    /// The two bars come from `TailscreenHubUI`, which the GTK viewer already
    /// renders — the dividend the alignment plan predicted for extracting the
    /// chrome. Each is shown only when the sharer advertised the matching
    /// capability, so a sharer that cannot render annotations or inject input
    /// produces a plainer window rather than dead controls.
    private func watching(host: String) -> some View {
        let model = state
        let interaction = state.interaction
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L("Watching \(host)"))
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                Spacer()
                if interaction.isZoomed {
                    Button(L("Reset Zoom")) { interaction.resetZoom() }
                }
                Button(L("Stop")) { model.disconnect() }
            }
            .padding(.horizontal, 16)
            .frame(height: Double(HubStyle.toolbarHeight))
            .frame(maxWidth: .infinity)
            .background(HubStyle.barFill)
            // A strip above the video (not a placard) so the picture stays visible.
            if let notice = state.viewerNotice {
                ViewerNoticeBanner(message: notice) { model.viewerNotice = nil }
            }
            // The annotation toolbar owns the stats toggle; the state stays
            // `AppUIState.showStats` since that's what the fps counter feeds.
            if interaction.annotationsAvailable {
                AnnotationToolbar(
                    activeTool: interaction.activeTool,
                    inkColor: interaction.inkColor,
                    statsShown: state.showStats,
                    onSelectTool: { interaction.selectTool($0) },
                    onSelectColor: { interaction.selectColor($0) },
                    onUndo: { interaction.undoAnnotation() },
                    onClear: { interaction.clearAnnotations() },
                    onToggleStats: { model.showStats.toggle() })
            } else {
                // No annotation toolbar to hang it on — a sharer that withholds
                // the capability must not also cost the viewer its stats.
                HStack {
                    Spacer()
                    Button(state.showStats ? L("Hide stats") : L("Stats")) {
                        model.showStats.toggle()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            // Drawn only after the first fps window closes, or "0x0 · 0 fps"
            // over a running stream reads as broken rather than warming up.
            if state.showStats && state.fps > 0 {
                HStack {
                    StatsHUD(
                        width: state.videoWidth, height: state.videoHeight, fps: state.fps,
                        colorLabel: state.videoColorLabel)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            WinUIVideoView(
                store: state.frameStore,
                generation: state.frameGeneration,
                interaction: interaction)
            if state.micAvailable || interaction.remoteControlAvailable {
                // Each on its own capability: a sharer that can't inject
                // input must not also cost the viewer its microphone.
                HStack(spacing: 8) {
                    if state.micAvailable {
                        MicrophoneButton(
                            isOn: state.micOn, failureNote: state.micFailure,
                            chordHint: state.muteChordHint,
                            onToggle: { model.toggleMic() })
                    }
                    if interaction.remoteControlAvailable {
                        RemoteControlBar(
                            buttonLabel: interaction.controlButtonLabel,
                            declinedReason: interaction.controlDeclinedReason,
                            isControlling: interaction.isControlling,
                            controllingHost: host,
                            onToggle: { interaction.toggleControl() })
                    }
                }
                .padding(12)
            }
        }
    }

    private var signIn: some View {
        let model = state
        // "with", not "to": Tailscale is the identity provider here — the
        // same control the macOS welcome pane and the GTK hub render.
        let label = state.phase.hasFailed ? L("Try again") : L("Sign in with Tailscale")
        return HubSignInPane(
            tailnetMessage: state.welcomeTailnetMessage,
            signInLabel: label,
            onSignIn: { model.signIn() },
            // Beside sign-in, never behind it: both link directions need no
            // Tailscale account.
            onJoin: { token in model.joinShare(token: token) },
            shareAction: state.welcomeShareAction,
            onShare: { model.startSharing() },
            // Kept apart from `detail` (the tailnet card's) so a share
            // failure isn't reported on the sign-in card.
            shareNote: state.shareNote)
    }

    /// The share-by-token way in.
    private var hubJoinCard: HubJoinCard {
        let model = state
        return HubJoinCard(onJoin: { token in model.joinShare(token: token) })
    }

    /// Signed in, or on the way there. `PickerContent` covers both: with
    /// `isPicking` false it shows the login card over a spinner, and with it
    /// true, the Screens list.
    private var hub: some View {
        let model = state
        return PickerContent(
            statusLine: state.status,
            isPicking: state.phase.isReady && !state.isSearching,
            // This hub never enters `.discovering` — it reports its sweep
            // through `isSearching` instead.
            isDiscovering: state.isSearching,
            screens: state.hubScreens,
            loginURL: state.loginURL,
            emptyMessage: L("No Tailscreen screens found on your tailnet."),
            emptyAction: HubAction(
                label: L("Get Tailscreen for your other devices"),
                perform: { model.openInstallPage() }),
            hiddenByFilter: state.hiddenByFilter,
            askingIDs: state.asking,
            askNotes: state.askOutcome,
            onSelect: { id in model.connect(toID: id) },
            onAskToShare: { id in model.askToShare(id: id) },
            onOpenLogin: { model.openLoginURL() },
            shareCard: state.shareCard,
            joinCard: hubJoinCard)
    }

    /// Build stamp, and whatever the last thing to go wrong was.
    private var footer: some View {
        VStack(spacing: 2) {
            if showsDetail {
                Text(state.detail)
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                    .multilineTextAlignment(.center)
            }
            Text(state.environmentLine)
                .font(.caption)
                .foregroundColor(HubStyle.tertiaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(HubStyle.barFill)
    }

    /// The footer carries the last error, except before sign-in — there the
    /// sign-in card already shows it, and repeating it reads as two failures.
    private var showsDetail: Bool {
        guard !state.detail.isEmpty else { return false }
        return !state.phase.isSignedOut
    }
}

/// The server's viewer health as the chrome's, case for case, so
/// TailscreenHubUI can draw the roster without importing the sharer tier.
/// The GTK app carries the twin of this; the WORDING (the part that would
/// actually drift) is written once, in `HubViewerHealth.note`.
private func hubHealth(_ health: ViewerHealth) -> HubViewerHealth {
    switch health {
    case .good: return .good
    case .degraded: return .degraded
    case .throttled: return .throttled
    }
}

/// The window's state machine: sign-in → discovery → list.
///
/// `@MainActor` because `TsnetTransport` is, and because SwiftCrossUI's `App`
/// protocol is too — so a main-actor model can be held in `@State` directly
/// without hopping.
@MainActor
final class AppUIState: ObservableObject {
    /// The shared bring-up vocabulary, in `TailscreenProtocol` so this hub,
    /// the GTK picker and the macOS one name one lifecycle. `discovering` is a
    /// case this hub never enters: it goes straight from `startingNode` to
    /// `ready` and reports its peer sweep through `isSearching` instead.
    typealias Phase = NodeBringUpPhase

    @Published var phase: Phase = .signedOut
    @Published var status = L("Not signed in")
    @Published var detail = ""
    /// A SHARE failure, kept apart from `detail` so it lands on the card that
    /// offered the share, not the sign-in card beside it. Cleared on a fresh attempt.
    @Published var shareDetail: String?
    /// A non-modal notice about a session that is still RUNNING — rendered as
    /// a strip above the video by `ViewerNoticeBanner`. Its own slot rather
    /// than `detail` (the hub's line, not on screen while watching a stream).
    @Published var viewerNotice: String?
    @Published var loginURL: String?
    /// The RAW discovery result. Stays unfiltered so the filter menu can
    /// enumerate its tags and `connect(toID:)` can resolve against it;
    /// `hubScreens` is the filtered projection.
    @Published var peers: [DiscoveredSharer] = []
    /// Per-peer live share status from the metadata sweep, keyed by peer id.
    /// A missing entry is status-UNKNOWN, never "not sharing" — every failure
    /// mode of `fetchMetadata` collapses to nil.
    @Published var shareInfo: [String: TailscreenMetadata] = [:]
    /// Round-trip time of the last successful probe, by peer id. Absent means
    /// no probe has completed — never "fast".
    @Published var latencyMs: [String: Int] = [:]

    /// The encoder knobs the next share will start with. Persisted through the
    /// portable `QualitySettingsStore`, shared with the macOS Settings pane.
    /// Read at share start: `WGCCaptureEncoder` takes its settings at
    /// construction, so a mid-share change lands on the NEXT share.
    @Published private(set) var quality: QualitySettings = QualitySettingsStore.load()

    /// Live video stats for the HUD, counted at the sink. Zero until the
    /// first window closes (~1s in), which is why the HUD only draws once
    /// there's something to draw.
    @Published private(set) var videoWidth = 0
    @Published private(set) var videoHeight = 0
    @Published private(set) var fps = 0
    /// The stream's colour encoding as the decoder reported it, preformatted
    /// ("BT.709 · limited"). Empty until the first stats window closes.
    @Published private(set) var videoColorLabel = ""
    /// Whether the stats HUD is shown. Session-scoped, not persisted — a debugging glance.
    @Published var showStats = false

    /// Whether this machine opened a capture device for the live session.
    /// A box with no microphone shows no button rather than one that cannot unmute.
    @Published private(set) var micAvailable = false
    /// Whether the microphone is live. Starts off: joining a share must never
    /// put somebody on the air, matching the macOS viewer.
    @Published private(set) var micOn = false
    /// Set when the device goes away mid-session.
    @Published private(set) var micFailure: String?
    /// The live session's uplink, cleared in the session tail — a stale one
    /// would leave the microphone open (visible in the Windows tray).
    private var voiceUplink: VoiceUplink?
    /// The two flags above and every transition allowed to move them. Shared
    /// with the GTK viewer and both share engines — see `VoiceLatch`.
    private var voiceLatch = VoiceLatch()
    /// Header filter state, persisted through the portable `PeerListFilterStore`.
    /// Unlike the GTK picker there is no legacy online-only list to preserve
    /// here — this app has always shown offline machines.
    @Published private(set) var filter = PeerListFilterStore.load()
    @Published var isSearching = false
    /// Non-nil while a viewing session OWNS THE WINDOW, from dial until the
    /// session's UI is dismissed — deliberately longer than the session
    /// itself, since the ended placard stays up until the person dismisses it.
    @Published private(set) var viewerLifecycle = ViewerSessionLifecycle()
    /// Toolkit-facing projections. Mutating `viewerLifecycle` publishes the
    /// one source value, so the view still re-renders without parallel
    /// `watching`, phase, peer-id and guest-token slots drifting apart.
    var watching: String? {
        viewerLifecycle.phase == nil ? nil : viewerLifecycle.target?.displayName
    }
    var sessionPhase: HubSessionPhase? { viewerLifecycle.phase }
    /// Bumped per decoded frame so SwiftCrossUI re-runs `updateWinUIElement`.
    /// The frame itself travels through `frameStore`, never through this.
    @Published var frameGeneration = 0

    /// Drawing, remote control and zoom for the live session. Its own type
    /// because none of it is WinUI — keeping it separate is what lets Linux CI
    /// typecheck the whole interactive layer, which is where the mistakes are.
    let interaction = WindowsViewerInteraction()

    /// Sharing state, mirrored from `SharingController` (off the main actor on purpose).
    @Published var sharing = WindowsShareSession.Status()

    /// The signed-in accounts, mirrored out of `profileStore` so the header
    /// re-renders on switch / add / relabel. Mirrored because the registry is
    /// deliberately not observable — it's portable Foundation, and the
    /// `ObservableObject` this app observes is SwiftCrossUI's.
    @Published private(set) var accounts: [HubAccount] = []
    @Published private(set) var activeAccountID = ""
    @Published private(set) var activeAccountName = ""

    /// Auto-resume: a non-empty tsnet state directory means a previous login
    /// can come up with no browser interaction, so the app goes straight for
    /// the peer list. A fresh install still lands on sign-in. If the stored
    /// login expired, `prepare` falls back to the interactive URL.
    init() {
        // Subscribed here, not on the first Share press: the approval gate is
        // decided BEFORE a share exists.
        shareSession.onStatus = { [weak self] status in
            Task { @MainActor in self?.applySharingStatus(status) }
        }
        // Same router as the card's own button, so the two decisions can't
        // drift. `answerPrompt` matches against the live rows, so a stale
        // press lands nowhere.
        notifications.onAnswer = { [weak self] _, identity, accept in
            self?.answerPrompt(identity, accept: accept)
        }
        // Not gated on `notifications.isAvailable`: a subscription with
        // nothing to deliver costs nothing, while a toast whose button
        // reaches nobody is worse than no button.
        NotificationActivation.observe { [weak self] press in
            self?.notifications.answer(activationID: press.id, action: press.action)
        }
        // The ask-to-share flow: listener lifecycle, inbox, answer sequencing
        // are the shared coordinator's; these closures are this host's part.
        askToShare.onRequestsChanged = { [weak self] requests in
            guard let self else { return }
            self.shareRequests = requests
            self.applyShareRequestNotifications()
        }
        askToShare.onPreApproveViewer = { [weak self] sourceKey in
            // Before the picker, so the invitee is known to the gate by the
            // time the share is up and their HELLO lands.
            self?.shareSession.preApproveViewer(ip: sourceKey)
        }
        askToShare.onStartShare = { [weak self] in self?.startSharing() }
        askToShare.onListenerError = { [weak self] (error: Error) in
            self?.detail = L("Not listening for share requests: \(error)")
        }
        // Both ends are WASAPI; handed over as closures since
        // `WindowsShareSession` carries no Windows-only code (so Linux CI can
        // typecheck it). Factory called at share start, device released at stop.
        shareSession.microphoneFactory = { makeWASAPIMicrophone() }
        shareSession.playRemoteVoice = { [weak self] pcm in
            self?.sharerVoiceOut.play(pcm)
        }
        shareSession.setRequireApproval(ViewerApprovalPreference.load())
        // Mute from OUTSIDE the window: during a share it's behind whatever
        // is shown, exactly when muting matters most. `toggleMic` vs
        // `toggleShareMic` stay separate; the controller picks which one the
        // single chord flips.
        muteHotkey = makeMuteHotkeyController(
            sharerMicAvailable: { [weak self] in self?.sharing.micAvailable ?? false },
            viewerMicAvailable: { [weak self] in self?.micAvailable ?? false },
            toggleSharerMic: { [weak self] in self?.toggleShareMic() },
            toggleViewerMic: { [weak self] in self?.toggleMic() })
        muteHotkey?.onUnavailabilityChange = { [weak self] reason in
            self?.hotkeyUnavailability = reason
        }
        muteHotkey?.start()
        syncAccounts()
        // Nothing redirects today — each link click is a fresh process — but
        // the subscription costs nothing installed.
        ProtocolActivation.observe { [weak self] link in
            guard let token = ShareLinkFormat.token(fromUserInput: link) else { return }
            self?.joinShare(token: token)
        }
        if Self.isUIPreview {
            seedUIPreview()
        } else if let launchToken = Self.launchJoinToken() {
            // Launched by a `tailscreen:` link click: straight into the
            // guest session, deliberately NO sign-in auto-resume (a click
            // while another instance runs starts a second process, and two
            // tsnet nodes on one state directory is the known pitfall).
            joinShare(token: launchToken)
        } else if hasPreviousLogin() {
            signIn()
        }
    }

    /// The share token this process was protocol-launched with, if any. A
    /// link with no plausible token falls through to an ordinary launch.
    private static func launchJoinToken() -> String? {
        guard let link = ProtocolActivation.launchJoinLink() else { return nil }
        return ShareLinkFormat.token(fromUserInput: link)
    }

    /// True when launched with `--ui-preview`: the hub renders a seeded,
    /// deterministic peer list so CI can screenshot the chrome. Same flag as
    /// the GTK app's preview mode.
    static let isUIPreview = CommandLine.arguments.contains("--ui-preview")

    /// The one preview state that is NOT signed in: the welcome pane a first
    /// launch opens on. Rides `--ui-preview` alongside — without it `init`
    /// falls through to `signIn()` on a machine with a previous login.
    static let isUIPreviewWelcome = CommandLine.arguments.contains("--ui-preview-welcome")

    /// The seeded preview state: tagged and untagged, online and offline, one
    /// peer sharing and one relayed, so a single screenshot exercises the
    /// sharing chip, route line, latency figure, and filter menu.
    private func seedUIPreview() {
        if Self.isUIPreviewWelcome {
            // Seeding stops here — everything below is a tailnet this state
            // doesn't have, and `loginURL` stays nil.
            phase = .signedOut
            status = L("Not signed in")
            return
        }
        phase = .ready
        status = hubSignedInSubtitle(tailnet: "example.com", account: "robert@example.com")
        activeAccountName = "robert@example.com"
        peers = [
            DiscoveredSharer(
                id: "1", hostname: "robert-macbook", tailscaleIP: "100.64.0.12",
                isOnline: true, route: .direct),
            DiscoveredSharer(
                id: "2", hostname: "studio-imac", tailscaleIP: "100.64.0.31",
                isOnline: true, tags: ["tag:studio"], route: .relay(region: "sto")),
            DiscoveredSharer(
                id: "3", hostname: "living-room-tv", tailscaleIP: "100.64.0.44",
                isOnline: false, tags: ["tag:media"])
        ]
        shareInfo = [
            "1": TailscreenMetadata(
                shareName: "robert's Screen", hostname: "robert-macbook",
                screenResolution: .init(width: 1920, height: 1080),
                isSharing: true, timestamp: Date(), videoCodec: .hevc)
        ]
        latencyMs = ["1": 12, "2": 38]
    }

    private func hasPreviousLogin() -> Bool {
        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory())) ?? []
        return !entries.isEmpty
    }

    private let transport = TsnetTransport()
    private let shareSession = WindowsShareSession()
    /// Holds ⌃⌥M system-wide while there is a microphone to mute.
    private var muteHotkey: PortableMuteHotkey?
    /// Why the system-wide mute chord could not be taken, mirrored from
    /// `PortableMuteHotkey` so the share card can say so.
    @Published private(set) var hotkeyUnavailability: GlobalHotkeyUnavailability?
    /// The mute chord to advertise on the viewer's mic control, or nil while
    /// the hotkey is not actually registered.
    var muteChordHint: String? { muteHotkey?.chordHint }
    /// Posts the sharer's notifications and routes their buttons back.
    /// During a share this window is behind the thing being shared, and
    /// raising it is itself visible to viewers. Built unconditionally — a
    /// machine that can't register is a normal state the type reports.
    private let notifications = SharerNotifications()
    /// Where viewers' voices come out while sharing. Its own sink, separate
    /// from the viewing session's, since this app can share while not
    /// watching. `ThreadedAudioSink` since a blocking WASAPI write must not
    /// run on the thread that publishes it; opens its device lazily.
    private let sharerVoiceOut = ThreadedAudioSink(wrapping: WASAPIAudioSink())

    /// Peers asking this machine to share — the coordinator's inbox, mirrored
    /// so the card re-renders.
    @Published private(set) var shareRequests: [PendingShareRequest] = []

    /// The whole ask-to-share flow — control listener, inbox, answer
    /// sequencing — written once in `TailscreenSharer` and shared with the
    /// GTK engine and macOS. What stays here: the `@Published` mirror, the
    /// toast reconcile, and where a listener failure is said.
    private let askToShare = SharerAskToShareCoordinator()

    /// Screens with an outstanding "please share" ask, by `DiscoveredSharer.id`.
    @Published private(set) var asking: Set<String> = []
    /// How the last ask to each screen ended, by screen id.
    @Published private(set) var askOutcome: [String: String] = [:]
    /// The multi-account registry, shared with the GTK viewer. A profile IS a
    /// tsnet state directory, so switching accounts is a node teardown and
    /// fresh bring-up under a different one. `.windowsLocalAppData()` seeds
    /// account #1 onto the single fixed directory this app used before it
    /// had accounts, so introducing the registry signs nobody out.
    private let profileStore = AccountProfileStore(layout: .windowsLocalAppData())
    /// The renderer hand-off, shared with `WinUIVideoView`. Portable, lock-
    /// guarded, the same type the GTK viewer polls from its draw callback.
    let frameStore = FrameStore()
    private var sessionTask: Task<Void, Never>?
    private var stopRequested = false

    var environmentLine: String {
        // The CONFIGURED value, not `.default` — a footer reporting a number
        // the next share won't use is worse than no footer.
        let quality = self.quality
        // One literal, not joined with `+`: the argument is a
        // `LocalizationKey`, whose catalog key is the whole sentence.
        return L(
            "\(BuildInfo.summary) · \(Self.architecture) · fps cap \(quality.fpsCap) · codec \(quality.codecPreference)"
        )
    }

    /// A spinner rides the header while node bring-up or a discovery sweep is
    /// genuinely in flight, never while merely idle.
    var showsSpinner: Bool { phase.isBringingUp || isSearching }

    /// Refresh is offered only from the settled signed-in state.
    var canRefresh: Bool { phase.isReady && watching == nil && !isSearching }

    /// The discovered peers, narrowed by the header filter, as hub rows.
    /// The sweep's answer rides along so the shared chrome derives the green
    /// "Sharing" chip — a peer we got no answer from gets no chip.
    var hubScreens: [HubScreen] {
        filteredPeers.map {
            HubScreen(
                id: $0.id, hostname: $0.hostname, tailscaleIP: $0.tailscaleIP,
                isOnline: $0.isOnline, metadata: shareInfo[$0.id],
                route: $0.route, latencyMs: latencyMs[$0.id], tags: $0.tags)
        }
    }

    /// `peers` narrowed by `filter` — hide-offline ∧ only-sharing ∧
    /// any-of-selected-tags. `PeerListFilter.narrow` is shared with the GTK
    /// and macOS hubs, so "no sweep answer ⇒ unknown, never not-sharing" is
    /// stated once.
    var filteredPeers: [DiscoveredSharer] {
        filter.narrow(peers, shareInfo: shareInfo)
    }

    /// The tags the filter menu offers: every tag across the RAW list, plus
    /// any currently selected — see `PeerListFilter.knownTags(in:)` for why
    /// the second half matters.
    var knownTags: [String] { filter.knownTags(in: peers) }

    /// How many discovered machines the filter is hiding right now — the
    /// footnote under the list, so rows never vanish unexplained.
    var hiddenByFilter: Int { peers.count - filteredPeers.count }

    func setFilter(_ new: PeerListFilter) {
        guard new != filter else { return }
        filter = new
        PeerListFilterStore.save(new)
    }

    /// No node, and none coming up: the sign-in pane's state. A share
    /// started from there is a link-only share — see `startSharing`.
    var isSignedOut: Bool { phase.isSignedOut }

    /// The welcome pane's tailnet card copy: the pitch by default, or
    /// whatever went wrong once something has.
    var welcomeTailnetMessage: String {
        // The PHASE first, then the legacy slot: `detail` is cleared by
        // anything that starts fresh, so reading it first could leave the
        // button saying "Try again" over the first-run pitch.
        if let reason = phase.failureReason { return reason }
        guard detail.isEmpty else { return detail }
        return L(
            "Every Tailscreen on your tailnet, listed by name — connect with one click, no link to pass around."
        )
    }

    /// The welcome pane's share-link card note: why the last link-only start
    /// did not happen. `shareDetail` covers the one failure the phase can't:
    /// a capture picker that threw before `beginSharing` was ever called.
    var shareNote: String? {
        sharing.phase.failureReason ?? shareDetail
    }

    /// What the welcome pane's share-link card offers. `canShare` folds in
    /// this app's two gates: a build without Windows.Graphics.Capture, and a
    /// viewing session already owning the window. `linkBusy` publishes
    /// before the phase leaves `starting`, so idle must exclude it or the
    /// button stays pressable through the relay handshake.
    var welcomeShareAction: WelcomePaneDecision.LinkShareAction {
        WelcomePaneDecision.linkShareAction(
            canShare: shareSession.isSupported && watching == nil,
            isIdle: sharing.phase.canStart && !sharing.linkBusy,
            isLinkOnlyShare: sharing.linkIsOnlyWayIn && sharing.linkToken != nil)
    }

    /// What the share card's headline says, per phase. Same wording (and
    /// catalog keys) as the GTK card.
    private var shareStatusLine: String {
        switch sharing.phase {
        case .idle: L("Not sharing")
        case .starting: L("Starting share…")
        case .sharing: L("Sharing \(sharing.target)")
        case .failed(let why): L("Share failed: \(why)")
        }
    }

    /// The sharing half of the hub, or nil on a build that cannot capture.
    /// Withheld rather than shown and then failing.
    var shareCard: ShareCard? {
        guard shareSession.isSupported else { return nil }
        return ShareCard(
            statusLine: shareStatusLine,
            isSharing: sharing.isSharing,
            isStarting: sharing.phase == .starting,
            canShare: watching == nil,
            // Signed out, the button says what it will actually do: there is
            // no tailnet to share to, so the share comes up over the guest
            // tunnel with its link as the only way in. Same wording as the
            // macOS welcome pane's link.
            startLabel: isSignedOut ? L("Share your screen via Link…") : L("Share this screen"),
            notes: shareNotes,
            // The roster: `notes` stays for statistics — a person is not a note.
            viewers: sharing.viewers.map { self.hubViewerRow($0) },
            // Control requests and viewer approvals share one prompt shape.
            // Approvals lead: a viewer at the gate is stuck on a Connecting
            // placard with nothing on screen, while a control request comes
            // from someone already watching.
            prompts: sharing.pendingViewers.map {
                HubPrompt(
                    id: $0.id, message: L("\($0.displayName) wants to watch"),
                    acceptLabel: L("Accept"), declineLabel: L("Deny"),
                    isGuest: $0.isGuest)
            }
                + sharing.controlRequests.map {
                    HubPrompt(
                        id: $0.id.uuidString,
                        message: L("\($0.displayName) wants to control this machine"))
                }
                // Somebody asking this machine to START sharing — last, since
                // the other two are about people already blocked on an answer.
                + shareRequests.map {
                    HubPrompt(
                        id: $0.id.uuidString,
                        message: L("\($0.fromHostname) wants you to share your screen"),
                        acceptLabel: L("Share"), declineLabel: L("Decline"))
                },
            // The approval gate governs TAILNET viewers, and a link-only
            // share has none — showing it would be a switch wired to nothing.
            settings: sharing.linkIsOnlyWayIn
                ? []
                : [
                    HubToggle(
                        label: L("Require approval for new viewers"),
                        // Said only while off: the one setting whose wrong
                        // value is invisible in normal use.
                        caption: sharing.requireApproval
                            ? nil
                            : L("Anyone on your tailnet who can reach this machine can watch."),
                        isOn: sharing.requireApproval,
                        set: { [weak self] in self?.setRequireApproval($0) })
                ],
            quality: HubQuality(
                settings: quality,
                isSharing: sharing.isSharing,
                onChange: { [weak self] in self?.setQuality($0) }),
            extraAction: sharing.controlGrantedTo.map { holder in
                HubAction(label: L("Take back control from \(holder)")) { [weak self] in
                    self?.revokeControl()
                }
            },
            // Absent unless a capture device was actually opened for this share.
            microphone: sharing.micAvailable
                ? HubMicrophone(isOn: sharing.micOn) { [weak self] in self?.toggleShareMic() }
                : nil,
            // The escape route renders in the caption BEFORE anything is
            // armed — once armed, this window is behind the shared surface.
            drawing: sharing.isSharing && sharing.drawingAvailable
                ? HubDrawing(
                    activeTool: sharing.activeDrawingTool,
                    inkColor: sharing.drawingInkColor,
                    note: sharing.drawingNote,
                    selectTool: { [weak self] tool in self?.selectDrawingTool(tool) },
                    undo: { [weak self] in self?.shareSession.undoDrawing() },
                    clear: { [weak self] in self?.shareSession.clearDrawing() })
                : nil,
            // Windows can always re-point a live share (see `WindowsShareSession.changeSource`).
            changeSource: sharing.isSharing
                ? HubAction(
                    label: L("Change source…"), perform: { [weak self] in self?.changeSource() })
                : nil,
            // What is actually on the wire, once a second. Only while sharing.
            preview: sharing.isSharing
                ? sharing.preview.map {
                    HubPreview(width: $0.width, height: $0.height, rgba: $0.rgba)
                }
                : nil,
            linkSharing: hubLinkSharing,
            onStart: { [weak self] in self?.startSharing() },
            onStop: { [weak self] in self?.stopSharing() },
            onAccept: { [weak self] id in self?.answerPrompt(id, accept: true) },
            onDecline: { [weak self] id in self?.answerPrompt(id, accept: false) })
    }

    /// One roster row. A method rather than an inline closure: the guest
    /// branch (badge on, remember-actions off, since those persist under a
    /// StableNodeID a guest never has) doubles the ternaries.
    private func hubViewerRow(_ viewer: WindowsShareSession.ConnectedViewer) -> HubViewerRow {
        let stableID = viewer.stableID
        if viewer.isGuest {
            return HubViewerRow(
                id: viewer.id,
                label: viewer.displayName,
                health: hubHealth(viewer.health),
                onKick: { [weak self] in self?.shareSession.disconnectViewer(viewer.id) },
                isGuest: true)
        }
        let remembered = shareSession.remembered(stableID: stableID)
        return HubViewerRow(
            id: viewer.id,
            label: viewer.displayName,
            health: hubHealth(viewer.health),
            remembered: remembered.map { $0 == .allow ? .allowed : .blocked } ?? .none,
            rememberIsDeferred: shareSession.isDeferred(rowID: viewer.id),
            onKick: { [weak self] in self?.shareSession.disconnectViewer(viewer.id) },
            onAlwaysAllow: { [weak self] in
                self?.shareSession.remember(
                    rowID: viewer.id, stableID: stableID,
                    displayName: viewer.displayName, policy: .allow)
            },
            onDenyAndBlock: { [weak self] in
                self?.shareSession.remember(
                    rowID: viewer.id, stableID: stableID,
                    displayName: viewer.displayName, policy: .deny)
            },
            onForget: { [weak self] in
                self?.shareSession.forget(rowID: viewer.id, stableID: stableID)
            })
    }

    /// The card's share-by-token half, live only while sharing.
    private var hubLinkSharing: HubLinkSharing? {
        guard sharing.isSharing else { return nil }
        let guests =
            sharing.viewers.filter(\.isGuest).count
            + sharing.pendingViewers.filter(\.isGuest).count
        // Hoisted with explicit types: closure literals needing @MainActor
        // @Sendable inference inside one init call (plus the conditional
        // optional) sink the Swift 6 typechecker outright on Linux.
        let toggle: @MainActor @Sendable (Bool) -> Void = { [weak self] on in
            self?.shareSession.setLinkSharing(on)
        }
        var newLink: (@MainActor @Sendable () -> Void)?
        if sharing.linkToken != nil {
            newLink = { [weak self] in self?.shareSession.rotateLink() }
        }
        return HubLinkSharing(
            token: sharing.linkToken,
            busy: sharing.linkBusy,
            guestCount: guests,
            // A link-only share has no off position short of Stop Sharing.
            isOnlyWayIn: sharing.linkIsOnlyWayIn,
            onToggle: toggle,
            onNewLink: newLink,
            onCopy: { copyToClipboard($0) })
    }

    /// Take a share-status snapshot, and reconcile the notifications with it.
    /// Order matters at the end of a share: a teardown snapshot must clear
    /// notification bookkeeping BEFORE the empty rosters are reconciled
    /// against it, or the sharer gets one "stopped watching" toast per viewer.
    @MainActor
    private func applySharingStatus(_ status: WindowsShareSession.Status) {
        let wasSharing = sharing.isSharing
        sharing = status
        guard status.isSharing else {
            if wasSharing { notifications.stop() }
            return
        }
        // Keyed by `ip:port`: a genuine rejoin IS news (mac keys the same way).
        notifications.applyViewers(
            status.viewers.map { NoticeCandidate(identity: $0.id, label: $0.displayName) })
        // The identity IS the id `approveViewer`/`denyViewer` take, so a button
        // press routes back with nothing to re-derive.
        notifications.applyAsk(
            kind: .viewerPending,
            candidates: status.pendingViewers.map {
                NoticeCandidate(identity: $0.id, label: $0.displayName)
            })
        // Likewise the connection UUID `grantControl` takes.
        notifications.applyAsk(
            kind: .controlRequested,
            candidates: status.controlRequests.map {
                NoticeCandidate(identity: $0.id.uuidString, label: $0.displayName)
            })
    }

    /// An ask to share, from the inbox rather than a share status — arrives
    /// while the machine is idle, so it's not urgent.
    @MainActor
    private func applyShareRequestNotifications() {
        notifications.applyAsk(
            kind: .requestToShare,
            candidates: shareRequests.map {
                NoticeCandidate(identity: $0.id.uuidString, label: $0.fromHostname)
            })
    }

    /// Route a card prompt back to whichever feature raised it. Matched
    /// against the live pending list, never the string's shape — a dispatch
    /// that leaned on `"ip:port"` vs UUID would be one format change away
    /// from granting control to someone who asked to watch.
    private func answerPrompt(_ id: String, accept: Bool) {
        if sharing.pendingViewers.contains(where: { $0.id == id }) {
            if accept {
                shareSession.approveViewer(id)
            } else {
                shareSession.denyViewer(id)
            }
            return
        }
        guard let requestID = UUID(uuidString: id) else { return }
        // Both UUID-shaped; each matched against its own live list, never by shape.
        if shareRequests.contains(where: { $0.id == requestID }) {
            answerShareRequest(id: requestID, accept: accept)
            return
        }
        guard sharing.controlRequests.contains(where: { $0.id == requestID }) else { return }
        if accept {
            grantControl(to: requestID)
        } else {
            declineControl(requestID)
        }
    }

    /// Change the encoder knobs and remember them. Deliberately does not
    /// touch a running share: the WGC encoder was built with the old values
    /// and this host has no re-push path.
    func setQuality(_ new: QualitySettings) {
        let normalized = new.normalized()
        guard normalized != quality else { return }
        quality = normalized
        QualitySettingsStore.save(normalized)
    }

    func setRequireApproval(_ enabled: Bool) {
        guard enabled != sharing.requireApproval else { return }
        ViewerApprovalPreference.save(enabled)
        shareSession.setRequireApproval(enabled)
    }

    /// The secondary lines under the share card's status.
    private var shareNotes: [String] {
        guard sharing.isSharing else { return [] }
        var notes: [String] = [
            // Spelled out rather than a number: "nobody watching" vs "N watching".
            sharing.viewerCount == 0
                ? L("No one is watching yet")
                : L("\(sharing.viewerCount) watching")
        ]
        // Which of the two optional features this share actually got —
        // otherwise invisible from both ends.
        if sharing.remoteControlAvailable {
            notes.append(L("Viewers can ask to control this machine"))
        }
        if sharing.annotationsAvailable {
            notes.append(L("Viewers' drawings appear on this screen"))
        }
        if !sharing.message.isEmpty { notes.append(sharing.message) }
        // Two distinct silences: no registration is the platform runtime,
        // switched off is this app's row in Windows' notification settings.
        if !notifications.isAvailable {
            notes.append(L("No desktop notifications on this system — approvals appear here only"))
        } else if !notifications.isVisible {
            notes.append(L("Notifications are off for Tailscreen — approvals appear here only"))
        }
        if sharing.micAvailable, let hotkey = muteHotkey,
            let reason = hotkeyUnavailability
        {
            notes.append(
                MuteHotkeyNote.text(chord: hotkey.chordDisplay, unavailability: reason))
        }
        // Where the frame time goes: capture, convert and encode are three
        // different problems with three different fixes.
        if let timings = sharing.timings {
            notes.append(timings.summary)
            if let slowest = timings.slowestStage {
                notes.append(L("slowest stage: \(slowest)"))
            }
        }
        return notes
    }

    func signIn() {
        guard phase.isSignedOut else { return }
        phase = .startingNode
        status = L("Starting Tailscale…")
        detail = ""
        loginURL = nil

        // Keep the node alive between viewing sessions — without this, the
        // peer list stays on screen with a node that's gone, and the next
        // Refresh fails with `badInterfaceHandle`.
        transport.retainsNodeAcrossSessions = true
        // Also goes in the log, not just the window footer, so a log alone
        // can rule out "this is yesterday's build."
        transport.buildIdentity = BuildInfo.summary

        Task {
            do {
                try await transport.prepare(
                    config: ViewerConfig(
                        // The dial target, used only by `run()`; discovery never reads it.
                        hostname: "",
                        statePath: stateDirectory(),
                        // Share-capable, so the node registers under
                        // `tailscreen-<machine>` rather than the viewer prefix
                        // discovery deliberately EXCLUDES (a viewer-only node
                        // is invisible in everyone's screen list by design).
                        nodeRole: .shareCapable(name: Self.machineName())
                    ),
                    onLoginURL: { [weak self] url in
                        // Fired from the IPN-bus watcher, off the main actor.
                        Task { @MainActor in
                            self?.loginURL = url.absoluteString
                            self?.status = L("Waiting for browser sign-in…")
                        }
                    }
                )
                loginURL = nil
                phase = .ready
                status = hubSignedInSubtitle(
                    tailnet: transport.tailnetName, account: transport.accountIdentity)
                labelActiveAccount()
                // Idempotent per node, so a later profile switch re-points it
                // rather than leaving it bound to a node that's going away.
                ensureControlListener()
                refreshPeers()
            } catch {
                phase = .failed("\(error)")
                loginURL = nil
                status = L("Could not start Tailscale")
                detail = "\(error)"
            }
        }
    }

    func refreshPeers() {
        // The preview's phase is .ready but its transport never started —
        // a refresh would replace the seeded list with a discovery error.
        guard !Self.isUIPreview else { return }
        guard phase.isReady, !isSearching else { return }
        isSearching = true
        detail = ""

        Task {
            do {
                let found = try await transport.discoverPeers()
                peers = found
                // Drop answers for peers no longer discovered or gone
                // offline, since the sweep below skips those and their
                // cached answer can only get staler.
                shareInfo = PeerShareStatusMap.pruned(
                    shareInfo, toPresent: Set(found.filter(\.isOnline).map(\.id)))
                isSearching = false
                await sweepShareStatus(found)
            } catch {
                detail = L("Discovery failed: \(error)")
                isSearching = false
            }
        }
    }

    /// Lazy per-peer share-status sweep — the input to the filter's "Only
    /// screens being shared" axis and the rows' sharing chips. Rides
    /// discovery rather than a timer; offline peers are skipped, correctly
    /// leaving them `.unknown`. A no-answer REMOVES the entry rather than
    /// leaving the last one in place, so status can never go stale-positive.
    private func sweepShareStatus(_ found: [DiscoveredSharer]) async {
        let online = found.filter(\.isOnline)
        guard !online.isEmpty else { return }
        // Child tasks capture the transport, not `self`, and are NOT
        // `@MainActor` — that would make the closure non-`Sendable`, which
        // `addTask`'s `sending` parameter rejects.
        let transport = self.transport
        await withTaskGroup(of: (String, PeerProbe).self) { group in
            for peer in online {
                group.addTask { (peer.id, await transport.probePeer(ip: peer.tailscaleIP)) }
            }
            for await (id, probe) in group {
                shareInfo = PeerShareStatusMap.recording(probe.metadata, for: id, in: shareInfo)
                // Only on a completed round trip, so a probe that never
                // answered can't record a "fast" latency.
                latencyMs[id] = probe.latencyMs
            }
        }
    }

    /// Dial the row the hub reports was tapped. The shared chrome hands back
    /// a row id rather than a `DiscoveredSharer`, since it doesn't import the
    /// transport that defines one.
    func connect(toID id: String) {
        guard let peer = peers.first(where: { $0.id == id }) else { return }
        connect(to: peer)
    }

    func connect(to peer: DiscoveredSharer) {
        guard phase.isReady else { return }
        startSession(
            config: ViewerConfig(
                // Dial by IP, not hostname: the transport documents that this
                // sidesteps the from == dest hostname mismatch the CLI host
                // path warns about.
                hostname: peer.tailscaleIP,
                statePath: stateDirectory()),
            target: ViewerSessionTarget(
                identifier: peer.id, host: peer.tailscaleIP,
                displayName: peer.displayName))
    }

    /// Join a share-by-token session (the hub's join card, signed in or not
    /// — the guest tunnel needs no tsnet node, so no `phase` guard). The
    /// token arrives already parsed by `HubJoinCard`.
    func joinShare(token: String) {
        startSession(
            config: ViewerConfig(guestToken: token),
            target: ViewerSessionTarget(
                host: "", displayName: L("Shared screen"), guestToken: token))
    }

    private func startSession(config: ViewerConfig, target: ViewerSessionTarget) {
        guard sessionTask == nil else { return }
        stopRequested = false
        let sessionID = viewerLifecycle.begin(target)
        status = L("Connecting to \(target.displayName)…")
        detail = ""
        viewerNotice = nil

        sessionTask = Task { [weak self] in
            guard let self else { return }
            // The portable sink, shared with the GTK viewer: parks the frame
            // and counts fps; this app supplies only what wakes ITS renderer.
            let sink = FrameStoreVideoSink(
                store: frameStore,
                // Announcing a frame re-arms this latch, so the next decode
                // takes the stall banner away by itself.
                onFirstFrame: { [weak self] in
                    Task { @MainActor in self?.viewerNotice = nil }
                },
                onFrame: { [weak self] in
                    Task { @MainActor in self?.frameGeneration &+= 1 }
                },
                onStats: { [weak self] width, height, fps, color in
                    // Fires roughly once a second off the session's thread.
                    Task { @MainActor in
                        self?.videoWidth = width
                        self?.videoHeight = height
                        self?.fps = fps
                        self?.videoColorLabel = color.shortLabel
                    }
                })
            sink.resetForNewSession()
            // Off-thread: a blocking WASAPI write inline would stall the WinUI
            // main thread and freeze video.
            let audio = ThreadedAudioSink(wrapping: WASAPIAudioSink())
            defer { audio.stop() }
            // Opened on the pump's own thread, so building this cannot fail
            // here — "no microphone" arrives as `onStopped`.
            let microphone = makeWASAPIMicrophone()
            // nil after `run` returns means the USER stopped it.
            final class EndedBox: @unchecked Sendable {
                var value: (reason: ViewerCloseReason, wasAdmitted: Bool)?
            }
            let ended = EndedBox()
            var failureMessage: String?
            // Held here so the decode-recovery ladder's reset rung can reach it.
            let decoder = FFmpegVideoDecoder()
            do {
                try await transport.run(
                    config: config,
                    decoder: decoder,
                    videoSink: sink,
                    audioSink: audio,
                    shouldClose: { [weak self] in self?.stopRequested ?? true },
                    backChannelHandlers: interaction.backChannelHandlers(),
                    microphone: microphone,
                    onVoiceReady: { [weak self] uplink in
                        guard let self, self.viewerLifecycle.isActive(sessionID) else { return }
                        self.attachVoice(uplink)
                    },
                    onBackChannelReady: { [weak self] channel in
                        Task { @MainActor in
                            guard let self, self.viewerLifecycle.isActive(sessionID) else { return }
                            self.interaction.beginSession(channel: channel)
                        }
                    },
                    onAdmitted: { [weak self] caps in
                        Task { @MainActor in
                            // A stale hop must not clobber the ended placard.
                            guard let self, self.sessionTask != nil else { return }
                            guard self.viewerLifecycle.markViewing(for: sessionID) else { return }
                            self.status = L("Watching \(target.displayName)")
                            // Drawing and Request Control appear only if the
                            // sharer advertised them — withheld bits mean a
                            // quieter UI, never a broken one.
                            self.interaction.setCaps(caps)
                        }
                    },
                    onAwaitingApproval: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.sessionTask != nil else { return }
                            guard self.viewerLifecycle.markAwaitingApproval(for: sessionID) else {
                                return
                            }
                            self.status = L("Waiting for \(target.displayName) to approve…")
                        }
                    },
                    onEnded: { reason, wasAdmitted in
                        ended.value = (reason, wasAdmitted)
                    },
                    // Decode-recovery ladder opt-in: at the wedged-decoder
                    // rung drop the lazy libavcodec context so the next AU (a
                    // fresh keyframe — the session asks for one) rebuilds it.
                    onDecoderResetNeeded: { decoder.reset() },
                    onDecodeFatal: { [weak self] in
                        guard let self, self.viewerLifecycle.isActive(sessionID) else { return }
                        // Terminal rung: say so over the frozen frame. Unlatch
                        // the sink first, so a later decode re-announces video
                        // and clears the banner by itself.
                        sink.resetForNewSession()
                        self.viewerNotice = L(
                            "Video has stalled — decoding keeps failing and automatic recovery hasn't helped."
                        )
                    }
                )
            } catch {
                detail = L("Session ended: \(error)")
                failureMessage = L("Session ended: \(error)")
            }
            sessionTask = nil
            detachVoice()
            viewerNotice = nil
            // Before the status line, so a stale grant or armed tool can never
            // outlive the session that produced it.
            interaction.endSession()
            // A guest session can run with no account at all, so "Signed in"
            // must not show over the sign-in pane.
            status =
                phase.isReady
                ? transport.accountIdentity.map { L("Signed in as \($0)") } ?? L("Signed in")
                : L("Not signed in")
            if let end = ended.value {
                // Keep `watching` so the window shows the ended placard with
                // the reason, never a silent snap back to the hub. The deny
                // byte's wording comes from the shared `resolve`, so this
                // app, GTK and macOS tell the same ending the same story.
                _ = viewerLifecycle.end(
                    ViewerSessionEndReason.resolve(
                        end.reason, wasAdmitted: end.wasAdmitted),
                    for: sessionID)
            } else if let failureMessage {
                // The session threw (dial/bring-up failure): same placard
                // shape, with the error as the sentence.
                _ = viewerLifecycle.fail(failureMessage, for: sessionID)
            } else {
                // The user stopped it — no explanation owed.
                _ = viewerLifecycle.dismiss(ifCurrent: sessionID)
            }
        }
    }

    /// The ended/failed placard's Reconnect: redial the retained peer. The
    /// row id resolves against the live `peers` list, so a peer that has
    /// genuinely left the tailnet makes this a quiet return to the hub rather
    /// than a dial into nothing.
    func reconnectSession() {
        guard sessionTask == nil else { return }
        guard let target = viewerLifecycle.target else { return }
        viewerLifecycle.dismiss()
        if let token = target.guestToken {
            joinShare(token: token)
            return
        }
        guard let id = target.identifier else { return }
        connect(toID: id)
    }

    /// The ended/failed placard's Back: dismiss the explanation, return to
    /// the hub.
    func dismissEndedSession() {
        guard sessionTask == nil else { return }
        viewerLifecycle.dismiss()
    }

    func disconnect() {
        stopRequested = true
    }

    // MARK: Microphone

    private func attachVoice(_ uplink: VoiceUplink) {
        // The transport hands it over muted; write what the latch says rather
        // than assuming the two agree.
        uplink.isMuted = voiceLatch.attach()
        voiceUplink = uplink
        publishViewerVoice()
        micFailure = nil
        uplink.onStopped = { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self else { return }
                self.voiceLatch.detach()
                self.publishViewerVoice()
                self.micFailure = L("Microphone unavailable")
            }
        }
    }

    private func detachVoice() {
        voiceUplink?.stop()
        voiceUplink = nil
        voiceLatch.detach()
        publishViewerVoice()
        micFailure = nil
    }

    private func publishViewerVoice() {
        micAvailable = voiceLatch.isAvailable
        micOn = voiceLatch.isOn
    }

    /// Flip the SHARER's microphone. Distinct from `toggleMic`, which is the
    /// viewer's: this app can share and watch at once, and one control flipping
    /// both would mute somebody in a call they are not in.
    func toggleShareMic() {
        shareSession.toggleMic()
    }

    /// Arm one of the sharer's own drawing tools, or disarm by re-picking it.
    /// A pass-through: everything that could go wrong lives in
    /// `SharerDrawingLatch` in the portable tier.
    func selectDrawingTool(_ tool: AnnotationTool) {
        shareSession.selectDrawingTool(tool)
    }

    func toggleMic() {
        guard case .setMuted(let muted) = voiceLatch.toggle() else { return }
        voiceUplink?.isMuted = muted
        publishViewerVoice()
    }

    // MARK: Accounts

    /// Reserved row id for the Sign out entry inside the account menu.
    /// `ViewerHeader` renders a flat list of accounts and hands back the id
    /// picked, so Sign out travels as a row with an id no UUID can collide with.
    static let signOutEntryID = "__tailscreen.signOut__"

    /// The account menu is hidden during a viewing session: the video owns the
    /// window then, and every entry in it would tear that session down.
    var showsAccountMenu: Bool { watching == nil }

    /// Menu button label — nil hides the whole menu (the header's convention:
    /// a quiet header reads as chrome, a header of dead controls does not).
    var accountMenuLabel: String? { showsAccountMenu ? activeAccountName : nil }

    /// The accounts, plus Sign out once there is a session to sign out of.
    var accountMenuEntries: [HubAccount] {
        guard phase.isReady else { return accounts }
        return accounts + [HubAccount(id: Self.signOutEntryID, name: L("Sign out"))]
    }

    func selectAccountMenuEntry(_ id: String) {
        if id == Self.signOutEntryID {
            signOut()
        } else {
            switchAccount(to: id)
        }
    }

    /// Switching closes the node, so every non-idle state blocks it, the same
    /// rule as the macOS app's `canSwitchProfile`.
    var canSwitchAccount: Bool {
        watching == nil && sessionTask == nil && sharing.phase.canStart && phase != .startingNode
    }

    func switchAccount(to id: String) {
        guard canSwitchAccount, profileStore.setActive(id) else { return }
        syncAccounts()
        restartUnderActiveAccount()
    }

    /// Add an account and switch to it. Its state directory is fresh and
    /// empty, so the bring-up below hands back an interactive login URL.
    func addAccount() {
        guard canSwitchAccount else { return }
        profileStore.addProfile()
        syncAccounts()
        restartUnderActiveAccount()
    }

    private func syncAccounts() {
        accounts = profileStore.profiles.map { HubAccount(id: $0.id, name: $0.name) }
        activeAccountID = profileStore.activeID
        activeAccountName = profileStore.active.name
    }

    /// Bring the node down and back up under the active account's state
    /// directory. Teardown first, `signIn()` only after: two accounts must
    /// never have a node up at once, since a tsnet node is one machine key.
    /// The previous account stays signed in on disk, so switching back
    /// resumes without a browser round trip.
    private func restartUnderActiveAccount() {
        phase = .signedOut
        status = L("Switching account…")
        detail = ""
        peers = []
        loginURL = nil
        Task { [weak self] in
            await self?.transport.teardown()
            self?.signIn()
        }
    }

    /// Relabel the active account with the resolved login once the tailnet can
    /// say who it is. "Account 2" is only useful until then.
    private func labelActiveAccount() {
        guard let identity = transport.accountIdentity,
            profileStore.rename(profileStore.activeID, to: identity)
        else { return }
        syncAccounts()
    }

    // MARK: Sharing

    /// Re-point the live share at something else, keeping the viewers. The
    /// same picker `startSharing` opens. Dismissing it changes nothing and
    /// says nothing — they declined a change, not the share.
    func changeSource() {
        guard sharing.isSharing else { return }
        let item: WGC.CaptureItem?
        do {
            item = try shareSession.pickTarget()
        } catch {
            detail = L("Could not open the capture picker: \(error)")
            return
        }
        guard let item else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await shareSession.changeSource(to: item)
            } catch {
                self.detail = L("Could not change the shared source: \(error)")
            }
        }
    }

    /// The picker runs inline on the main actor (modal system UI needing an
    /// owner window). Everything after it — tsnet bring-up, capture, encode —
    /// runs off the main actor inside `beginSharing`, why `WindowsShareSession`
    /// is not `@MainActor`.
    func startSharing() {
        // Signed out is a real way to share: the share comes up over the
        // guest tunnel with its link as the only way in. Mid-bring-up
        // (`.starting`) is still refused.
        let linkOnly = isSignedOut
        // `canStart` is idle-or-failed, so this also refuses a second click
        // during capture bring-up. `linkBusy` still covers the link-only
        // bootstrap, which publishes before the phase moves.
        guard phase.isReady || linkOnly, sharing.phase.canStart, !sharing.linkBusy else { return }
        detail = ""
        shareDetail = nil

        let item: WGC.CaptureItem?
        do {
            item = try shareSession.pickTarget()
        } catch {
            // Signed out, the button that opened this picker lives on the
            // share-link card, so its failure belongs there, not `detail`
            // (the welcome pane's tailnet card).
            if linkOnly {
                shareDetail = L("Could not open the capture picker: \(error)")
            } else {
                detail = L("Could not open the capture picker: \(error)")
            }
            return
        }
        // Dismissing the picker is a decision, not a failure. Say nothing.
        guard let item else { return }

        let quality = self.quality
        Task { [weak self] in
            guard let self else { return }
            do {
                try await shareSession.beginSharing(
                    item: item,
                    // Both ignored when a node is supplied; passed so the
                    // signature stays honest about a standalone bring-up.
                    hostname: Self.machineName(),
                    statePath: stateDirectory(),
                    quality: quality,
                    // THE app's node, not a new one — a second node means a
                    // second machine key and a share that never joins the
                    // tailnet. Nil when signed out (`linkOnly`).
                    existingNode: transport.sharedNode,
                    // The app's long-lived listener, so the share doesn't
                    // bind a second one to port 7447.
                    controlListener: askToShare.controlListener,
                    linkOnly: linkOnly
                )
            } catch {
                // Deliberately silent: the ENGINE owns this failure — it sets
                // `phase = .failed(reason)`, which `shareStatusLine` and
                // `shareNote` already render. A second copy here would show
                // the same failure twice in two different wordings.
                _ = error
            }
        }
    }

    func stopSharing() {
        Task { [weak self] in await self?.shareSession.stopSharing() }
    }

    // MARK: Asks to share

    /// Bring up (or re-point) the idle control listener. Idempotent per node
    /// and safe to call on every discovery — there's no single observable
    /// "the node is ready" moment here.
    func ensureControlListener() {
        guard let node = transport.sharedNode else { return }
        askToShare.ensureListener(node: node)
    }

    /// Answer an ask: reply on its own connection, and on accept invite the
    /// asker past the approval gate and open the capture picker.
    func answerShareRequest(id: UUID, accept: Bool) {
        askToShare.answer(id: id, accept: accept)
    }

    /// Ask a machine to start sharing. Nothing awaits this inline: the ask
    /// parks for up to two minutes on the far side.
    func askToShare(id: String) {
        guard let peer = peers.first(where: { $0.id == id }), !asking.contains(id) else { return }
        asking.insert(id)
        askOutcome[id] = nil
        let ip = peer.tailscaleIP
        Task { [weak self] in
            guard let self else { return }
            let outcome = await transport.requestToShare(ip: ip, from: Self.machineName())
            asking.remove(id)
            switch outcome {
            case .accepted:
                // Not a success message — they are still choosing what to
                // show. Their share turns up in this list on its own.
                askOutcome[id] = L("Accepted — they're choosing what to share")
            case .declined:
                askOutcome[id] = L("Declined")
            case .noAnswer:
                // One wording for away, closed, and too old to understand the
                // request: the asker cannot act on the difference.
                askOutcome[id] = L("No reply")
            }
        }
    }

    func grantControl(to requestID: UUID) {
        if !shareSession.grantControl(to: requestID) {
            detail = L("Remote control isn't available for this share.")
        }
    }

    func declineControl(_ requestID: UUID) {
        shareSession.declineControl(requestID)
    }

    func revokeControl() {
        shareSession.revokeControl()
    }

    func signOut() {
        guard phase.isReady else { return }
        stopRequested = true
        phase = .signedOut
        status = L("Not signed in")
        detail = ""
        peers = []
        viewerLifecycle.forget()
        Task { await transport.teardown() }
    }

    /// Open the login URL in the default browser. A failure here is not
    /// fatal: the URL stays on screen to be copied by hand.
    func openLoginURL() {
        guard let url = loginURL else { return }
        openBrowser(url)
    }

    /// Open the install page — the empty screen list's CTA, pointing at the
    /// same URL the macOS hub links.
    func openInstallPage() {
        openBrowser("https://tailscreen.dev/install/")
    }

    /// Open a URL in the default browser.
    ///
    /// Via `cmd /c start` rather than `ShellExecuteW`, to keep WinSDK out of
    /// this module: WinSDK carries `#define uuid_t UUID`, which makes every
    /// `Foundation.UUID` ambiguous — the same trap documented in
    /// `TailscreenProtocol`'s PortabilityShims.
    private func openBrowser(_ url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        // The empty argument is `start`'s title parameter. Without it, a URL in
        // quotes is taken AS the title and no browser opens.
        process.arguments = ["/c", "start", "", url]
        do {
            try process.run()
        } catch {
            detail = L("Could not open a browser — copy the URL above. (\(error))")
        }
    }

    /// Where the ACTIVE account's tsnet node keeps its state (machine key,
    /// netmap). Under `%LOCALAPPDATA%` since it's per-machine, per-user data
    /// that should not roam.
    private func stateDirectory() -> String {
        profileStore.active.statePath
    }

    /// This machine's name, as the tailnet sees it. `TsnetTransport` prefixes
    /// it with `serverHostnamePrefix`; sanitised by `TailscreenInstance.nodeLabel`, never empty.
    private static func machineName() -> String {
        let machine =
            ProcessInfo.processInfo.environment["COMPUTERNAME"]
            ?? ProcessInfo.processInfo.hostName
        return TailscreenInstance.nodeLabel(from: machine, fallback: "windows")
    }

    private static var architecture: String {
        #if arch(x86_64)
        return "x86_64"
        #elseif arch(arm64)
        return "arm64"
        #else
        return "unknown"
        #endif
    }
}
