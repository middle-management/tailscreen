import DefaultBackend
import Foundation
import SwiftCrossUI
import TailscreenHubUI
import TailscreenProtocol
import TailscreenViewer
import TailscreenViewerCore
import TailscreenViewerGtk
import TailscreenViewerTsnet

// tailscreen — native GTK desktop viewer.
//
//   tailscreen [<sharer-host>] [--port N] [--state-dir PATH] [--control-url URL]
//   tailscreen --render-self-test
//   Env: TAILSCREEN_TS_AUTHKEY, TAILSCREEN_TS_CONTROL_URL
//
// With a host argument the viewer dials it directly. WITHOUT one it enters
// picker mode: it brings the tsnet node up, discovers Tailscreen sharers on the
// tailnet, and shows a native list to choose from (L4).
//
// The window shows decoded video via the downstream GtkVideoView. The tsnet
// transport (reused from Packages/TailscreenLinuxBackends) runs on the main actor as a Task that
// swift-cross-ui's RunLoop tick services, feeding frames into the shared
// FrameStore; `present` (main thread) requests a GLArea repaint. The live tsnet
// leg is local-only. `--render-self-test` is the headless CI render gate (no
// network): it renders a colour-bars frame, reads the pixels back, and exits.

// swift-cross-ui's `App.main()` default-constructs the app, so shared state
// lives at module scope.
let gStore = FrameStore()
let gUIState = ViewerUIState()
let gControls = ViewerControls(ui: gUIState)
let gInput = InputForwarder(ui: gUIState)
let gPicker = PickerModel()
let gProfiles = ProfileStore()
let gAnnotations = AnnotationStore()
let gAnnoForwarder = AnnotationForwarder()
let gSharer = SharerModel()
// Account-menu actions, wired in picker mode (nil elsewhere → menu hidden).
var gSwitchProfile: (@MainActor @Sendable (String) -> Void)?
var gAddAccount: (@MainActor @Sendable () -> Void)?
// Return to the screen list after a session ends (picker mode); open the
// interactive-login URL in a browser. Wired in the picker block.
var gReturnToPicker: (@MainActor @Sendable () -> Void)?
var gOpenLogin: (@MainActor @Sendable () -> Void)?
let gArgs = Array(CommandLine.arguments.dropFirst())
let gSelfTest = gArgs.contains("--render-self-test")
// Headless chrome preview: render the hub with fake data and no networking, for
// screenshots / visual review under Xvfb. Never used in a real run.
let gUIPreview = gArgs.contains("--ui-preview")
// True when launched with no host arg → the picker drives host selection.
var gPickerMode = false

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    FileHandle.standardError.write(
        Data("usage: tailscreen [<sharer-host>] [--port N] [--no-audio] [--state-dir PATH] [--control-url URL]\n".utf8))
    exit(2)
}

/// Parse the live-run arguments. The host is OPTIONAL — its absence selects
/// picker mode. The returned `ViewerConfig` carries an empty hostname then
/// (`prepare` ignores hostname; the chosen sharer's IP fills it in before `run`).
func parseConfig() -> (config: ViewerConfig, host: String?, wantAudio: Bool, explicitStateDir: Bool) {
    var args = gArgs
    var host: String?
    var port: UInt16 = 7447
    var wantAudio = true
    var explicitStateDir = false
    var statePath = FileManager.default.currentDirectoryPath + "/.tailscreen-state"
    let env = ProcessInfo.processInfo.environment
    var controlURL = env["TAILSCREEN_TS_CONTROL_URL"]
    let authKey = env["TAILSCREEN_TS_AUTHKEY"]

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--port":
            guard let raw = args.first, let value = UInt16(raw) else { fail("--port needs a number") }
            port = value
            args.removeFirst()
        case "--no-audio":
            wantAudio = false
        case "--state-dir":
            guard let value = args.first else { fail("--state-dir needs a path") }
            statePath = value
            explicitStateDir = true
            args.removeFirst()
        case "--control-url":
            guard let value = args.first else { fail("--control-url needs a URL") }
            controlURL = value
            args.removeFirst()
        case let other where other.hasPrefix("--"):
            fail("unknown option \(other)")
        default:
            guard host == nil else { fail("unexpected extra argument \(arg)") }
            host = arg
        }
    }

    var config = ViewerConfig(hostname: host ?? "", port: port, authKey: authKey, statePath: statePath)
    if let controlURL { config.controlURL = controlURL }
    return (config, host, wantAudio, explicitStateDir)
}

if gSelfTest {
    // Headless render gate: a colour-bars frame the GtkVideoView renders and
    // the self-test verifies via glReadPixels. No transport.
    gStore.set(makeColorBarsFrame())
} else if gUIPreview {
    // Headless chrome preview: seed the picker with fake sharers and render the
    // hub without any networking, so the UI can be screenshotted / reviewed.
    gPickerMode = true
    gPicker.phase = .picking
    // Tagged and untagged, online and offline, so the header's filter menu has
    // every axis to show in a screenshot.
    gPicker.sharers = [
        DiscoveredSharer(id: "1", hostname: "robert-macbook", tailscaleIP: "100.64.0.12", isOnline: true),
        DiscoveredSharer(
            id: "2", hostname: "studio-imac", tailscaleIP: "100.64.0.31", isOnline: true,
            tags: ["tag:studio"]),
        DiscoveredSharer(
            id: "3", hostname: "living-room-tv", tailscaleIP: "100.64.0.44", isOnline: false,
            tags: ["tag:media"]),
    ]
    // The preview is a screenshot surface, not a returning user: show the whole
    // seeded list (including the offline row) regardless of what this machine
    // happens to have persisted.
    gPicker.setFilter(.default, persist: false)
    gPicker.shareInfo = [
        "1": TailscreenMetadata(
            shareName: "robert's Screen", hostname: "robert-macbook",
            screenResolution: .init(width: 1920, height: 1080),
            isSharing: true, timestamp: Date(), videoCodec: .hevc),
    ]
    // Show the account menu in the preview (no-op actions).
    gSwitchProfile = { _ in }
    gAddAccount = {}
    // `--ui-preview-video` jumps straight to the video state (a color-bars
    // frame) so the window-grows-to-video behaviour is screenshot-reviewable.
    if gArgs.contains("--ui-preview-video") {
        // A 16:9 gradient stand-in for real video — big enough that the
        // annotation overlay is legible in a screenshot. (The CI render
        // self-test keeps using the small colour-bars frame, which its pixel
        // assertions are calibrated against.)
        gStore.set(makePreviewFrame(width: 960, height: 540))
        gUIState.remoteControlAvailable = true
        gUIState.annotationsAvailable = true
        gUIState.hasVideo = true
        gUIState.videoWidth = 1920
        gUIState.videoHeight = 1080
        gUIState.fps = 30
        gUIState.showStats = true
        gUIState.activeTool = .pen
        // One stroke per tool so the overlay + shape geometry are both visible.
        func seed(_ tool: AnnotationTool, _ points: [CGPoint], _ colorIndex: Int) {
            gAnnotations.apply(.add(Annotation(
                id: UUID(), tool: tool, points: points,
                color: Annotation.RGBA.palette[colorIndex], width: 4)))
        }
        seed(.pen, [CGPoint(x: 0.08, y: 0.30), CGPoint(x: 0.20, y: 0.55), CGPoint(x: 0.14, y: 0.72)], 0)
        seed(.line, [CGPoint(x: 0.28, y: 0.30), CGPoint(x: 0.40, y: 0.72)], 1)
        seed(.arrow, [CGPoint(x: 0.46, y: 0.72), CGPoint(x: 0.58, y: 0.30)], 2)
        seed(.rectangle, [CGPoint(x: 0.62, y: 0.34), CGPoint(x: 0.76, y: 0.66)], 3)
        seed(.oval, [CGPoint(x: 0.80, y: 0.34), CGPoint(x: 0.94, y: 0.66)], 4)
        seed(.click, [CGPoint(x: 0.50, y: 0.85)], 5)
    }
    if gArgs.contains("--ui-preview-placard") {
        gUIState.inSession = true
        gUIState.sessionPhase = .awaitingApproval
    }
} else {
    // Live path: reuse the tsnet transport, driving decoded frames into the
    // shared store. The transport is @MainActor; started as a Task here, it
    // runs interleaved with the GTK loop (swift-cross-ui ticks RunLoop.main),
    // so `present` — and thus the GLArea repaint — happens on the main thread.
    let (baseConfig, host, wantAudio, explicitStateDir) = parseConfig()
    let sink = GtkVideoSink(store: gStore, uiState: gUIState)
    let decoder = FFmpegVideoDecoder()
    let transport = TsnetTransport()
    // Audio out: an ALSA sink fronted by a background thread so its blocking
    // device write never runs on the GTK main thread (the transport loop is
    // serviced by RunLoop.main). Best-effort — a missing/busy device (or a
    // headless box) shouldn't block viewing, so failure just drops to video-only.
    var audioSink: AudioSink?
    if wantAudio {
        do {
            audioSink = try makeThreadedALSAAudioSink()
        } catch {
            FileHandle.standardError.write(Data("warning: audio disabled (\(error))\n".utf8))
        }
    }
    // Inbound back-channel handlers: control grant/revoke drive the toolbar's
    // state machine. Inbound annotation *rendering* (drawing relayed strokes on
    // an overlay canvas) is a follow-up — the plumbing already carries the ops.
    // Relay finalized local annotation ops; apply relayed ops to the canvas.
    gAnnotations.onLocalOp = { op in gAnnoForwarder.submit(op) }
    let backChannelHandlers = ViewerBackChannel.Handlers(
        onAnnotation: { op in gAnnotations.apply(op) },
        onControlGranted: { gUIState.setControlState(.active) },
        onControlRevoked: { reason in gUIState.setControlState(.revoked(reason: reason)) })

    // The sharer borrows this transport's node rather than bringing up its own
    // — one app, one tailnet identity. `retainsNodeAcrossSessions` is what
    // makes that safe: without it the node goes down when a viewing session
    // ends, which would silently kill an in-progress share.
    transport.retainsNodeAcrossSessions = gPickerMode
    gSharer.nodeProvider = { transport.liveNode }

    // Run a viewing session against a chosen host/IP. Shared by the direct-host
    // path and the picker's selection callback (both on the main actor). Drives
    // the session-lifecycle placard and, in picker mode, returns to the list
    // when the session ends or is declined.
    func startSession(host dialHost: String) {
        var config = baseConfig
        config.hostname = dialHost
        sink.resetForNewSession()  // the sink outlives one session
        gAnnotations.resetForNewSession()
        gUIState.beginSession()
        // A reference box for the decline flag, set from the @Sendable
        // onDeclined callback (both it and the post-run read run on MainActor).
        final class DeclinedFlag: @unchecked Sendable { var value = false }
        let declined = DeclinedFlag()
        Task { @MainActor in
            do {
                try await transport.run(
                    config: config, decoder: decoder, videoSink: sink,
                    audioSink: audioSink, shouldClose: { false },
                    backChannelHandlers: backChannelHandlers,
                    onBackChannelReady: { channel in
                        gControls.attach(channel)
                        gInput.attach(channel)
                        gAnnoForwarder.attach(channel)
                    },
                    onAdmitted: { caps in
                        gUIState.setCaps(
                            remoteControl: caps.contains(.remoteControl),
                            annotations: caps.contains(.annotations))
                    },
                    onAwaitingApproval: { gUIState.post(sessionPhase: .awaitingApproval) },
                    onDeclined: {
                        declined.value = true
                        gUIState.post(sessionPhase: .declined)
                    })
                FileHandle.standardError.write(Data("session ended\n".utf8))
                gUIState.post(sessionPhase: declined.value ? .declined : .ended)
            } catch {
                FileHandle.standardError.write(Data("session failed: \(error)\n".utf8))
                gUIState.post(sessionPhase: .failed("Connection failed"))
            }
            // Back to the picker after a beat so the declined/ended placard is
            // readable (picker mode only; a direct-host run has no list to
            // return to, so it rests on the placard).
            if gPickerMode, let ret = gReturnToPicker {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                ret()
            }
        }
    }

    if let host {
        // Direct connect — a host was named on the command line.
        startSession(host: host)
    } else {
        // Picker mode: bring the node up, discover sharers, and let the user
        // choose. Dialing the chosen sharer's tailnet IP (not its hostname)
        // also sidesteps the `from == dest` hostname-match limitation.
        gPickerMode = true
        gPicker.onSelect = { sharer in startSession(host: sharer.tailscaleIP) }

        // Discover sharers on the live node, then sweep their live share status
        // (name / resolution) concurrently. Reused by the initial bring-up and
        // the header Refresh, so the list can be re-listed without re-login.
        @Sendable func discoverAndSweep() {
            Task { @MainActor in
                do {
                    gPicker.phase = .discovering
                    let peers = try await transport.discoverPeers()
                    // Raw and unfiltered: the source of truth the header's
                    // filter projects from (and what its tag menu enumerates).
                    // Hiding offline machines is now the filter's job — and it
                    // defaults to on, so the list looks unchanged. Only the
                    // metadata sweep stays online-only: dialing a machine tsnet
                    // says is down buys nothing but a timeout.
                    gPicker.sharers = peers
                    let online = peers.filter { $0.isOnline }
                    // Label the header with the tailnet these rows belong to
                    // (falling back to the login) — set before `.picking`, so
                    // the placard never flashes the old guidance text.
                    gPicker.tailnetName = transport.tailnetName
                    gPicker.accountIdentity = transport.accountIdentity
                    gPicker.phase = .picking
                    // Lazy per-sharer metadata sweep (the sharing chip + res).
                    await withTaskGroup(of: (String, TailscreenMetadata?).self) { group in
                        for sharer in online {
                            group.addTask { (sharer.id, await transport.fetchMetadata(ip: sharer.tailscaleIP)) }
                        }
                        for await (id, meta) in group {
                            if let meta { gPicker.shareInfo[id] = meta } else { gPicker.shareInfo[id] = nil }
                        }
                    }
                } catch {
                    FileHandle.standardError.write(Data("discovery failed: \(error)\n".utf8))
                    gPicker.phase = .picking  // renders "No screens found"
                }
            }
        }
        gPicker.onRefresh = { discoverAndSweep() }

        // Quiet auto-refresh: while the list is showing, re-list every 10 s
        // WITHOUT flipping to the "discovering…" placard, so peers coming/going
        // are reflected live (a lightweight stand-in for an IPN-bus subscription;
        // full IPN wiring is a follow-up). Skips while a session/bring-up is in
        // flight (phase != .picking).
        @Sendable func quietRefresh() {
            Task { @MainActor in
                guard case .picking = gPicker.phase else { return }
                guard let peers = try? await transport.discoverPeers() else { return }
                guard case .picking = gPicker.phase else { return }  // re-check after await
                gPicker.sharers = peers
                let online = peers.filter { $0.isOnline }
                let ids = Set(online.map(\.id))
                gPicker.shareInfo = gPicker.shareInfo.filter { ids.contains($0.key) }
                await withTaskGroup(of: (String, TailscreenMetadata?).self) { group in
                    for sharer in online {
                        group.addTask { (sharer.id, await transport.fetchMetadata(ip: sharer.tailscaleIP)) }
                    }
                    for await (id, meta) in group where meta != nil {
                        gPicker.shareInfo[id] = meta
                    }
                }
            }
        }
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                quietRefresh()
            }
        }

        // Return to the screen list when a session ends: reset the session UI
        // and re-list.
        gReturnToPicker = {
            gUIState.returnToPickerState()
            gAnnotations.resetForNewSession()
            gPicker.phase = .picking
            discoverAndSweep()
        }

        // Open the interactive-login URL in a local browser (best-effort).
        gOpenLogin = {
            guard let urlString = gPicker.loginURL else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["xdg-open", urlString]
            try? process.run()
        }

        // Each profile owns a tsnet state dir (its own identity/keys), unless the
        // user forced one with --state-dir.
        @Sendable func stateDir(for profile: ViewerProfile) -> String {
            explicitStateDir ? baseConfig.statePath : profile.statePath
        }

        // Bring up (or switch to) a profile: tear the current node down, reset
        // the picker, prepare under the profile's state dir, then discover. A
        // fresh profile's empty state dir triggers interactive login.
        @Sendable func bringUp(profile: ViewerProfile) {
            Task { @MainActor in
                await transport.teardown()
                gPicker.loginURL = nil
                gPicker.sharers = []
                gPicker.shareInfo = [:]
                gPicker.phase = .startingNode
                var config = baseConfig
                config.statePath = stateDir(for: profile)
                // Register under a discoverable name when this host can share:
                // `isTailscreenServerHostname` excludes the viewer prefix, so a
                // viewer-named node could never be picked by anyone. The cost
                // is that the app appears in peers' lists while idle — which is
                // exactly what the macOS app does, with the "only screens being
                // shared" filter (a metadata probe) telling idle from sharing.
                if gSharer.canShare {
                    config.nodeRole = .shareCapable(name: localShareName())
                }
                do {
                    try await transport.prepare(config: config, onLoginURL: { url in
                        Task { @MainActor in gPicker.loginURL = url.absoluteString }
                    })
                    gPicker.loginURL = nil
                    // Label the account by its resolved login once known.
                    if let identity = transport.accountIdentity {
                        gProfiles.rename(profile.id, to: identity)
                    }
                    discoverAndSweep()
                } catch {
                    FileHandle.standardError.write(Data("node bring-up failed: \(error)\n".utf8))
                    gPicker.phase = .picking
                }
            }
        }

        // Account-menu actions.
        gSwitchProfile = { id in
            guard id != gProfiles.activeID else { return }
            gProfiles.setActive(id)
            bringUp(profile: gProfiles.active)
        }
        gAddAccount = {
            bringUp(profile: gProfiles.addProfile())
        }

        bringUp(profile: gProfiles.active)
    }
}

struct ViewerApp: App {
    // Observe the shared UI state so the placard reactively hides once video
    // flows (swift-cross-ui @State tracks the ObservableObject's @Published).
    @State var ui = gUIState
    @State var picker = gPicker
    // Observed so the account menu re-renders on switch / add / rename.
    @State var profileStore = gProfiles
    // Observed so the share card re-renders as viewers join / leave.
    @State var sharer = gSharer

    // Toolbar button label reflects the remote-control state machine.
    private var controlButtonLabel: String {
        switch ui.controlState {
        case .idle, .revoked: return "Request Control"
        case .requested: return "Requesting Control…"
        case .active: return "Release Control"
        }
    }

    // A revoke/decline reason to surface beside the button, if any.
    private var revokedReason: String? {
        if case .revoked(let reason) = ui.controlState, !reason.isEmpty { return reason }
        return nil
    }

    // Whether the picker list of sharers should be shown right now.
    private var showingPickerList: Bool {
        if case .picking = picker.phase { return true }
        return false
    }

    // Header subtitle: the picker's progress line, or the direct-connect status.
    private var headerSubtitle: String {
        gPickerMode ? picker.statusLine : ui.status
    }

    // A spinner rides the header while the node is coming up / discovering.
    private var headerShowsSpinner: Bool {
        guard gPickerMode else { return false }
        switch picker.phase {
        case .startingNode, .discovering: return true
        case .picking, .connecting: return false
        }
    }

    // Refresh is offered only from the settled picking state. Captures the
    // module-global `gPicker` (Sendable) rather than `self` so the closure can
    // satisfy the Button action's `@MainActor @Sendable` type.
    private var headerOnRefresh: (@MainActor @Sendable () -> Void)? {
        guard gPickerMode && showingPickerList else { return nil }
        return { gPicker.refresh() }
    }

    /// The peer-list filter, offered from the same settled picking state as
    /// Refresh — there is nothing to filter while the node is still coming up.
    /// All three axes are live here: the picker keeps the raw peer list
    /// (including offline machines), `DiscoveredSharer` now carries the netmap's
    /// ACL tags, and the existing metadata sweep already fills `shareInfo`,
    /// which is the sharing axis's input.
    private var headerFilter: HubFilter? {
        guard gPickerMode && showingPickerList else { return nil }
        return HubFilter(
            filter: picker.filter,
            tags: picker.knownTags,
            onChange: { gPicker.setFilter($0) })
    }

    var body: some Scene {
        WindowGroup("Tailscreen viewer") {
            rootView
        }
        // Opens hub-narrow (the picker is a single column, like the mac hub);
        // GtkVideoView grows the window to the video's size on the first frame.
        .defaultSize(width: 460, height: 680)
    }

    /// The window's content: the headless render self-test surface, live video
    /// (once frames flow) with its remote-control bar, or the hub chrome
    /// (header + picker / connecting placard) before video. The `GtkVideoView`
    /// is mounted only when there's something to show, so the hub chrome sits on
    /// the native GTK window background rather than over a black GL surface — the
    /// first frame is stored before `hasVideo` flips, so mounting renders it.
    // The host being connected to (for the session placard), from the picker's
    // connecting phase.
    private var sessionHost: String {
        if case .connecting(let host) = picker.phase { return host }
        return ""
    }

    /// The viewer's session state as the shared placard's phase.
    ///
    /// Two enums rather than one because the chrome must not import a viewer's
    /// session model to draw five sentences — the same reason it takes
    /// `HubScreen` instead of `DiscoveredSharer`. The cost is this function;
    /// the benefit is a UI package that compiles without a transport.
    private static func hubPhase(_ phase: ViewerUIState.SessionPhase) -> HubSessionPhase {
        switch phase {
        case .connecting: return .connecting
        case .awaitingApproval: return .awaitingApproval
        case .viewing: return .viewing
        case .declined: return .declined
        case .ended: return .ended
        case .failed(let reason): return .failed(reason)
        }
    }

    /// The hub's sharing card. Only offered in picker mode: the direct-host
    /// path (`tailscreen <host>`) is a one-shot viewer invocation,
    /// and growing a share button onto it would be surprising.
    private var shareCard: ShareCard? {
        guard gPickerMode else { return nil }
        return ShareCard(
            statusLine: sharer.statusLine,
            isSharing: sharer.phase == .sharing,
            canShare: sharer.canShare,
            notes: sharer.viewerIPs.map { "• \($0) watching" },
            // Viewers parked at the approval gate. The shared card renders
            // these exactly like the Windows app's control requests, because
            // they are the same interaction and this window is the only place
            // either can be answered.
            prompts: sharer.pendingViewers.map {
                // `id` is the server's `"ip:port"` key, which is what
                // approve/deny take; the label is only what the row says.
                HubPrompt(
                    id: $0.id, message: "\($0.label) wants to watch",
                    acceptLabel: "Accept", declineLabel: "Deny")
            },
            settings: [
                HubToggle(
                    label: "Require approval for new viewers",
                    caption: sharer.requireApproval
                        ? nil
                        : "Anyone on your tailnet who can reach this machine can watch.",
                    isOn: sharer.requireApproval,
                    set: { gSharer.setRequireApproval($0) })
            ],
            onStart: { gSharer.startSharing() },
            onStop: { gSharer.stopSharing() },
            onAccept: { gSharer.approve($0) },
            onDecline: { gSharer.deny($0) })
    }

    /// The picker's discovered machines as hub rows, with the metadata sweep's
    /// answer folded in so the shared chrome derives the sharing chip.
    ///
    /// Built from the FILTERED projection; `picker.sharers` stays raw so the tag
    /// menu and any future auto-connect still see every machine.
    private var hubScreens: [HubScreen] {
        picker.filteredSharers.map { sharer in
            HubScreen(
                id: sharer.id, hostname: sharer.hostname, tailscaleIP: sharer.tailscaleIP,
                isOnline: sharer.isOnline, metadata: picker.shareInfo[sharer.id])
        }
    }

    @ViewBuilder private var rootView: some View {
        if gSelfTest {
            GtkVideoView(store: gStore, selfTest: true)
        } else if ui.hasVideo {
            // Toolbar ROW above the video (the mac viewer puts its annotation
            // NSToolbar in the window's title bar, not floating over the
            // content), then the video with its overlays beneath it.
            VStack(spacing: 0) {
                if ui.annotationsAvailable {
                    AnnotationToolbar(
                        activeTool: ui.activeTool,
                        inkColor: gAnnotations.color,
                        statsShown: ui.showStats,
                        onSelectTool: { tool in
                            // Radio behaviour like the mac tool group, plus
                            // click-the-selected-tool to disarm — a Linux viewer
                            // still needs plain drags for zoom/pan + control.
                            let disarm = gUIState.activeTool == tool
                            gUIState.activeTool = disarm ? nil : tool
                            gAnnotations.mode = disarm ? .off : .drawing(tool)
                        },
                        onUndo: { gAnnotations.undo() },
                        onClear: { gAnnotations.clearAll() },
                        onToggleStats: { gUIState.showStats.toggle() })
                    Divider()
                }
                ZStack {
                    GtkVideoView(
                        store: gStore, onInputEvent: { gInput.submit($0) },
                        annotations: gAnnotations,
                        chromeHeight: ui.annotationsAvailable ? HubStyle.toolbarHeight : 0)
                    // Stats HUD, pinned top-left over the video (toggleable from
                    // the toolbar, like the mac viewer's Stats item).
                    if ui.showStats {
                        VStack {
                            HStack {
                                StatsHUD(width: ui.videoWidth, height: ui.videoHeight, fps: ui.fps)
                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(10)
                    }
                    // Remote-control bar stays pinned at the bottom: it's a
                    // session affordance, not a drawing tool.
                    if ui.remoteControlAvailable {
                        VStack {
                            Spacer()
                            RemoteControlBar(
                                buttonLabel: controlButtonLabel,
                                declinedReason: revokedReason,
                                onToggle: { gControls.toggleControl() })
                        }
                    }
                }
            }
        } else if ui.inSession {
            // A session is up but no video yet: connecting / awaiting approval /
            // declined / ended placard.
            VStack(spacing: 0) {
                ViewerHeader(subtitle: "Viewer")
                Divider()
                SessionPlacard(phase: Self.hubPhase(ui.sessionPhase), host: sessionHost)
            }
        } else {
            VStack(spacing: 0) {
                ViewerHeader(
                    subtitle: headerSubtitle,
                    showSpinner: headerShowsSpinner,
                    filter: headerFilter,
                    onRefresh: headerOnRefresh,
                    accountName: gPickerMode ? profileStore.active.name : nil,
                    accounts: profileStore.profiles.map {
                        HubAccount(id: $0.id, name: $0.name)
                    },
                    activeAccountID: profileStore.activeID,
                    onSelectAccount: gSwitchProfile,
                    onAddAccount: gAddAccount)
                Divider()
                if gPickerMode {
                    PickerContent(
                        statusLine: picker.statusLine,
                        isPicking: showingPickerList,
                        screens: hubScreens,
                        loginURL: picker.loginURL,
                        autoExpandFirst: gUIPreview,
                        hiddenByFilter: picker.hiddenByFilter,
                        // The chrome hands back the row's id rather than a
                        // transport type it deliberately does not import.
                        onSelect: { id in
                            guard let chosen = gPicker.sharers.first(where: { $0.id == id })
                            else { return }
                            gPicker.select(chosen)
                        },
                        onOpenLogin: gOpenLogin,
                        shareCard: shareCard)
                } else {
                    HubStatusPane(status: ui.status)
                }
            }
        }
    }
}

ViewerApp.main()
