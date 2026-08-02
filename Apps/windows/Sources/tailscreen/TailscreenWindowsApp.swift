import DefaultBackend
import Foundation
import SwiftCrossUI
// The hub's look, shared with the GTK viewer — header, screen rows with their
// detail panes, cards, placards, tokens. Safe to import wholesale: it does not
// re-export TailscreenProtocol, so the `Published` / `ObservableObject`
// collision the targeted imports below exist to dodge does not arrive with it.
import TailscreenHubUI

// Targeted imports: pulling all of TailscreenProtocol collides with SwiftCrossUI's
// own `Published` / `ObservableObject` shims, the same collision the GTK app
// hits and solves the same way.
import struct TailscreenProtocol.AccountProfileLayout
import class TailscreenProtocol.AccountProfileStore
import struct TailscreenProtocol.CaptureTimings
import struct TailscreenProtocol.ControlRequestInfo
import enum TailscreenProtocol.PeerPolicy
import struct TailscreenProtocol.PeerListFilter
import enum TailscreenProtocol.PeerListFilterStore
import enum TailscreenProtocol.PeerSharingState
import struct TailscreenProtocol.QualitySettings
import struct TailscreenProtocol.TailscreenMetadata
import enum TailscreenProtocol.ViewerApprovalPreference
import class TailscreenSharerWGC.WindowsShareSession
import class TailscreenVideoFFmpeg.FFmpegVideoDecoder
import class TailscreenViewer.FrameStore
import class TailscreenViewer.ThreadedAudioSink
import struct TailscreenViewerTsnet.DiscoveredSharer
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
                header
                Divider()
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
            watching(host: host)
        } else if state.phase == .idle || state.phase == .failed {
            signIn
        } else {
            hub
        }
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
                Text("Watching \(host)")
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                Spacer()
                if interaction.isZoomed {
                    Button("Reset Zoom") { interaction.resetZoom() }
                }
                Button("Stop") { model.disconnect() }
            }
            .padding(.horizontal, 16)
            .frame(height: Double(HubStyle.toolbarHeight))
            .frame(maxWidth: .infinity)
            .background(HubStyle.barFill)
            if interaction.annotationsAvailable {
                AnnotationToolbar(
                    activeTool: interaction.activeTool,
                    inkColor: interaction.annotations.color,
                    statsShown: interaction.showStats,
                    onSelectTool: { interaction.selectTool($0) },
                    onUndo: { interaction.undoAnnotation() },
                    onClear: { interaction.clearAnnotations() },
                    onToggleStats: { interaction.toggleStats() })
            }
            WinUIVideoView(
                store: state.frameStore,
                generation: state.frameGeneration,
                interaction: interaction)
            if interaction.remoteControlAvailable {
                RemoteControlBar(
                    buttonLabel: interaction.controlButtonLabel,
                    declinedReason: interaction.controlDeclinedReason,
                    onToggle: { interaction.toggleControl() })
            }
        }
    }

    private var signIn: some View {
        let model = state
        let message =
            state.detail.isEmpty
            ? "Sign in to your tailnet to share this screen or watch someone else's."
            : state.detail
        let label = state.phase == .failed ? "Try again" : "Sign in to Tailscale"
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
            emptyMessage: "No Tailscreen screens found on your tailnet.",
            hiddenByFilter: state.hiddenByFilter,
            onSelect: { id in model.connect(toID: id) },
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
            Text("Screens on your tailnet")
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
    @Published var status = "Not signed in"
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
    /// Header filter state, persisted through the portable `PeerListFilterStore`
    /// the macOS hub uses — not a new persistence layer. On Windows that is
    /// swift-corelibs-foundation's `UserDefaults`; if the write does not stick
    /// the filter is per-session, which is a far better failure than refusing to
    /// filter at all. Unlike the GTK picker there is no legacy online-only list
    /// to preserve here — this app has always shown offline machines — so the
    /// portable `.default` (every axis off) is the right first-run state.
    @Published private(set) var filter = PeerListFilterStore.load()
    @Published var isSearching = false
    /// Non-nil while a viewing session is running — the hostname on screen.
    @Published var watching: String?
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
            Task { @MainActor in self?.sharing = status }
        }
        // Push the persisted choice at the session. It already fails closed on
        // its own, but "closed" and "what the user asked for" are not the same
        // answer, and only one of them is this app's to give.
        shareSession.setRequireApproval(ViewerApprovalPreference.load())
        syncAccounts()
        if hasPreviousLogin() {
            signIn()
        }
    }

    private func hasPreviousLogin() -> Bool {
        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory())) ?? []
        return !entries.isEmpty
    }

    private let transport = TsnetTransport()
    private let shareSession = WindowsShareSession()
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
        let quality = QualitySettings.default
        // The build stamp leads, because it is the one thing you need before
        // any other number on screen can be trusted: "the new counter isn't
        // there" and "this is yesterday's exe" are indistinguishable without
        // it.
        return "\(BuildInfo.summary) · \(Self.architecture) · fps cap \(quality.fpsCap) "
            + "· codec \(quality.codecPreference)"
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
                isOnline: $0.isOnline, metadata: shareInfo[$0.id])
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
                ? "Sharing \(sharing.target)"
                : "Not sharing",
            isSharing: sharing.isSharing,
            canShare: watching == nil,
            startLabel: "Share this screen",
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
                    id: $0.id, message: "\($0.displayName) wants to watch",
                    acceptLabel: "Accept", declineLabel: "Deny")
            }
                + sharing.controlRequests.map {
                    HubPrompt(
                        id: $0.id.uuidString,
                        message: "\($0.displayName) wants to control this machine")
                },
            settings: [
                HubToggle(
                    label: "Require approval for new viewers",
                    // Said only while it is off, and said as a consequence
                    // rather than a warning glyph: this is the one setting on
                    // the card whose wrong value is invisible in normal use —
                    // the share looks identical, it just lets strangers in.
                    caption: sharing.requireApproval
                        ? nil
                        : "Anyone on your tailnet who can reach this machine can watch.",
                    isOn: sharing.requireApproval,
                    set: { [weak self] in self?.setRequireApproval($0) })
            ],
            extraAction: sharing.controlGrantedTo.map { holder in
                HubAction(label: "Take back control from \(holder)") { [weak self] in
                    self?.revokeControl()
                }
            },
            onStart: { [weak self] in self?.startSharing() },
            onStop: { [weak self] in self?.stopSharing() },
            onAccept: { [weak self] id in self?.answerPrompt(id, accept: true) },
            onDecline: { [weak self] id in self?.answerPrompt(id, accept: false) })
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
                ? "No one is watching yet"
                : "\(sharing.viewerCount) watching"
        ]
        // Which of the two optional features this share actually got. Their
        // absence is otherwise invisible from both ends — the viewer simply
        // stops offering them and the sharer sees a share that looks normal.
        if sharing.remoteControlAvailable {
            notes.append("Viewers can ask to control this machine")
        }
        if sharing.annotationsAvailable {
            notes.append("Viewers' drawings appear on this screen")
        }
        // Carries the reason they are unavailable, when they are. "Request
        // Control is missing" with no explanation is a support ticket; "2
        // displays share this resolution" is something the sharer can act on.
        if !sharing.message.isEmpty { notes.append(sharing.message) }
        // Where the frame time goes. A viewer's stats overlay can prove the
        // network is fine and still leave "why is it 2 fps" open — capture,
        // convert and encode are three different problems with three different
        // fixes, and the idle count separates all of them from "nothing on
        // screen moved".
        if let timings = sharing.timings {
            notes.append(timings.summary)
            if let slowest = timings.slowestStage {
                notes.append("slowest stage: \(slowest)")
            }
        }
        return notes
    }

    func signIn() {
        guard phase == .idle || phase == .failed else { return }
        phase = .starting
        status = "Starting Tailscale…"
        detail = ""
        loginURL = nil

        // Keep the node alive between viewing sessions. `run`'s defer clears
        // `preparedNode` on EVERY exit path, so without this the peer list is
        // still on screen with a node that is gone, and the next Refresh fails
        // with `badInterfaceHandle` — which is exactly what happened after
        // watching a share once.
        transport.retainsNodeAcrossSessions = true

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
                            self?.status = "Waiting for browser sign-in…"
                        }
                    }
                )
                loginURL = nil
                phase = .ready
                status = hubSignedInSubtitle(
                    tailnet: transport.tailnetName, account: transport.accountIdentity)
                labelActiveAccount()
                refreshPeers()
            } catch {
                phase = .failed
                loginURL = nil
                status = "Could not start Tailscale"
                detail = "\(error)"
            }
        }
    }

    func refreshPeers() {
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
                detail = "Discovery failed: \(error)"
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
        await withTaskGroup(of: (String, TailscreenMetadata?).self) { group in
            for peer in online {
                group.addTask { (peer.id, await transport.fetchMetadata(ip: peer.tailscaleIP)) }
            }
            for await (id, metadata) in group {
                shareInfo[id] = metadata
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
        status = "Connecting to \(peer.hostname)…"
        detail = ""

        sessionTask = Task { [weak self] in
            guard let self else { return }
            let sink = WindowsVideoSink(store: frameStore) { [weak self] in
                Task { @MainActor in self?.frameGeneration &+= 1 }
            }
            // Off-thread on purpose. The transport is serviced by the WinUI main
            // thread, so a blocking WASAPI write inline in `handleAudio` — up to
            // a device buffer, ~50×/s — would stall the UI loop and freeze
            // video. The wrapper is also what gives the sink its single-threaded
            // COM apartment, which is why it opens the device lazily.
            let audio = ThreadedAudioSink(wrapping: WASAPIAudioSink())
            defer { audio.stop() }
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
                    onBackChannelReady: { [weak self] channel in
                        Task { @MainActor in self?.interaction.beginSession(channel: channel) }
                    },
                    onAdmitted: { [weak self] caps in
                        Task { @MainActor in
                            self?.status = "Watching \(peer.hostname)"
                            // Drawing and Request Control appear only if the
                            // sharer said it can serve them. Withheld bits mean
                            // a quieter UI, never a broken one.
                            self?.interaction.setCaps(caps)
                        }
                    },
                    onAwaitingApproval: { [weak self] in
                        Task { @MainActor in
                            self?.status = "Waiting for \(peer.hostname) to approve…"
                        }
                    },
                    onDeclined: { [weak self] in
                        Task { @MainActor in self?.detail = "The sharer declined." }
                    }
                )
            } catch {
                detail = "Session ended: \(error)"
            }
            watching = nil
            sessionTask = nil
            // Before the status line, so a stale grant or armed tool can never
            // outlive the session that produced it.
            interaction.endSession()
            status = transport.accountIdentity.map { "Signed in as \($0)" } ?? "Signed in"
        }
    }

    func disconnect() {
        stopRequested = true
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
        return accounts + [HubAccount(id: Self.signOutEntryID, name: "Sign out")]
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
        status = "Switching account…"
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
    func startSharing() {
        guard phase == .ready, !sharing.isSharing else { return }
        detail = ""

        let item: WGC.CaptureItem?
        do {
            item = try shareSession.pickTarget()
        } catch {
            detail = "Could not open the capture picker: \(error)"
            return
        }
        // Dismissing the picker is a decision, not a failure. Say nothing.
        guard let item else { return }

        let quality = QualitySettings.default
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
                    existingNode: transport.sharedNode
                )
            } catch {
                self.detail = "Could not start sharing: \(error)"
            }
        }
    }

    func stopSharing() {
        Task { [weak self] in await self?.shareSession.stopSharing() }
    }

    func grantControl(to requestID: UUID) {
        if !shareSession.grantControl(to: requestID) {
            detail = "Remote control isn't available for this share."
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
        status = "Not signed in"
        detail = ""
        peers = []
        watching = nil
        Task { await transport.teardown() }
    }

    /// Open the login URL in the default browser.
    ///
    /// Via `cmd /c start` rather than `ShellExecuteW`, to keep WinSDK out of
    /// this module: WinSDK carries `#define uuid_t UUID`, which makes every
    /// `Foundation.UUID` ambiguous — the same trap documented in
    /// `TailscreenProtocol`'s PortabilityShims. A failure here is not fatal:
    /// the URL stays on screen to be copied by hand.
    func openLoginURL() {
        guard let url = loginURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        // The empty argument is `start`'s title parameter. Without it, a URL in
        // quotes is taken AS the title and no browser opens.
        process.arguments = ["/c", "start", "", url]
        do {
            try process.run()
        } catch {
            detail = "Could not open a browser — copy the URL above. (\(error))"
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
    /// returned here is the bare name — filtered to what a hostname may
    /// contain, and never empty.
    private static func machineName() -> String {
        let machine =
            ProcessInfo.processInfo.environment["COMPUTERNAME"]
            ?? ProcessInfo.processInfo.hostName
        let cleaned = machine.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return cleaned.isEmpty ? "windows" : cleaned
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
