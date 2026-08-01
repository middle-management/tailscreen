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
import struct TailscreenProtocol.CaptureTimings
import struct TailscreenProtocol.ControlRequestInfo
import struct TailscreenProtocol.QualitySettings
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
            onRefresh: headerRefresh,
            secondaryAction: headerSignOut)
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

    private var headerSignOut: HubAction? {
        guard state.phase == .ready, state.watching == nil else { return nil }
        let model = state
        return HubAction(label: "Sign out") { model.signOut() }
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
    private func watching(host: String) -> some View {
        let model = state
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Watching \(host)")
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                Spacer()
                Button("Stop") { model.disconnect() }
            }
            .padding(.horizontal, 16)
            .frame(height: Double(HubStyle.toolbarHeight))
            .frame(maxWidth: .infinity)
            .background(HubStyle.barFill)
            WinUIVideoView(store: state.frameStore, generation: state.frameGeneration)
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
    @Published var peers: [DiscoveredSharer] = []
    @Published var isSearching = false
    /// Non-nil while a viewing session is running — the hostname on screen.
    @Published var watching: String?
    /// Bumped per decoded frame so SwiftCrossUI re-runs `updateWinUIElement`.
    /// The frame itself travels through `frameStore`, never through this.
    @Published var frameGeneration = 0

    /// Sharing state, mirrored from `SharingController` (which is off the main
    /// actor on purpose — see its type comment).
    @Published var sharing = WindowsShareSession.Status()

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
        if Self.hasPreviousLogin() {
            signIn()
        }
    }

    private static func hasPreviousLogin() -> Bool {
        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory())) ?? []
        return !entries.isEmpty
    }

    private let transport = TsnetTransport()
    private let shareSession = WindowsShareSession()
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

    /// The discovered peers as hub rows.
    ///
    /// No metadata: the Windows app has no equivalent of the macOS sharing
    /// sweep yet, so no row claims a green "Sharing" chip. Absent rather than
    /// guessed — a chip that appears when a machine is merely reachable would
    /// be a lie, and the chip is the one thing on the row people act on.
    var hubScreens: [HubScreen] {
        peers.map {
            HubScreen(
                id: $0.id, hostname: $0.hostname, tailscaleIP: $0.tailscaleIP,
                isOnline: $0.isOnline)
        }
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
            // Control requests and viewer approvals are the same interaction —
            // a sentence and two buttons — so they go through the one prompt
            // shape the shared card renders. This window is the only surface
            // this app has; a request not rendered here is one nobody can
            // answer, which is exactly what happened when the Windows sharer
            // advertised the capability and had nowhere to show the request.
            prompts: sharing.controlRequests.map {
                HubPrompt(
                    id: $0.id.uuidString,
                    message: "\($0.displayName) wants to control this machine")
            },
            extraAction: sharing.controlGrantedTo.map { holder in
                HubAction(label: "Take back control from \(holder)") { [weak self] in
                    self?.revokeControl()
                }
            },
            onStart: { [weak self] in self?.startSharing() },
            onStop: { [weak self] in self?.stopSharing() },
            onAccept: { [weak self] id in
                guard let requestID = UUID(uuidString: id) else { return }
                self?.grantControl(to: requestID)
            },
            onDecline: { [weak self] id in
                guard let requestID = UUID(uuidString: id) else { return }
                self?.declineControl(requestID)
            })
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
                        statePath: Self.stateDirectory(),
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
                status =
                    transport.accountIdentity.map { "Signed in as \($0)" }
                    ?? "Signed in"
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
                peers = try await transport.discoverPeers()
            } catch {
                detail = "Discovery failed: \(error)"
            }
            isSearching = false
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
                        statePath: Self.stateDirectory()
                    ),
                    decoder: FFmpegVideoDecoder(),
                    videoSink: sink,
                    audioSink: audio,
                    shouldClose: { [weak self] in self?.stopRequested ?? true },
                    onAdmitted: { [weak self] _ in
                        Task { @MainActor in self?.status = "Watching \(peer.hostname)" }
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
            status = transport.accountIdentity.map { "Signed in as \($0)" } ?? "Signed in"
        }
    }

    func disconnect() {
        stopRequested = true
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

        shareSession.onStatus = { [weak self] status in
            Task { @MainActor in self?.sharing = status }
        }

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
                    statePath: Self.stateDirectory(),
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

    /// Where the tsnet node keeps its state (machine key, netmap).
    ///
    /// Under `%LOCALAPPDATA%` because it is per-machine, per-user data that
    /// should not roam: the machine key identifies *this* device to the tailnet,
    /// and a roaming profile would carry it to another one.
    private static func stateDirectory() -> String {
        let base =
            ProcessInfo.processInfo.environment["LOCALAPPDATA"]
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: base)
            .appendingPathComponent("Tailscreen")
            .appendingPathComponent("tailscale")
            .path
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
