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
import class TailscreenAudio.VoiceUplink
import struct TailscreenProtocol.AccountProfileLayout
import class TailscreenProtocol.AccountProfileStore
import enum TailscreenProtocol.AnnotationTool
import struct TailscreenProtocol.CaptureTimings
import struct TailscreenProtocol.ControlRequestInfo
import enum TailscreenProtocol.GlobalHotkeyUnavailability
import struct TailscreenProtocol.NoticeCandidate
import struct TailscreenProtocol.PeerListFilter
import enum TailscreenProtocol.PeerListFilterStore
import enum TailscreenProtocol.PeerPolicy
import enum TailscreenProtocol.PeerSharingState
import struct TailscreenProtocol.PendingShareRequest
import struct TailscreenProtocol.QualitySettings
import enum TailscreenProtocol.QualitySettingsStore
import enum TailscreenProtocol.ScreenShareMessage
import struct TailscreenProtocol.ShareRequestInbox
import enum TailscreenProtocol.TailscreenInstance
import struct TailscreenProtocol.TailscreenMetadata
import enum TailscreenProtocol.ViewerApprovalPreference
import class TailscreenSharerWGC.WindowsShareSession
import class TailscreenTransport.TailscreenControlListener
import class TailscreenVideoFFmpeg.FFmpegVideoDecoder
import class TailscreenViewer.FrameStore
import class TailscreenViewer.ThreadedAudioSink
import enum TailscreenViewer.ViewerCloseReason
import struct TailscreenViewerTsnet.DiscoveredSharer
import struct TailscreenViewerTsnet.PeerProbe
import class TailscreenViewerTsnet.TsnetTransport
import struct TailscreenViewerTsnet.ViewerConfig
import enum WGCCaptureKit.WGC

// NOT named main.swift on purpose: Swift rejects `@main` in a file with that
// name, because main.swift is itself top-level code.

/// Stage W5 of the Windows port: sign in, pick a peer, watch and hear it.
///
/// W2 proved the chrome renders; W3 proved libtailscale's Go↔native bridge
/// (patch 024) carries a real tsnet node; W4 added libavcodec decode through the
/// portable `VideoDecoding` seam and a CPU blit into a WinUI `WriteableBitmap`.
/// W5 adds WASAPI playback behind the portable `AudioSink` seam, and W6 adds
/// sharing: the system capture picker, then the portable
/// `TailscaleScreenShareServer` driven by Windows.Graphics.Capture.
///
/// Very little of this is Windows-specific: the decoder is the same
/// `FFmpegVideoDecoder` the Linux viewer runs, the colour conversion is
/// `I420Converter`, the PCM conversion is `MonoPCMConverter`, and the off-thread
/// audio wrapper is `ThreadedAudioSink` — all portable and all tested on Linux.
/// What is genuinely new per stage is one platform file: the WinUI surface, and
/// the WASAPI sink.
@main
struct TailscreenWindowsApp: App {
    @State var state = AppUIState()

    /// Process-wide setup that has to happen before a window exists — today,
    /// per-monitor DPI awareness. Without it Windows reports scaled coordinates
    /// for every display while Windows.Graphics.Capture reports capture items
    /// in real pixels, so on any display above 100 % scaling the sharer cannot
    /// work out which monitor it is capturing and silently loses both remote
    /// control and annotations.
    ///
    /// `App.main()` default-constructs the app and then runs it — which is
    /// exactly why this init must NOT call `WindowsShareSession.prepareProcess()`
    /// any more. It runs BEFORE swift-winui's `WindowsAppRuntimeInitializer`,
    /// whose init does `try CHECKED(SetProcessDpiAwareness(PROCESS_PER_MONITOR_
    /// DPI_AWARE))` — and that call returns E_ACCESSDENIED (0x80070005) when
    /// awareness was already set, which `CHECKED` turns into a fatalError at
    /// SwiftApplication.swift:64. Setting awareness here therefore killed the
    /// app at startup, deterministically, on every real desktop ("Failed to
    /// initialize WindowsAppRuntimeInitializer: 0x80070005 — Access is denied").
    ///
    /// swift-winui's own per-monitor (v1) awareness is sufficient for the
    /// capture-region math this call existed for: monitor enumeration returns
    /// physical pixels under v1 too. `prepareProcess()` remains available for
    /// non-WinUI hosts (tests, headless probes), where nothing else sets
    /// awareness.
    ///
    /// What DOES belong here is `ConsoleBridge`: the exe is a GUI-subsystem
    /// binary, so stdio must be attached to a parent console or redirected to
    /// the log file before anything prints — and it touches no DPI, COM, or
    /// WinUI state, so it cannot re-create the initializer collision above.
    init() {
        ConsoleBridge.attachOrRedirect()
    }

    // The view is deliberately split into many small, individually-typed
    // pieces rather than one nested expression. A first attempt inlined the
    // header's two optional arguments as `cond ? closure : nil` ternaries, and
    // the Windows compiler answered with "failed to produce diagnostic for
    // expression" against the whole `body` — the type checker giving up
    // without saying on what. Result builders plus optional closures are the
    // known way to get there, and the fix is not to find the clever line but
    // to stop asking one expression to be inferred all at once. The GTK app is
    // written the same way for the same reason.
    var body: some Scene {
        WindowGroup("Tailscreen") {
            VStack(spacing: 0) {
                // The hub header is suppressed while a session owns the window.
                // Its subtitle IS `status`, which during a session reads
                // "Watching <host>" — the same sentence the session bar below
                // already carries next to Stop, so the window opened with two
                // identical headers stacked on each other. Everything else the
                // header offers is already gated off mid-session (`canRefresh`
                // and `showsAccountMenu` both require `watching == nil`), so
                // what was left was a duplicate line and 44 points of video.
                // macOS names the host once, in the window, for the same reason.
                if state.watching == nil {
                    header
                    Divider()
                }
                content
                Divider()
                footer
            }
        }
        // Opens hub-narrow, like the macOS window and the GTK viewer: the hub
        // is one column, and a wide window turns every row into a ribbon with
        // the IP a foot from the hostname it belongs to.
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
    /// Refresh — there is nothing to filter while the node is still coming up
    /// or while a session owns the window.
    ///
    /// All three axes are live: this app has always kept offline machines in
    /// `peers`, `DiscoveredSharer` carries the netmap's ACL tags, and
    /// `sweepShareStatus` fills the sharing axis's input off every discovery.
    ///
    /// A computed property with an explicit type for the same reason
    /// `headerRefresh` is one: an optional built at the call site inside a
    /// result builder is how this file previously got "failed to produce
    /// diagnostic for expression" out of the Windows compiler.
    private var headerFilter: HubFilter? {
        guard state.phase == .ready, state.watching == nil else { return nil }
        let model = state
        return HubFilter(
            filter: model.filter,
            tags: model.knownTags,
            onChange: { model.setFilter($0) })
    }

    /// Refresh, offered only from the settled signed-in state.
    ///
    /// A computed property with an explicit type, not a ternary at the call
    /// site: the annotation is what lets the closure literal be checked on its
    /// own instead of against an optional inside a builder.
    ///
    /// Every action closure captures the MODEL, never `self` — these are
    /// `@MainActor @Sendable`, and a view struct is the wrong thing to be
    /// sending. `AppUIState` is a main-actor class and therefore Sendable.
    private var headerRefresh: (@MainActor @Sendable () -> Void)? {
        guard state.canRefresh else { return nil }
        let model = state
        return { model.refreshPeers() }
    }

    /// The account menu, which replaces what used to be a bare Sign out
    /// button. Sign out did not go away — it rides INSIDE the menu as a row
    /// (see `AppUIState.accountMenuEntries`), because the shared header takes
    /// a list of accounts and one selection callback and nothing else, and a
    /// second button beside the menu is the arrangement the menu exists to
    /// replace. The GTK viewer has had this menu since it grew profiles;
    /// this is the same one, over the same registry.
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
        } else if state.phase == .idle || state.phase == .failed {
            signIn
        } else {
            hub
        }
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
            // The annotation toolbar owns the stats toggle, which is why this
            // merge collapsed two of them into one. 4.3 landed a `Stats`
            // button in the top bar while this branch was open; keeping both
            // would have put two controls for one boolean on the same screen.
            // The toolbar wins because it is where the other view-level
            // controls already are — and the state stays `AppUIState.showStats`,
            // since that is what the fps counter feeds.
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
            // Drawn only once the first fps window has closed. Before that the
            // numbers are all zero, and "0×0 · 0 fps" over a stream that is
            // plainly running reads as a broken overlay rather than a warming
            // one.
            if state.showStats && state.fps > 0 {
                HStack {
                    StatsHUD(
                        width: state.videoWidth, height: state.videoHeight, fps: state.fps)
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
                // Talking and taking control, each on its own capability: a
                // sharer that cannot inject input must not also cost the viewer
                // its microphone.
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
        let message =
            state.detail.isEmpty
            ? L("Sign in to your tailnet to share this screen or watch someone else's.")
            : state.detail
        let label = state.phase == .failed ? L("Try again") : L("Sign in to Tailscale")
        return SignInPane(message: message, buttonLabel: label) { model.signIn() }
    }

    /// Signed in, or on the way there. `PickerContent` covers both: with
    /// `isPicking` false it shows the login card over a spinner, and with it
    /// true, the Screens list.
    private var hub: some View {
        let model = state
        return PickerContent(
            statusLine: state.status,
            isPicking: state.phase == .ready && !state.isSearching,
            screens: state.hubScreens,
            loginURL: state.loginURL,
            emptyMessage: L("No Tailscreen screens found on your tailnet."),
            // The empty list's way out: every machine that could appear there
            // is one without Tailscreen yet. Same link (and catalog key) as
            // the macOS hub.
            emptyAction: HubAction(
                label: L("Get Tailscreen for your other devices"),
                perform: { model.openInstallPage() }),
            hiddenByFilter: state.hiddenByFilter,
            askingIDs: state.asking,
            askNotes: state.askOutcome,
            onSelect: { id in model.connect(toID: id) },
            onAskToShare: { id in model.askToShare(id: id) },
            onOpenLogin: { model.openLoginURL() },
            shareCard: state.shareCard)
    }

    /// Build stamp, and whatever the last thing to go wrong was.
    ///
    /// The stamp leads because it is the one thing you need before any other
    /// number on screen can be trusted: "the new counter isn't there" and "this
    /// is yesterday's exe" are indistinguishable without it.
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
        return state.phase != .idle && state.phase != .failed
    }
}

/// The pre-sign-in state: what this app is for, and the one button that starts
/// it.
///
/// A card rather than a bare button because this is the first thing anyone sees
/// and "Tailscreen" over a lone control says nothing about what pressing it
/// does. On failure the same card carries the reason and says "Try again",
/// which keeps the error where the retry is.
struct SignInPane: View {
    let message: String
    let buttonLabel: String
    let onSignIn: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(L("Screens on your tailnet"))
                .font(.headline)
                .fontWeight(.semibold)
            Text(message)
                .font(.callout)
                .foregroundColor(HubStyle.secondaryText)
                .multilineTextAlignment(.center)
            Button(buttonLabel, action: onSignIn)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .center)
        .hubCard()
        .frame(maxWidth: HubStyle.contentMaxWidth)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// The window's state machine: sign-in → discovery → list.
///
/// `@MainActor` because `TsnetTransport` is, and because SwiftCrossUI's `App`
/// protocol is too — so a main-actor model can be held in `@State` directly
/// without hopping.
@MainActor
final class AppUIState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case ready
        case failed
    }

    @Published var phase: Phase = .idle
    @Published var status = L("Not signed in")
    @Published var detail = ""
    @Published var loginURL: String?
    /// The RAW discovery result. Stays unfiltered on purpose: the filter menu
    /// enumerates its tags, `connect(toID:)` resolves against it, and a filter
    /// that ate its own input could never be undone. `hubScreens` is the
    /// projection — the same split the macOS hub keeps between `availablePeers`
    /// and `filteredPeers`.
    @Published var peers: [DiscoveredSharer] = []
    /// Per-peer live share status from the metadata sweep, keyed by peer id.
    /// A missing entry is status-UNKNOWN, never "not sharing" — every failure
    /// mode of `fetchMetadata` (timeout, EOF, a legacy peer dropping the
    /// unknown byte) collapses to nil, and rendering that as "idle" would be a
    /// claim the app cannot support.
    @Published var shareInfo: [String: TailscreenMetadata] = [:]
    /// Round-trip time of the last successful probe, by peer id. Free: it
    /// times the sweep above rather than adding a second dial. Absent means no
    /// probe has completed — never "fast".
    @Published var latencyMs: [String: Int] = [:]

    /// The encoder knobs the next share will start with.
    ///
    /// Persisted through the portable `QualitySettingsStore`, the same store
    /// and key the macOS Settings pane writes, so the clamps and the
    /// decode-with-fallback are shared rather than reimplemented. Read at
    /// share start: `WGCCaptureEncoder` takes its settings at construction, so
    /// a mid-share change lands on the NEXT share and the card says so.
    @Published private(set) var quality: QualitySettings = QualitySettingsStore.load()

    /// Live video stats for the HUD, counted at the sink.
    ///
    /// Zero until the first window closes — about a second in — which is why
    /// the HUD is only drawn once there is something to draw. Showing
    /// "0×0 · 0 fps" over a stream that is plainly running would read as a
    /// broken overlay rather than a warming-up one.
    @Published private(set) var videoWidth = 0
    @Published private(set) var videoHeight = 0
    @Published private(set) var fps = 0
    /// Whether the stats HUD is shown. Session-scoped rather than persisted:
    /// it is a debugging glance, not a preference, and the GTK viewer treats
    /// it the same way.
    @Published var showStats = false

    /// Whether this machine opened a capture device for the live session — the
    /// capability the mic control's existence rides on. A box with no
    /// microphone shows no button rather than one that cannot unmute.
    @Published private(set) var micAvailable = false
    /// Whether the microphone is live. Starts off: joining a share must never
    /// put somebody on the air, matching the macOS viewer.
    @Published private(set) var micOn = false
    /// Set when the device goes away mid-session, so the control says so
    /// instead of quietly ceasing to work.
    @Published private(set) var micFailure: String?
    /// The live session's uplink, held for exactly as long as the session.
    /// Cleared in the session tail — a stale one would leave the microphone
    /// open, and Windows shows that in the tray for everyone to see.
    private var voiceUplink: VoiceUplink?
    /// Header filter state, persisted through the portable `PeerListFilterStore`
    /// the macOS hub uses — not a new persistence layer. On Windows that is
    /// swift-corelibs-foundation's `UserDefaults`; if the write does not stick
    /// the filter is per-session, which is a far better failure than refusing to
    /// filter at all. Unlike the GTK picker there is no legacy online-only list
    /// to preserve here — this app has always shown offline machines — so the
    /// portable `.default` (every axis off) is the right first-run state.
    @Published private(set) var filter = PeerListFilterStore.load()
    @Published var isSearching = false
    /// Non-nil while a viewing session OWNS THE WINDOW — from the dial until
    /// the session's UI is dismissed. That is deliberately longer than the
    /// session itself: after a non-user end the ended placard stays up (with
    /// the reason and Reconnect / Back) instead of the window silently
    /// snapping back to the hub, and everything gated on `watching == nil`
    /// (header, refresh, account switching) stays gated until the person
    /// dismisses it.
    @Published var watching: String?
    /// Where the session UI is — placard phases before admission, `.viewing`
    /// while the video renders, `.ended`/`.failed` afterwards. nil whenever
    /// `watching` is nil.
    @Published var sessionPhase: HubSessionPhase?
    /// The last dialed peer's row id, retained past the session's end so the
    /// ended placard's Reconnect can redial through `connect(toID:)`.
    private var lastPeerID: String?
    /// Bumped per decoded frame so SwiftCrossUI re-runs `updateWinUIElement`.
    /// The frame itself travels through `frameStore`, never through this.
    @Published var frameGeneration = 0

    /// Drawing, remote control and zoom for the live session. Its own type
    /// because none of it is WinUI — keeping it separate is what lets Linux CI
    /// typecheck the whole interactive layer, which is where the mistakes are.
    let interaction = WindowsViewerInteraction()

    /// Sharing state, mirrored from `SharingController` (which is off the main
    /// actor on purpose — see its type comment).
    @Published var sharing = WindowsShareSession.Status()

    /// The signed-in accounts, mirrored out of `profileStore` so the header
    /// re-renders on switch / add / relabel. Mirrored rather than read through,
    /// because the registry is deliberately not observable — it is portable
    /// Foundation, and the `ObservableObject` this app observes is
    /// SwiftCrossUI's.
    @Published private(set) var accounts: [HubAccount] = []
    @Published private(set) var activeAccountID = ""
    @Published private(set) var activeAccountName = ""

    /// Auto-resume: a non-empty tsnet state directory means a previous login
    /// whose node can come up with no browser interaction, so the app goes
    /// straight for the peer list instead of parking on a Sign in button the
    /// user would always press. A fresh install still lands on the sign-in
    /// card — auto-starting THERE would be a surprise browser prompt. If the
    /// stored login has expired, `prepare` falls back to the interactive URL
    /// and the UI shows the usual waiting-for-browser card, so the worst case
    /// of guessing wrong is exactly the screen the user would have reached by
    /// clicking. (The GTK app's picker mode already behaves this way.)
    init() {
        // Subscribe to share status here rather than on the first Share press.
        // The approval gate is decided BEFORE a share exists, and a switch
        // whose value only arrives once you press Share reads wrong at exactly
        // the moment you are deciding whether to press it.
        shareSession.onStatus = { [weak self] status in
            Task { @MainActor in self?.applySharingStatus(status) }
        }
        // A notification button answers exactly what the card's button does,
        // through the same router — so there is one implementation of each
        // decision and the two surfaces cannot drift. `answerPrompt` matches
        // the identity against the live rows, which also makes a press about
        // somebody who has since gone land nowhere instead of on whoever is
        // there now.
        notifications.onAnswer = { [weak self] _, identity, accept in
            self?.answerPrompt(identity, accept: accept)
        }
        // The press half. Subscribed once, for the life of the process, and
        // deliberately NOT gated on `notifications.isAvailable`: the two are
        // different runtime facts, and a subscription with nothing to deliver
        // costs nothing while the reverse — a toast whose button reaches
        // nobody — is the failure that makes buttons worse than no buttons.
        NotificationActivation.observe { [weak self] press in
            self?.notifications.answer(activationID: press.id, action: press.action)
        }
        // The sharer's own voice. Both ends are WASAPI and both live in this
        // target, so they are handed over as closures — `WindowsShareSession`
        // deliberately carries no Windows-only code, which is what lets Linux
        // CI typecheck it. The factory is called at share start and the device
        // released at share stop, so an idle app holds no microphone.
        shareSession.microphoneFactory = { makeWASAPIMicrophone() }
        shareSession.playRemoteVoice = { [weak self] pcm in
            self?.sharerVoiceOut.play(pcm)
        }
        // Push the persisted choice at the session. It already fails closed on
        // its own, but "closed" and "what the user asked for" are not the same
        // answer, and only one of them is this app's to give.
        shareSession.setRequireApproval(ViewerApprovalPreference.load())
        // Mute from OUTSIDE the window. The in-window buttons only exist while
        // the app is in front of you, and during a share it is behind whatever
        // you are showing — which is exactly when muting matters most. The two
        // microphones stay separate (`toggleMic` vs `toggleShareMic`);
        // `MuteHotkeyRouting` picks which one the single chord flips, and the
        // controller holds the chord only while there is one to flip.
        muteHotkey = MuteHotkeyController(
            sharerMicAvailable: { [weak self] in self?.sharing.micAvailable ?? false },
            viewerMicAvailable: { [weak self] in self?.micAvailable ?? false },
            toggleSharerMic: { [weak self] in self?.toggleShareMic() },
            toggleViewerMic: { [weak self] in self?.toggleMic() })
        // Mirror the chord's failure into a published field the share card
        // reads: the controller's own report goes to the console, which
        // reaches nobody mid-share, and an unregistered mute shortcut looks
        // exactly like one that works — until it is trusted.
        muteHotkey?.onUnavailabilityChange = { [weak self] reason in
            self?.hotkeyUnavailability = reason
        }
        muteHotkey?.start()
        syncAccounts()
        if Self.isUIPreview {
            seedUIPreview()
        } else if hasPreviousLogin() {
            signIn()
        }
    }

    /// True when launched with `--ui-preview`: the hub renders a seeded,
    /// deterministic peer list — no tsnet node, no networking — so CI can
    /// screenshot the chrome. Same flag, same fake tailnet as the GTK app's
    /// preview mode, so the platforms' screenshots read as one product.
    static let isUIPreview = CommandLine.arguments.contains("--ui-preview")

    /// The seeded preview state: tagged and untagged, online and offline,
    /// one peer sharing and one relayed — so a single screenshot exercises
    /// the sharing chip, the route line, the latency figure, and every axis
    /// of the filter menu. Verbatim data, deliberately not localized.
    private func seedUIPreview() {
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
    /// Holds ⌃⌥M system-wide while there is a microphone to mute. Built in
    /// `init` and kept for the process — it decides for itself when to take
    /// and release the chord.
    private var muteHotkey: MuteHotkeyController?
    /// Why the system-wide mute chord could not be taken, mirrored from
    /// `MuteHotkeyController` so the share card can say so. Nil while the
    /// chord is held, or before a microphone made holding it worthwhile.
    @Published private(set) var hotkeyUnavailability: GlobalHotkeyUnavailability?
    /// The mute chord to advertise on the viewer's mic control, or nil while
    /// the hotkey is not actually registered.
    var muteChordHint: String? { muteHotkey?.chordHint }
    /// Posts the sharer's notifications and routes their buttons back.
    ///
    /// The other half of the same problem the hotkey above solves: during a
    /// share this window is behind the thing being shared, and raising it is
    /// itself visible to the viewers. Built unconditionally — a machine that
    /// cannot register is a normal state the type reports rather than an error
    /// to avoid constructing.
    private let notifications = SharerNotifications()
    /// Where viewers' voices come out while sharing.
    ///
    /// Its own sink, separate from the viewing session's: this app can share
    /// while not watching, and sharing one would mean a viewing session's
    /// teardown silently taking the share's audio with it. `ThreadedAudioSink`
    /// for the usual reason — a blocking WASAPI write must not run on the
    /// thread that publishes it — and it opens its device lazily, so an app
    /// that never shares never touches the output endpoint.
    private let sharerVoiceOut = ThreadedAudioSink(wrapping: WASAPIAudioSink())

    /// Peers asking this machine to share, coalesced and bounded by the
    /// portable `ShareRequestInbox` — the same type the GTK app uses, so the
    /// two cannot disagree about the cap or the dedupe key.
    @Published private(set) var shareRequests: [PendingShareRequest] = []
    private var inbox = ShareRequestInbox()

    /// This app's OWN control listener, alive for as long as the node is.
    ///
    /// Not the one a share creates. `TailscaleScreenShareServer` builds a
    /// listener when none is supplied, but only for the share's lifetime — and
    /// a request to share arrives exactly when this machine is NOT sharing.
    /// Without a long-lived one the port answers nothing while idle, and every
    /// ask reads to the asker as "no answer", indistinguishable from a peer
    /// that is away.
    private var controlListener: TailscreenControlListener?
    /// The node the listener was started against, held only for identity.
    ///
    /// `AnyObject` rather than `TailscaleNode` on purpose: this file keeps
    /// TailscaleKit out of the app target (see `beginSharing`'s note about
    /// `kDefaultControlURL`), and identity comparison is the entire use — a
    /// profile switch brings a different node up, and the listener has to
    /// follow it rather than stay bound to one that is going away.
    private var listenerNode: AnyObject?

    /// Screens with an outstanding "please share" ask, by `DiscoveredSharer.id`.
    @Published private(set) var asking: Set<String> = []
    /// How the last ask to each screen ended, by screen id.
    @Published private(set) var askOutcome: [String: String] = [:]
    /// The multi-account registry, shared with the GTK viewer and unit-tested
    /// on Linux CI. A profile IS a tsnet state directory, so switching accounts
    /// is a node teardown and a fresh bring-up under a different one.
    ///
    /// `.windowsLocalAppData()` seeds account #1 onto
    /// `%LOCALAPPDATA%\Tailscreen\tailscale` — the single fixed directory this
    /// app used before it had accounts — so introducing the registry signs
    /// nobody out.
    private let profileStore = AccountProfileStore(layout: .windowsLocalAppData())
    /// The renderer hand-off, shared with `WinUIVideoView`. Portable, lock-
    /// guarded, and the same type the GTK viewer polls from its draw callback.
    let frameStore = FrameStore()
    private var sessionTask: Task<Void, Never>?
    private var stopRequested = false

    /// Architecture and a value read out of the portable protocol tier. W2 made
    /// this a button because proving the shared core was reachable from WinUI
    /// was the entire point of that stage; now that the same binary runs a tsnet
    /// node, it is a footer.
    var environmentLine: String {
        // The CONFIGURED value, not `.default` — a footer that reports a
        // number the next share will not use is worse than no footer.
        let quality = self.quality
        // The build stamp leads, because it is the one thing you need before
        // any other number on screen can be trusted: "the new counter isn't
        // there" and "this is yesterday's exe" are indistinguishable without
        // it.
        // One literal, not two joined with `+`: the argument is a
        // `LocalizationKey`, and concatenating two of those is neither defined
        // nor meaningful — the catalog key is the whole sentence.
        return L(
            "\(BuildInfo.summary) · \(Self.architecture) · fps cap \(quality.fpsCap) · codec \(quality.codecPreference)"
        )
    }

    /// A spinner rides the header while something is genuinely in flight —
    /// node bring-up or a discovery sweep. Not while merely idle: a spinner
    /// that never stops is worse than none, because it makes a settled state
    /// look broken.
    var showsSpinner: Bool { phase == .starting || isSearching }

    /// Refresh is offered only from the settled signed-in state.
    var canRefresh: Bool { phase == .ready && watching == nil && !isSearching }

    /// The discovered peers, narrowed by the header filter, as hub rows.
    ///
    /// The sweep's answer rides along so the shared chrome derives the green
    /// "Sharing" chip — and a peer we got no answer from gets no chip, because
    /// one that appeared when a machine was merely reachable would be a lie,
    /// and the chip is the one thing on the row people act on.
    var hubScreens: [HubScreen] {
        filteredPeers.map {
            HubScreen(
                id: $0.id, hostname: $0.hostname, tailscaleIP: $0.tailscaleIP,
                isOnline: $0.isOnline, metadata: shareInfo[$0.id],
                route: $0.route, latencyMs: latencyMs[$0.id], tags: $0.tags)
        }
    }

    /// `peers` narrowed by `filter` — hide-offline ∧ only-sharing ∧
    /// any-of-selected-tags, with the tri-state sharing input the sweep fills.
    var filteredPeers: [DiscoveredSharer] {
        peers.filter {
            filter.matches(
                isOnline: $0.isOnline, tags: $0.tags,
                sharing: PeerSharingState(fetched: shareInfo[$0.id]))
        }
    }

    /// Every ACL tag across the RAW list, for the filter menu's tag rows.
    /// Sorted so the menu does not reshuffle between discovery sweeps.
    var knownTags: [String] { Array(Set(peers.flatMap(\.tags))).sorted() }

    /// How many discovered machines the filter is hiding right now — the
    /// footnote under the list, so rows never vanish unexplained.
    var hiddenByFilter: Int { peers.count - filteredPeers.count }

    func setFilter(_ new: PeerListFilter) {
        guard new != filter else { return }
        filter = new
        PeerListFilterStore.save(new)
    }

    /// The sharing half of the hub, or nil on a build that cannot capture.
    ///
    /// Withheld rather than shown and then failing: a Windows build without
    /// Windows.Graphics.Capture cannot share, and finding that out by pressing
    /// a button is worse than not being offered one.
    var shareCard: ShareCard? {
        guard shareSession.isSupported else { return nil }
        return ShareCard(
            statusLine: sharing.isSharing
                ? L("Sharing \(sharing.target)")
                : L("Not sharing"),
            isSharing: sharing.isSharing,
            canShare: watching == nil,
            startLabel: L("Share this screen"),
            notes: shareNotes,
            // The roster: who is watching, and what can be done about them.
            // `notes` stays for statistics — a person is not a note.
            viewers: sharing.viewers.map { viewer in
                let stableID = viewer.stableID
                let remembered = shareSession.remembered(stableID: stableID)
                return HubViewerRow(
                    id: viewer.id,
                    label: viewer.displayName,
                    detail: viewer.health,
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
            },
            // Control requests and viewer approvals are the same interaction —
            // a sentence and two buttons — so they go through the one prompt
            // shape the shared card renders. This window is the only surface
            // this app has; a request not rendered here is one nobody can
            // answer, which is exactly what happened when the Windows sharer
            // advertised the capability and had nowhere to show the request.
            // Approvals lead: a viewer at the gate is stuck on a Connecting
            // placard with nothing on screen, while a control request comes
            // from someone already watching. The more blocked person goes
            // first.
            prompts: sharing.pendingViewers.map {
                HubPrompt(
                    id: $0.id, message: L("\($0.displayName) wants to watch"),
                    acceptLabel: L("Accept"), declineLabel: L("Deny"))
            }
                + sharing.controlRequests.map {
                    HubPrompt(
                        id: $0.id.uuidString,
                        message: L("\($0.displayName) wants to control this machine"))
                }
                // Somebody asking this machine to START sharing. Third source
                // into the one prompt list, and last because the other two are
                // about people who are already blocked on an answer: a viewer
                // sits on a Connecting placard with nothing on screen, and a
                // control request comes from someone already watching.
                + shareRequests.map {
                    HubPrompt(
                        id: $0.id.uuidString,
                        message: L("\($0.fromHostname) wants you to share your screen"),
                        acceptLabel: L("Share"), declineLabel: L("Decline"))
                },
            settings: [
                HubToggle(
                    label: L("Require approval for new viewers"),
                    // Said only while it is off, and said as a consequence
                    // rather than a warning glyph: this is the one setting on
                    // the card whose wrong value is invisible in normal use —
                    // the share looks identical, it just lets strangers in.
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
            // Absent unless a capture device was actually opened for this
            // share, so a machine with no microphone shows no control rather
            // than one that cannot unmute.
            microphone: sharing.micAvailable
                ? HubMicrophone(isOn: sharing.micOn) { [weak self] in self?.toggleShareMic() }
                : nil,
            // The sharer's own pen, offered only while a share is actually
            // running and only when this one resolved where its content is on
            // screen. The shared card renders the escape route in its caption
            // BEFORE anything is armed — which is the point, because once a
            // tool is armed this window is behind a surface that covers the
            // shared region and the caption is no longer readable.
            drawing: sharing.isSharing && sharing.drawingAvailable
                ? HubDrawing(
                    activeTool: sharing.activeDrawingTool,
                    inkColor: sharing.drawingInkColor,
                    note: sharing.drawingNote,
                    selectTool: { [weak self] tool in self?.selectDrawingTool(tool) },
                    undo: { [weak self] in self?.shareSession.undoDrawing() },
                    clear: { [weak self] in self?.shareSession.clearDrawing() })
                : nil,
            // Windows can always re-point a live share: its picker offers
            // every target, and losing the capture region on the way is
            // handled rather than prevented (see
            // `WindowsShareSession.changeSource`).
            changeSource: sharing.isSharing
                ? HubAction(
                    label: L("Change source…"), perform: { [weak self] in self?.changeSource() })
                : nil,
            // What is actually on the wire, once a second. Only while
            // sharing: the session clears it on teardown, and this second gate
            // means a preview that somehow outlived its capture still cannot
            // be shown next to a Start button.
            preview: sharing.isSharing
                ? sharing.preview.map {
                    HubPreview(width: $0.width, height: $0.height, rgba: $0.rgba)
                }
                : nil,
            onStart: { [weak self] in self?.startSharing() },
            onStop: { [weak self] in self?.stopSharing() },
            onAccept: { [weak self] id in self?.answerPrompt(id, accept: true) },
            onDecline: { [weak self] id in self?.answerPrompt(id, accept: false) })
    }

    /// Take a share-status snapshot, and reconcile the notifications with it.
    ///
    /// One function rather than a `didSet`, because the ORDER matters at the
    /// end of a share: stopping expels every viewer at once, so a teardown
    /// snapshot must clear the notification bookkeeping *before* the empty
    /// rosters are reconciled against it — otherwise the sharer gets one
    /// "stopped watching" toast per viewer at the exact moment they decided to
    /// stop. The GTK app spells the same rule out in `SharerModel.stop()`.
    @MainActor
    private func applySharingStatus(_ status: WindowsShareSession.Status) {
        let wasSharing = sharing.isSharing
        sharing = status
        guard status.isSharing else {
            if wasSharing { notifications.stop() }
            return
        }
        // Keyed by `ip:port`, deliberately: a genuine rejoin IS news, and the
        // mac viewer-roster path keys the same way for the same reason.
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

    /// An ask to share, from the inbox rather than from a share status — this
    /// one arrives while the machine is idle, which is exactly why it is not
    /// urgent.
    @MainActor
    private func applyShareRequestNotifications() {
        notifications.applyAsk(
            kind: .requestToShare,
            candidates: shareRequests.map {
                NoticeCandidate(identity: $0.id.uuidString, label: $0.fromHostname)
            })
    }

    /// Route a card prompt back to whichever feature raised it.
    ///
    /// Two sources share one prompt list and one pair of buttons, so the id
    /// has to say which. Matched against the live pending list rather than by
    /// looking at the string's shape: an `"ip:port"` and a UUID happen to be
    /// distinguishable today, and a dispatch that leans on that is one id
    /// format change away from granting remote control to someone who asked
    /// to watch.
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
        // Three sources now share one id space, so each is matched against its
        // own live list. Both UUID-shaped, which is exactly why the shape is
        // not consulted: an ask to share and a request for control are very
        // different things to say yes to.
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

    /// Flip the approval gate and remember it.
    ///
    /// Persisted through the shared `ViewerApprovalPreference` so this app and
    /// the GTK one cannot disagree about the default or about
    /// `TAILSCREEN_OPEN_DOOR=1`. The session applies it to a running share as
    /// well as the next one — turning it off drains whoever is already parked.
    /// Change the encoder knobs and remember them.
    ///
    /// Deliberately does not touch a running share: the WGC encoder was built
    /// with the old values and this host has no re-push path, so applying it
    /// live would be a control that appears to work.
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
            // Spelled out rather than shown as a number: "nobody is watching
            // yet" and "two people are watching" are the two facts a sharer
            // wants, and a bare count leaves the first ambiguous.
            sharing.viewerCount == 0
                ? L("No one is watching yet")
                : L("\(sharing.viewerCount) watching")
        ]
        // Which of the two optional features this share actually got. Their
        // absence is otherwise invisible from both ends — the viewer simply
        // stops offering them and the sharer sees a share that looks normal.
        if sharing.remoteControlAvailable {
            notes.append(L("Viewers can ask to control this machine"))
        }
        if sharing.annotationsAvailable {
            notes.append(L("Viewers' drawings appear on this screen"))
        }
        // Carries the reason they are unavailable, when they are. "Request
        // Control is missing" with no explanation is a support ticket; "2
        // displays share this resolution" is something the sharer can act on.
        if !sharing.message.isEmpty { notes.append(sharing.message) }
        // Said only while sharing, and only when it is true. The reason it is
        // said at all: the approval gate defaults on, so a sharer who assumes
        // they will be told about a waiting viewer and never is has no way to
        // discover the difference — the share looks completely normal from
        // here. Two distinct silences, because the fixes are different: no
        // registration is the platform (the unpackaged build's runtime),
        // switched off is this app's row in Windows' notification settings.
        if !notifications.isAvailable {
            notes.append(L("No desktop notifications on this system — approvals appear here only"))
        } else if !notifications.isVisible {
            notes.append(L("Notifications are off for Tailscreen — approvals appear here only"))
        }
        // The mute chord's failure, said beside the microphone it would have
        // muted: the press that discovers it is the one made believing this
        // side had gone quiet.
        if sharing.micAvailable, let hotkey = muteHotkey,
            let reason = hotkeyUnavailability {
            notes.append(
                MuteHotkeyNote.text(chord: hotkey.chordDisplay, unavailability: reason))
        }
        // Where the frame time goes. A viewer's stats overlay can prove the
        // network is fine and still leave "why is it 2 fps" open — capture,
        // convert and encode are three different problems with three different
        // fixes, and the idle count separates all of them from "nothing on
        // screen moved".
        if let timings = sharing.timings {
            notes.append(timings.summary)
            if let slowest = timings.slowestStage {
                notes.append(L("slowest stage: \(slowest)"))
            }
        }
        return notes
    }

    func signIn() {
        guard phase == .idle || phase == .failed else { return }
        phase = .starting
        status = L("Starting Tailscale…")
        detail = ""
        loginURL = nil

        // Keep the node alive between viewing sessions. `run`'s defer clears
        // `preparedNode` on EVERY exit path, so without this the peer list is
        // still on screen with a node that is gone, and the next Refresh fails
        // with `badInterfaceHandle` — which is exactly what happened after
        // watching a share once.
        transport.retainsNodeAcrossSessions = true
        // The stamp was already computed and already displayed — in the window
        // footer, which a stderr log never sees. Two rounds of blank-viewer
        // diagnosis were spent on logs from a binary that predated the fix under
        // test, so it goes in the log too.
        transport.buildIdentity = BuildInfo.summary

        Task {
            do {
                try await transport.prepare(
                    config: ViewerConfig(
                        // The dial target, used only by `run()` when a viewing
                        // session starts. Discovery never reads it, and this
                        // stage stops before dialing.
                        hostname: "",
                        statePath: stateDirectory(),
                        // Share-capable, so the node registers under
                        // `tailscreen-<machine>` rather than the viewer prefix
                        // that discovery deliberately EXCLUDES. A viewer-only
                        // node is invisible in everyone's screen list by
                        // design — correct while this app could only watch,
                        // and the reason a share from it never showed up on
                        // the Mac.
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
                // Start answering asks to share. The node is up and shared at
                // this point, and the call is idempotent per node — so a later
                // profile switch re-points it rather than leaving it bound to
                // a node that is going away.
                ensureControlListener()
                refreshPeers()
            } catch {
                phase = .failed
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
        guard phase == .ready, !isSearching else { return }
        isSearching = true
        detail = ""

        Task {
            do {
                let found = try await transport.discoverPeers()
                peers = found
                // Drop answers for machines that are no longer discovered, so a
                // stale entry can never keep a departed peer looking like it is
                // sharing.
                let ids = Set(found.map(\.id))
                shareInfo = shareInfo.filter { ids.contains($0.key) }
                isSearching = false
                await sweepShareStatus(found)
            } catch {
                detail = L("Discovery failed: \(error)")
                isSearching = false
            }
        }
    }

    /// Lazy per-peer share-status sweep — the input to the filter's "Only
    /// screens being shared" axis and to the rows' sharing chips.
    ///
    /// The same portable path the GTK picker uses (`TsnetTransport.fetchMetadata`
    /// → `TailscreenMetadataClient` over TCP/7447), and lazy for the same reason
    /// the macOS `refreshPeerShareStatus()` is: it is a real dial per peer, so
    /// it rides discovery rather than a timer. Offline peers are skipped —
    /// dialing a machine tsnet says is down buys nothing but a timeout — which
    /// correctly leaves them `.unknown`, and therefore hidden while the sharing
    /// axis is on. A no-answer REMOVES the entry rather than leaving the last
    /// one in place, so the status can never go stale-positive.
    private func sweepShareStatus(_ found: [DiscoveredSharer]) async {
        let online = found.filter(\.isOnline)
        guard !online.isEmpty else { return }
        // The child tasks capture the transport, not `self`, and are NOT
        // annotated `@MainActor` — the GTK sweep's exact shape. Annotating them
        // makes the closure main-actor-isolated and therefore non-`Sendable`,
        // which `addTask`'s `sending` parameter rejects; leaving them
        // nonisolated lets each simply `await` the main-actor `fetchMetadata`.
        let transport = self.transport
        await withTaskGroup(of: (String, PeerProbe).self) { group in
            for peer in online {
                group.addTask { (peer.id, await transport.probePeer(ip: peer.tailscaleIP)) }
            }
            for await (id, probe) in group {
                shareInfo[id] = probe.metadata
                // Only on a completed round trip: a latency recorded for a
                // probe that never answered would read as a fast link to a
                // machine that is gone.
                latencyMs[id] = probe.latencyMs
            }
        }
    }

    /// Dial a peer and run a viewing session until `disconnect()`.
    ///
    /// `run` owns the whole receive loop, so it is held in a Task and torn down
    /// by flipping `stopRequested`, which its `shouldClose` closure polls — the
    /// transport's own contract for ending a session cleanly rather than
    /// cancelling mid-datagram.
    /// Dial the row the hub reports was tapped.
    ///
    /// The shared chrome hands back a row id rather than a `DiscoveredSharer`,
    /// because it deliberately does not import the transport that defines one —
    /// a package that draws rectangles should not need a Go archive to compile.
    func connect(toID id: String) {
        guard let peer = peers.first(where: { $0.id == id }) else { return }
        connect(to: peer)
    }

    func connect(to peer: DiscoveredSharer) {
        guard phase == .ready, sessionTask == nil else { return }
        stopRequested = false
        watching = peer.hostname
        sessionPhase = .connecting
        lastPeerID = peer.id
        status = L("Connecting to \(peer.hostname)…")
        detail = ""

        sessionTask = Task { [weak self] in
            guard let self else { return }
            let sink = WindowsVideoSink(
                store: frameStore,
                onFrame: { [weak self] in
                    Task { @MainActor in self?.frameGeneration &+= 1 }
                },
                onStats: { [weak self] width, height, fps in
                    // Fires roughly once a second off the session's thread; the
                    // published values are main-actor state.
                    Task { @MainActor in
                        self?.videoWidth = width
                        self?.videoHeight = height
                        self?.fps = fps
                    }
                })
            sink.resetForNewSession()
            // Off-thread on purpose. The transport is serviced by the WinUI main
            // thread, so a blocking WASAPI write inline in `handleAudio` — up to
            // a device buffer, ~50×/s — would stall the UI loop and freeze
            // video. The wrapper is also what gives the sink its single-threaded
            // COM apartment, which is why it opens the device lazily.
            let audio = ThreadedAudioSink(wrapping: WASAPIAudioSink())
            defer { audio.stop() }
            // The capture device is opened on the pump's own thread (COM
            // apartment affinity, same as the sink), so building this cannot
            // fail here — "there is no microphone" arrives as `onStopped`.
            let microphone = makeWASAPIMicrophone()
            // The transport's end verdict, set from the @Sendable onEnded
            // callback (both it and the post-run read run on the main actor).
            // nil after `run` returns means the USER stopped it.
            final class EndedBox: @unchecked Sendable {
                var value: (reason: ViewerCloseReason, wasAdmitted: Bool)?
            }
            let ended = EndedBox()
            var failureMessage: String?
            do {
                try await transport.run(
                    config: ViewerConfig(
                        // Dial by IP, not hostname: the transport documents
                        // that this sidesteps the from == dest hostname
                        // mismatch the CLI host path warns about.
                        hostname: peer.tailscaleIP,
                        statePath: stateDirectory()
                    ),
                    decoder: FFmpegVideoDecoder(),
                    videoSink: sink,
                    audioSink: audio,
                    shouldClose: { [weak self] in self?.stopRequested ?? true },
                    backChannelHandlers: interaction.backChannelHandlers(),
                    microphone: microphone,
                    onVoiceReady: { [weak self] uplink in
                        self?.attachVoice(uplink)
                    },
                    onBackChannelReady: { [weak self] channel in
                        Task { @MainActor in self?.interaction.beginSession(channel: channel) }
                    },
                    onAdmitted: { [weak self] caps in
                        Task { @MainActor in
                            // The hop can land after the session tail on a
                            // session that ended immediately — a stale
                            // `.viewing` must not clobber the ended placard.
                            guard let self, self.sessionTask != nil else { return }
                            self.status = L("Watching \(peer.hostname)")
                            self.sessionPhase = .viewing
                            // Drawing and Request Control appear only if the
                            // sharer said it can serve them. Withheld bits mean
                            // a quieter UI, never a broken one.
                            self.interaction.setCaps(caps)
                        }
                    },
                    onAwaitingApproval: { [weak self] in
                        Task { @MainActor in
                            // Same stale-hop guard as `onAdmitted`.
                            guard let self, self.sessionTask != nil else { return }
                            self.status = L("Waiting for \(peer.hostname) to approve…")
                            self.sessionPhase = .awaitingApproval
                        }
                    },
                    onEnded: { reason, wasAdmitted in
                        ended.value = (reason, wasAdmitted)
                    }
                )
            } catch {
                detail = L("Session ended: \(error)")
                failureMessage = L("Session ended: \(error)")
            }
            sessionTask = nil
            detachVoice()
            // Before the status line, so a stale grant or armed tool can never
            // outlive the session that produced it.
            interaction.endSession()
            status = transport.accountIdentity.map { L("Signed in as \($0)") } ?? L("Signed in")
            if let end = ended.value {
                // Sharer stop / deny / kick / timeout / socket death: keep
                // `watching` so the window shows the ended placard with the
                // reason — never a silent snap back to the hub. The deny byte
                // is worded by admission context, the same split the macOS
                // viewer applies.
                sessionPhase = .ended(Self.endReason(end.reason, wasAdmitted: end.wasAdmitted))
            } else if let failureMessage {
                // The session threw (dial/bring-up failure): same placard
                // shape, with the error as the sentence.
                sessionPhase = .failed(failureMessage)
            } else {
                // The user stopped it — no explanation owed.
                watching = nil
                sessionPhase = nil
            }
        }
    }

    /// The transport's close reason as the placard's, with the one deny byte
    /// split by whether an SSRC had been assigned when it landed: declined at
    /// the approval gate vs disconnected (kicked) mid-watch.
    nonisolated static func endReason(
        _ reason: ViewerCloseReason, wasAdmitted: Bool
    ) -> HubSessionEndReason {
        switch reason {
        case .sharerStopped: return .sharerStopped
        case .timedOut: return .timedOut
        case .connectionLost: return .connectionLost
        case .deniedOrKicked: return wasAdmitted ? .disconnectedBySharer : .declined
        }
    }

    /// The ended/failed placard's Reconnect: redial the retained peer. The
    /// row id resolves against the live `peers` list, so a peer that has
    /// genuinely left the tailnet makes this a quiet return to the hub rather
    /// than a dial into nothing.
    func reconnectSession() {
        guard sessionTask == nil else { return }
        sessionPhase = nil
        watching = nil
        guard let id = lastPeerID else { return }
        connect(toID: id)
    }

    /// The ended/failed placard's Back: dismiss the explanation, return to
    /// the hub.
    func dismissEndedSession() {
        guard sessionTask == nil else { return }
        sessionPhase = nil
        watching = nil
    }

    func disconnect() {
        stopRequested = true
    }

    // MARK: Microphone

    private func attachVoice(_ uplink: VoiceUplink) {
        // The transport hands it over muted; mirror rather than assume.
        uplink.isMuted = true
        voiceUplink = uplink
        micAvailable = true
        micOn = false
        micFailure = nil
        uplink.onStopped = { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                // Both flags move together: a live indicator over a device that
                // is recording nothing is the one wrong answer a mute control
                // can give.
                self?.micAvailable = false
                self?.micOn = false
                self?.micFailure = L("Microphone unavailable")
            }
        }
    }

    private func detachVoice() {
        voiceUplink?.stop()
        voiceUplink = nil
        micAvailable = false
        micOn = false
        micFailure = nil
    }

    /// Flip the SHARER's microphone. Distinct from `toggleMic`, which is the
    /// viewer's: this app can share and watch at once, and one control flipping
    /// both would mute somebody in a call they are not in.
    func toggleShareMic() {
        shareSession.toggleMic()
    }

    /// Arm one of the sharer's own drawing tools, or disarm by re-picking it.
    ///
    /// A pass-through, and it stays one: everything that could go wrong here —
    /// the toggle, the refusal, the guarantee that a refused arm never leaves a
    /// window up — lives in `SharerDrawingLatch` in the portable tier, where
    /// Linux CI tests it. The status comes back through the session's normal
    /// publish, so a refusal renders as an unarmed toolbar plus a sentence
    /// rather than a tool that looks selected and does nothing.
    func selectDrawingTool(_ tool: AnnotationTool) {
        shareSession.selectDrawingTool(tool)
    }

    func toggleMic() {
        guard let voiceUplink else { return }
        let nowOn = voiceUplink.isMuted
        voiceUplink.isMuted = !nowOn
        micOn = nowOn
    }

    // MARK: Accounts

    /// Reserved row id for the Sign out entry inside the account menu.
    ///
    /// `ViewerHeader` renders a flat list of accounts and hands back the id
    /// that was picked, which is all the menu it has. Sign out travels as a row
    /// with an id no UUID can collide with, rather than as a second header
    /// control — the bare Sign out button beside the menu is exactly what the
    /// menu replaces.
    static let signOutEntryID = "__tailscreen.signOut__"

    /// The account menu is hidden during a viewing session: the video owns the
    /// window then, and every entry in it would tear that session down.
    var showsAccountMenu: Bool { watching == nil }

    /// Menu button label — nil hides the whole menu (the header's convention:
    /// a quiet header reads as chrome, a header of dead controls does not).
    var accountMenuLabel: String? { showsAccountMenu ? activeAccountName : nil }

    /// The accounts, plus Sign out once there is a session to sign out of.
    var accountMenuEntries: [HubAccount] {
        guard phase == .ready else { return accounts }
        return accounts + [HubAccount(id: Self.signOutEntryID, name: L("Sign out"))]
    }

    func selectAccountMenuEntry(_ id: String) {
        if id == Self.signOutEntryID {
            signOut()
        } else {
            switchAccount(to: id)
        }
    }

    /// Switching closes the node, so every non-idle state blocks it — the same
    /// rule as the macOS app's `canSwitchProfile`. A share still starting or a
    /// session still connecting would be torn out from under itself.
    var canSwitchAccount: Bool {
        watching == nil && sessionTask == nil && !sharing.isSharing && phase != .starting
    }

    func switchAccount(to id: String) {
        guard canSwitchAccount, profileStore.setActive(id) else { return }
        syncAccounts()
        restartUnderActiveAccount()
    }

    /// Add an account and switch to it. Its state directory is fresh and empty,
    /// which is precisely what makes the bring-up below hand back an
    /// interactive login URL instead of resuming.
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
    /// directory. Teardown first, and `signIn()` only after it returns: the two
    /// accounts must never have a node up at the same time, since a tsnet node
    /// is one machine key and one identity.
    ///
    /// The previous account stays signed in *on disk* — its state directory is
    /// untouched — so switching back resumes without a browser round trip.
    private func restartUnderActiveAccount() {
        phase = .idle
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

    /// Pick a target, then start sharing it.
    ///
    /// The picker runs inline on the main actor because it is modal system UI
    /// that needs an owner window and a message pump. Everything after it —
    /// tsnet bring-up, capture, encode — runs off the main actor inside
    /// `beginSharing`, which is the whole reason `WindowsShareSession` is not
    /// `@MainActor`: the same shape of mistake froze sign-in earlier in this
    /// port, and a share brings up a node exactly the same way.
    /// Re-point the live share at something else, keeping the viewers.
    ///
    /// The same picker `startSharing` opens, so the person chooses from
    /// everything Windows offers rather than a subset this app decided on.
    /// Dismissing it changes nothing and says nothing — they declined a
    /// change, not the share.
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

    func startSharing() {
        guard phase == .ready, !sharing.isSharing else { return }
        detail = ""

        let item: WGC.CaptureItem?
        do {
            item = try shareSession.pickTarget()
        } catch {
            detail = L("Could not open the capture picker: \(error)")
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
                    // Both are ignored when a node is supplied; passed so the
                    // signature stays honest about what a standalone bring-up
                    // would have used.
                    hostname: Self.machineName(),
                    statePath: stateDirectory(),
                    quality: quality,
                    // THE app's node, not a new one. A second node means a
                    // second machine key, a second browser login nobody is
                    // prompted for, and a share that waits at that login
                    // forever without ever joining the tailnet.
                    existingNode: transport.sharedNode,
                    // The app's long-lived listener, so the share does not bind
                    // a second one to port 7447 and `onRequestToShare` keeps
                    // pointing at this model.
                    controlListener: controlListener
                )
            } catch {
                self.detail = L("Could not start sharing: \(error)")
            }
        }
    }

    func stopSharing() {
        Task { [weak self] in await self?.shareSession.stopSharing() }
    }

    // MARK: Asks to share

    /// Bring up (or re-point) the idle control listener.
    ///
    /// Idempotent per node, and safe to call on every discovery — which is how
    /// it is called, because there is no single observable "the node is ready"
    /// moment here. A listener already bound to this node is left alone.
    func ensureControlListener() {
        guard let node = transport.sharedNode else { return }
        if controlListener != nil, listenerNode === node { return }
        if let previous = controlListener { Task { await previous.stop() } }

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
        Task { [weak self] in
            do {
                try await listener.start(node: node)
            } catch {
                // Surfaced rather than swallowed: sharing still works and this
                // machine simply never hears an ask, which from the other end
                // looks exactly like nobody being home.
                await MainActor.run { [weak self] in
                    self?.detail = L("Not listening for share requests: \(error)")
                }
            }
        }
    }

    /// Matches the requester's own wait (`TailscreenRequestToShareClient`'s
    /// 120 s default). A row that outlives it is a button that does nothing.
    private static let shareRequestTTLNs: UInt64 = 120 * 1_000_000_000

    private func noteShareRequest(from hostname: String, sourceAddr: String?, connectionID: UUID) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        // Expire first, so a row the asker has already given up on cannot hold
        // a slot against a live one.
        _ = inbox.pruneExpired(nowNs: nowNs, ttlNs: Self.shareRequestTTLNs)
        guard
            inbox.record(
                fromHostname: hostname, sourceAddr: sourceAddr,
                connectionID: connectionID, nowNs: nowNs)
        else { return }
        shareRequests = inbox.requests
        applyShareRequestNotifications()
    }

    /// Answer an ask: reply on its own connection, and on accept invite the
    /// asker past the approval gate and open the capture picker.
    func answerShareRequest(id: UUID, accept: Bool) {
        guard let request = inbox.remove(id: id) else { return }
        shareRequests = inbox.requests
        // Reconciled after the row is gone, which is what takes the toast back
        // when the ask was answered from the window instead.
        applyShareRequestNotifications()

        if let connectionID = request.connectionID, let listener = controlListener {
            Task {
                // Best effort. The asker may already have given up and closed,
                // in which case their side has settled on `.noAnswer` and
                // there is nothing here worth reporting.
                await listener.send(.shareResponse(accepted: accept), to: connectionID)
            }
        }
        guard accept else { return }
        // Before the picker, so the invitee is known to the gate by the time
        // the share is up and their HELLO lands.
        shareSession.preApproveViewer(ip: request.sourceKey)
        startSharing()
    }

    /// Ask a machine to start sharing.
    ///
    /// Nothing awaits this inline: the ask parks for up to two minutes on the
    /// far side, and freezing the window for that would also stop somebody
    /// viewing a different screen that came free meanwhile.
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
        guard phase == .ready else { return }
        stopRequested = true
        phase = .idle
        status = L("Not signed in")
        detail = ""
        peers = []
        watching = nil
        sessionPhase = nil
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
    /// netmap) — which is what a profile is.
    ///
    /// Under `%LOCALAPPDATA%` because it is per-machine, per-user data that
    /// should not roam: the machine key identifies *this* device to the tailnet,
    /// and a roaming profile would carry it to another one. Account #1 is
    /// seeded onto the exact directory this method used to return outright, so
    /// an existing install keeps its login.
    private func stateDirectory() -> String {
        profileStore.active.statePath
    }

    /// This machine's name, as the tailnet sees it.
    ///
    /// `TsnetTransport` prefixes it with `serverHostnamePrefix`, so what is
    /// returned here is the bare name — sanitised by the shared
    /// `TailscreenInstance.nodeLabel`, and never empty. The old inline filter
    /// neither trimmed hyphens nor capped length, so a `COMPUTERNAME` of
    /// `-lab-box` registered a DNS-illegal label.
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
