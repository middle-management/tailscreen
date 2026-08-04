import DefaultBackend
import Foundation
import SwiftCrossUI
import TailscreenHubUI
import TailscreenL10n
import TailscreenProtocol

// Targeted: the mic seam only. A blanket `import TailscreenAudio` would pull
// OpusKit's re-exports into this file for two type names.
import protocol TailscreenAudio.MicrophoneCapturing
import TailscreenViewer
import TailscreenViewerCore
import TailscreenViewerGtk
import TailscreenViewerTsnet

// tailscreen — native GTK desktop viewer.
//
//   tailscreen [<sharer-host>] [--port N] [--state-dir PATH] [--control-url URL]
//   tailscreen --render-self-test | --overlay-self-test | --overlay-input-self-test
//   tailscreen --outline-self-test
//   tailscreen --capture-backend-report
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
let gVoice = VoiceControls(ui: gUIState)
let gPicker = PickerModel()
let gProfiles = ProfileStore()
let gAnnotations = AnnotationStore()
let gAnnoForwarder = AnnotationForwarder()
let gSharer = SharerModel()
// The system-wide mute hotkey. Built only on the live audio path — see the
// comment where it is assigned.
var gMuteHotkey: MuteHotkeyController?
// Account-menu actions, wired in picker mode (nil elsewhere → menu hidden).
var gSwitchProfile: (@MainActor @Sendable (String) -> Void)?
var gAddAccount: (@MainActor @Sendable () -> Void)?
// Return to the screen list after a session ends (picker mode); open the
// interactive-login URL in a browser. Wired in the picker block.
var gReturnToPicker: (@MainActor @Sendable () -> Void)?
var gOpenLogin: (@MainActor @Sendable () -> Void)?
let gArgs = Array(CommandLine.arguments.dropFirst())
let gSelfTest = gArgs.contains("--render-self-test")
// Headless SHARER gate: draw a known stroke on the annotation overlay and read
// the screen back through X11 capture to prove it landed. See OverlaySelfTest.
let gOverlaySelfTest = gArgs.contains("--overlay-self-test")
let gOverlayInputSelfTest = gArgs.contains("--overlay-input-self-test")
let gOutlineSelfTest = gArgs.contains("--outline-self-test")
// Which capture backend this machine would use, and why. Prints and exits;
// raises no dialog. Covers the wiring between the environment and
// `CaptureBackendSelection`, which its unit tests cannot reach.
if gArgs.contains("--capture-backend-report") {
    CaptureBackendReport.run()
}
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
/// The sharer's playback sink for viewers' voices, opened on first use.
///
/// Separate from the viewer's `audioSink` because the two are alive at
/// different times — this app can share while not watching — and because
/// sharing one would mean a viewing session's teardown silently taking the
/// share's audio with it. Failure is best-effort and permanent for the
/// process: a machine with no output device shares fine, it just cannot hear.
/// A holder rather than a bare global: `main.swift` is top-level code, where a
/// `var` cannot carry a global actor, and this is only ever touched from the
/// main actor.
@MainActor
final class SharerVoiceSink {
    static let shared = SharerVoiceSink()
    private var sink: AudioSink?
    private var tried = false

    func resolve() -> AudioSink? {
        if tried { return sink }
        tried = true
        do {
            sink = try makeThreadedALSAAudioSink()
        } catch {
            FileHandle.standardError.write(
                Data("warning: cannot play viewers' voices (\(error))\n".utf8))
        }
        return sink
    }
}

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
} else if gOverlaySelfTest {
    // Headless SHARER-overlay gate. Scheduled rather than run here: it needs
    // the GTK main loop up to create a window and to service the repaint it
    // posts, and swift-cross-ui ticks RunLoop.main, so a main-queue block set
    // now runs once the app is live. It exits the process itself, pass or fail.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { OverlaySelfTest.run() }
} else if gOverlayInputSelfTest {
    // The other half of the same window: can it take the pointer back from the
    // desktop when a tool is armed, and give it up again on Escape. Same
    // scheduling reason as above.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { OverlayInputSelfTest.run() }
} else if gOutlineSelfTest {
    // The recording indicator: does the border reach a real desktop, and does
    // it leave the middle of the screen alone. Same scheduling reason again.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { OutlineSelfTest.run() }
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
    // Audio in: the same best-effort rule, and the same reason it is built
    // here rather than per session — opening a capture device is the slow,
    // failable part, and a box with no microphone should discover that once.
    // Nil means no mic control is offered at all, which is the honest answer.
    var microphone: MicrophoneCapturing?
    if wantAudio {
        do {
            microphone = try makeALSAMicrophone()
        } catch {
            FileHandle.standardError.write(
                Data("warning: microphone unavailable (\(error))\n".utf8))
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
    // The sharer's own voice: the same ALSA ends the viewer uses, handed over
    // as closures so `SharerModel` names no audio library. The factory is
    // called at share start and the device released at share stop — a
    // long-lived open would keep the microphone indicator lit while idle.
    if wantAudio {
        gSharer.microphoneFactory = { try makeALSAMicrophone() }
        // Built on first use and kept for the process: unlike capture, an
        // output device that is open but silent costs nothing and shows
        // nothing, and reopening it per share would add a stall to Stop/Start.
        gSharer.playRemoteVoice = { pcm in SharerVoiceSink.shared.resolve()?.play(pcm) }
    }

    // Mute from OUTSIDE the window. The in-window buttons only exist while the
    // app is in front of you, and during a share it is behind whatever you are
    // showing — which is exactly when muting matters most.
    //
    // The two microphones stay separate (`toggleMic` vs `toggleShareMic`);
    // `MuteHotkeyRouting` picks which one the single chord flips, and the
    // controller holds the grab only while there is one to flip.
    if wantAudio {
        gMuteHotkey = MuteHotkeyController(
            sharerMicAvailable: { gSharer.micAvailable },
            viewerMicAvailable: { gUIState.micAvailable },
            toggleSharerMic: { gSharer.toggleMic() },
            toggleViewerMic: { gVoice.toggle() })
        gMuteHotkey?.start()
    }

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
        gUIState.setMicAvailable(false)
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
                    microphone: microphone,
                    onVoiceReady: { uplink in
                        gVoice.attach(uplink)
                        gUIState.setMicAvailable(true)
                    },
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
                gVoice.detach()
                gUIState.post(sessionPhase: declined.value ? .declined : .ended)
            } catch {
                FileHandle.standardError.write(Data("session failed: \(error)\n".utf8))
                gVoice.detach()
                gUIState.post(sessionPhase: .failed(L("Connection failed")))
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
        // Ask a machine to start sharing. The task parks for up to two minutes
        // on the far side, so nothing here awaits it inline — the row shows
        // that the ask is outstanding and the window stays usable, including
        // for viewing a different screen that came free meanwhile.
        gPicker.onAskToShare = { sharer in
            let id = sharer.id
            let ip = sharer.tailscaleIP
            gPicker.beginAsking(id)
            Task { @MainActor in
                let outcome = await transport.requestToShare(ip: ip, from: localShareName())
                switch outcome {
                case .accepted:
                    // Not a success message: they are still choosing what to
                    // show, and their share appears in this list on its own
                    // when it starts.
                    gPicker.finishAsking(
                        id, outcome: L("Accepted — they're choosing what to share"))
                case .declined:
                    gPicker.finishAsking(id, outcome: L("Declined"))
                case .noAnswer:
                    // One wording for away, closed and too-old-to-understand,
                    // because the asker cannot act on the difference.
                    gPicker.finishAsking(id, outcome: L("No reply"))
                }
            }
        }

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
                    // Start answering asks to share. Here rather than at
                    // bring-up because a successful discovery is the first
                    // point at which the node is provably usable, and it is
                    // idempotent per node — so the 10 s auto-refresh also
                    // re-points it after a profile switch brings a different
                    // node up.
                    gSharer.ensureControlListener()
                    // Lazy per-sharer probe: the sharing chip + resolution, and
                    // the round-trip time behind the detail pane's Route line —
                    // one dial, not two, since this was already a TCP round trip
                    // over the live path.
                    await withTaskGroup(of: (String, PeerProbe).self) { group in
                        for sharer in online {
                            group.addTask { (sharer.id, await transport.probePeer(ip: sharer.tailscaleIP)) }
                        }
                        for await (id, probe) in group {
                            gPicker.shareInfo[id] = probe.metadata
                            gPicker.latencyMs[id] = probe.latencyMs
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
                await withTaskGroup(of: (String, PeerProbe).self) { group in
                    for sharer in online {
                        group.addTask { (sharer.id, await transport.probePeer(ip: sharer.tailscaleIP)) }
                    }
                    // The quiet refresh keeps a previous answer rather than
                    // blanking on one failed probe — a peer that briefly does
                    // not answer should not make the row flicker.
                    for await (id, probe) in group where probe.metadata != nil {
                        gPicker.shareInfo[id] = probe.metadata
                        gPicker.latencyMs[id] = probe.latencyMs
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
        case .idle, .revoked: return L("Request Control")
        case .requested: return L("Requesting Control…")
        case .active: return L("Release Control")
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
        WindowGroup(L("Tailscreen viewer")) {
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
            notes: {
                var notes: [String] = []
                // Only after a grant was refused — see `SharerModel.controlNote`.
                if let controlNote = sharer.controlNote { notes.append(controlNote) }
                // Said only while sharing, and only when true: the person this
                // would have reached is the one who has stopped looking at
                // this window, so they should be told before they do.
                if sharer.phase == .sharing && sharer.notificationsUnavailable {
                    notes.append(
                        L("No desktop notifications on this system — approvals appear here only."))
                }
                return notes
            }(),
            // The roster: who is watching, and what can be done about them.
            // `notes` is now free for statistics; a person is not a note.
            viewers: sharer.viewers.map { viewer in
                let stableID = viewer.stableID
                let remembered = gSharer.remembered(stableID: stableID)
                return HubViewerRow(
                    id: viewer.id,
                    label: viewer.label,
                    detail: viewer.health,
                    remembered: remembered.map { $0 == .allow ? .allowed : .blocked } ?? .none,
                    rememberIsDeferred: gSharer.isDeferred(rowID: viewer.id),
                    onKick: { gSharer.disconnect(viewer.id) },
                    onAlwaysAllow: {
                        gSharer.remember(
                            rowID: viewer.id, stableID: stableID, label: viewer.label,
                            policy: .allow)
                    },
                    onDenyAndBlock: {
                        gSharer.remember(
                            rowID: viewer.id, stableID: stableID, label: viewer.label,
                            policy: .deny)
                    },
                    onForget: { gSharer.forget(rowID: viewer.id, stableID: stableID) })
            },
            // Viewers parked at the approval gate. The shared card renders
            // these exactly like the Windows app's control requests, because
            // they are the same interaction and this window is the only place
            // either can be answered.
            prompts: sharer.pendingViewers.map {
                // `id` is the server's `"ip:port"` key, which is what
                // approve/deny take; the label is only what the row says.
                HubPrompt(
                    id: $0.id, message: L("\($0.label) wants to watch"),
                    acceptLabel: L("Accept"), declineLabel: L("Deny"))
            }
                // Somebody already watching, asking to drive. Second, because
                // a viewer at the gate has nothing on screen at all while this
                // person can at least see what is happening.
                + sharer.controlRequests.map {
                    HubPrompt(
                        id: $0.id.uuidString,
                        message: "\($0.displayName) wants to control this machine")
                }
                // Somebody asking this machine to start sharing. Third source
                // into one prompt list, and last on purpose: a viewer at the
                // gate is stuck on a Connecting placard with nothing on
                // screen, while an asker is merely waiting. The more blocked
                // person goes first.
                + sharer.shareRequests.map {
                    HubPrompt(
                        id: $0.id.uuidString,
                        message: L("\($0.fromHostname) wants you to share your screen"),
                        acceptLabel: L("Share"), declineLabel: L("Decline"))
                },
            settings: [
                HubToggle(
                    label: L("Require approval for new viewers"),
                    caption: sharer.requireApproval
                        ? nil
                        : L("Anyone on your tailnet who can reach this machine can watch."),
                    isOn: sharer.requireApproval,
                    set: { gSharer.setRequireApproval($0) })
            ],
            quality: HubQuality(
                settings: sharer.quality,
                isSharing: sharer.phase == .sharing,
                onChange: { gSharer.setQuality($0) }),
            // The only way to end a grant from this side. Named after the
            // person holding it, because "revoke control" does not say who
            // currently has it and that is the fact the sharer needs.
            extraAction: sharer.controlGrantedTo.map { holder in
                HubAction(label: L("Take back control from \(holder)")) {
                    gSharer.revokeControl()
                }
            },
            // Absent unless a capture device was actually opened for this
            // share, so a machine with no microphone shows no control rather
            // than one that cannot unmute.
            microphone: sharer.micAvailable
                ? HubMicrophone(isOn: sharer.micOn, toggle: { gSharer.toggleMic() })
                : nil,
            // Only while sharing: the overlay these tools drive exists for the
            // share's lifetime, and a tool armed against nothing would take the
            // screen over for no reason.
            drawing: sharer.phase == .sharing
                ? HubDrawing(
                    activeTool: sharer.activeTool,
                    inkColor: gSharer.drawing.color,
                    note: sharer.drawingNote,
                    selectTool: { gSharer.selectTool($0) },
                    undo: { gSharer.undoDrawing() },
                    clear: { gSharer.clearDrawing() })
                : nil,
            // Absent, not disabled, when this session has no portal: sharing
            // one window is a capability an X11-only desktop genuinely lacks,
            // and a greyed button would invite the question "why".
            secondaryStart: sharer.canShareWindow
                ? HubAction(
                    label: L("Share a window or app…"),
                    perform: { gSharer.startWindowShare() })
                : nil,
            // Only for a portal-backed share: an X11 session captures exactly
            // one thing, so there would be nothing to change.
            changeSource: sharer.canChangeSource && sharer.phase == .sharing
                ? HubAction(
                    label: L("Change source…"), perform: { gSharer.changeSource() })
                : nil,
            // What is actually on the wire, once a second. Only while
            // sharing: the model clears it on every teardown path, and this
            // second gate means a preview that somehow outlived its capture
            // still cannot be shown next to a Start button.
            preview: sharer.phase == .sharing
                ? sharer.preview.map {
                    HubPreview(width: $0.width, height: $0.height, rgba: $0.rgba)
                }
                : nil,
            onStart: { gSharer.startSharing() },
            onStop: { gSharer.stopSharing() },
            onAccept: { Self.answerPrompt($0, accept: true) },
            onDecline: { Self.answerPrompt($0, accept: false) })
    }

    /// Route a card prompt back to whichever feature raised it.
    ///
    /// Matched against the live pending list rather than by inspecting the
    /// id's shape. An `"ip:port"` and a UUID happen to be distinguishable
    /// today, and a dispatch leaning on that is one id-format change away from
    /// starting a share when somebody meant to admit a viewer. The Windows app
    /// learned this first and its `answerPrompt` says the same thing.
    @MainActor
    private static func answerPrompt(_ id: String, accept: Bool) {
        if gSharer.pendingViewers.contains(where: { $0.id == id }) {
            if accept {
                gSharer.approve(id)
            } else {
                gSharer.deny(id)
            }
            return
        }
        guard let requestID = UUID(uuidString: id) else { return }
        // Two UUID-shaped sources now share this id space, which is exactly
        // why the shape is never consulted: an ask to share and a request to
        // drive this machine are very different things to say yes to.
        if gSharer.controlRequests.contains(where: { $0.id == requestID }) {
            if accept {
                gSharer.grantControl(to: requestID)
            } else {
                gSharer.declineControl(requestID)
            }
            return
        }
        guard gSharer.shareRequests.contains(where: { $0.id == requestID }) else { return }
        gSharer.answerShareRequest(id: requestID, accept: accept)
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
                isOnline: sharer.isOnline, metadata: picker.shareInfo[sharer.id],
                route: sharer.route, latencyMs: picker.latencyMs[sharer.id],
                tags: sharer.tags)
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
                    // Session affordances, pinned at the bottom: talking and
                    // taking control. Each appears on its own capability — a
                    // sharer that cannot inject input does not hide the
                    // microphone, and a machine with no microphone does not
                    // hide Request Control.
                    if ui.micAvailable || ui.remoteControlAvailable {
                        VStack {
                            Spacer()
                            HStack(spacing: 8) {
                                if ui.micAvailable {
                                    MicrophoneButton(
                                        isOn: ui.micOn, failureNote: ui.micFailure,
                                        onToggle: { gVoice.toggle() })
                                }
                                if ui.remoteControlAvailable {
                                    RemoteControlBar(
                                        buttonLabel: controlButtonLabel,
                                        declinedReason: revokedReason,
                                        onToggle: { gControls.toggleControl() })
                                }
                            }
                            .padding(12)
                        }
                    }
                }
            }
        } else if ui.inSession {
            // A session is up but no video yet: connecting / awaiting approval /
            // declined / ended placard.
            VStack(spacing: 0) {
                ViewerHeader(subtitle: L("Viewer"))
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
                        askingIDs: picker.asking,
                        askNotes: picker.askOutcome,
                        // The chrome hands back the row's id rather than a
                        // transport type it deliberately does not import.
                        onSelect: { id in
                            guard let chosen = gPicker.sharers.first(where: { $0.id == id })
                            else { return }
                            gPicker.select(chosen)
                        },
                        onAskToShare: { id in
                            guard let chosen = gPicker.sharers.first(where: { $0.id == id })
                            else { return }
                            gPicker.askToShare(chosen)
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
