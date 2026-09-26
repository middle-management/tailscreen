import DefaultBackend
import Foundation
import SwiftCrossUI
import TailscreenHubUI
import TailscreenL10n
import TailscreenProtocol
import TailscreenViewer
import TailscreenViewerCore
import TailscreenViewerGtk
import TailscreenViewerTsnet

// Targeted: the mic seam only. A blanket `import TailscreenAudio` would pull
// OpusKit's re-exports into this file for two type names.
import protocol TailscreenAudio.MicrophoneCapturing
// Targeted for the same reason: one enum, to word a viewer's link state.
import enum TailscreenSharer.ViewerHealth

// tailscreen — native GTK desktop viewer.
//
//   tailscreen [<sharer-host> | tailscreen://join?token=…] [--join TOKEN] [--port N]
//              [--state-dir PATH] [--control-url URL]
//   tailscreen --render-self-test | --overlay-self-test | --overlay-input-self-test
//   tailscreen --outline-self-test
//   tailscreen --capture-backend-report
//   Env: TAILSCREEN_TS_AUTHKEY, TAILSCREEN_TS_CONTROL_URL
//
// With a host argument the viewer dials it directly. Without one it enters
// picker mode: brings the tsnet node up, discovers sharers on the tailnet,
// and shows a native list.
//
// The tsnet transport runs on the main actor as a Task that swift-cross-ui's
// RunLoop tick services, feeding frames into the shared FrameStore; `present`
// requests a GLArea repaint. `--render-self-test` is the headless CI render
// gate (no network): renders color bars, reads pixels back, exits.

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
// The system-wide mute hotkey. Built only on the live audio path.
var gMuteHotkey: PortableMuteHotkey?
// Account-menu actions, wired in picker mode (nil elsewhere → menu hidden).
var gSwitchProfile: (@MainActor @Sendable (String) -> Void)?
var gAddAccount: (@MainActor @Sendable () -> Void)?
// Return to the screen list after a session ends (picker mode); open the
// interactive-login URL in a browser. Wired in the picker block.
var gReturnToPicker: (@MainActor @Sendable () -> Void)?
var gOpenLogin: (@MainActor @Sendable () -> Void)?
// The welcome pane's sign-in button: bring the active profile's node up, or —
// when a restore already parked a login URL — open that page instead of
// starting a second bring-up behind it.
var gSignIn: (@MainActor @Sendable () -> Void)?
// Portable lifecycle for the current/most-recent viewer, matching macOS and
// Windows: row/address/token can't drift across parallel "last ..." slots.
var gViewerLifecycle = ViewerSessionLifecycle()
// Redial `gViewerLifecycle.target` (the ended/failed placard's Reconnect).
// Not `@Sendable`, unlike its neighbours: it captures non-Sendable state
// (the FFmpeg decoder, the audio sink) and only runs on the main actor.
var gReconnect: (@MainActor () -> Void)?
// Join a share-by-token session with a parsed token (the hub's join card).
var gJoinShare: (@MainActor (String) -> Void)?
let gArgs = Array(CommandLine.arguments.dropFirst())
let gSelfTest = gArgs.contains("--render-self-test")
// Headless SHARER gate: draw a known stroke on the annotation overlay and
// read the screen back through X11 capture. See OverlaySelfTest.
let gOverlaySelfTest = gArgs.contains("--overlay-self-test")
let gOverlayInputSelfTest = gArgs.contains("--overlay-input-self-test")
let gOutlineSelfTest = gArgs.contains("--outline-self-test")
// Which capture backend this machine would use, and why. Covers the wiring
// between the environment and `CaptureBackendSelection` that unit tests
// can't reach.
if gArgs.contains("--capture-backend-report") {
    CaptureBackendReport.run()
}
// Headless chrome preview: render the hub with fake data, no networking.
let gUIPreview = gArgs.contains("--ui-preview")
// The signed-out pane a first launch opens on. A modifier on the seeded
// preview, not its own branch, so it's the only difference between the two
// screenshots. Spelled like the macOS/WinUI equivalent.
let gUIPreviewWelcome = gArgs.contains("--ui-preview-welcome")
// True when launched with no host arg → the picker drives host selection.
var gPickerMode = false

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    let usage =
        "usage: tailscreen [<sharer-host> | tailscreen://join?token=…] [--join TOKEN]\n"
        + "       [--port N] [--no-audio] [--state-dir PATH] [--control-url URL]\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

/// Open a URL in the local browser (best-effort) — the same `xdg-open` hop
/// `gOpenLogin` takes.
@MainActor
func openInBrowser(_ urlString: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["xdg-open", urlString]
    try? process.run()
}

/// The sharer's playback sink for viewers' voices, opened on first use.
/// Separate from the viewer's `audioSink`: the two are alive at different
/// times (this app can share while not watching), and sharing one would let
/// a viewing session's teardown take the share's audio with it. A holder,
/// not a bare global, since top-level `var` can't carry a global actor.
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

func parseConfig() -> (
    config: ViewerConfig, host: String?, wantAudio: Bool, explicitStateDir: Bool,
    joinToken: String?
) {
    var args = gArgs
    var host: String?
    var port: UInt16 = NetworkConfig.tailscreenPort
    var wantAudio = true
    var explicitStateDir = false
    var statePath = FileManager.default.currentDirectoryPath + "/.tailscreen-state"
    var joinToken: String?
    let env = ProcessInfo.processInfo.environment
    var controlURL = env["TAILSCREEN_TS_CONTROL_URL"]
    let authKey = env["TAILSCREEN_TS_AUTHKEY"]

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--join":
            // Same inputs as the hub's join card (bare token or a
            // `tailscreen:` link). Mutually exclusive with a host.
            guard let value = args.first else { fail("--join needs a token or tailscreen: link") }
            guard let token = ShareLinkFormat.token(fromUserInput: value) else {
                fail("--join: that doesn't look like a share token or tailscreen: link")
            }
            joinToken = token
            args.removeFirst()
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
            // A scheme-handler launch (`Exec=tailscreen %u`) hands the clicked
            // link over positionally, so a `tailscreen:` URL is join input,
            // never a hostname.
            if arg.lowercased().hasPrefix("\(ShareLinkFormat.scheme):") {
                guard joinToken == nil else { fail("more than one join link — pass one") }
                guard let token = ShareLinkFormat.token(fromUserInput: arg) else {
                    fail("that doesn't look like a tailscreen: share link: \(arg)")
                }
                joinToken = token
            } else {
                guard host == nil else { fail("unexpected extra argument \(arg)") }
                host = arg
            }
        }
    }

    if joinToken != nil, host != nil {
        fail("--join and a host argument name two different sessions — pass one")
    }
    var config = ViewerConfig(hostname: host ?? "", port: port, authKey: authKey, statePath: statePath)
    if let controlURL { config.controlURL = controlURL }
    return (config, host, wantAudio, explicitStateDir, joinToken)
}

/// The transport's close reason as the UI's end reason. The wire carries ONE
/// deny byte for both a declined approval and a mid-session kick;
/// `wasAdmitted` (was an SSRC assigned) splits the wording, as on macOS.
func sessionEndReason(
    _ reason: ViewerCloseReason, wasAdmitted: Bool
) -> ViewerUIState.EndReason {
    switch reason {
    case .sharerStopped: return .sharerStopped
    case .timedOut: return .timedOut
    case .connectionLost: return .connectionLost
    case .deniedOrKicked: return wasAdmitted ? .disconnectedBySharer : .declined
    }
}

if gSelfTest {
    // Headless render gate: color bars the self-test verifies via
    // glReadPixels. No transport.
    gStore.set(makeColorBarsFrame())
} else if gOverlaySelfTest {
    // Scheduled, not run inline: needs the GTK main loop up to create a
    // window and service its repaint. Exits the process itself.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { OverlaySelfTest.run() }
} else if gOverlayInputSelfTest {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { OverlayInputSelfTest.run() }
} else if gOutlineSelfTest {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { OutlineSelfTest.run() }
} else if gUIPreview {
    // Headless chrome preview: seed the picker with fake sharers, no
    // networking, for screenshots under Xvfb.
    gPickerMode = true
    gPicker.phase = gUIPreviewWelcome ? .signedOut : .ready
    gSignIn = {}
    // Tagged and untagged, online and offline, so the filter menu has every
    // axis to show.
    gPicker.sharers = [
        DiscoveredSharer(id: "1", hostname: "robert-macbook", tailscaleIP: "100.64.0.12", isOnline: true),
        DiscoveredSharer(
            id: "2", hostname: "studio-imac", tailscaleIP: "100.64.0.31", isOnline: true,
            tags: ["tag:studio"]),
        DiscoveredSharer(
            id: "3", hostname: "living-room-tv", tailscaleIP: "100.64.0.44", isOnline: false,
            tags: ["tag:media"])
    ]
    // Show the whole seeded list regardless of what this machine persisted.
    gPicker.setFilter(.default, persist: false)
    gPicker.shareInfo = [
        "1": TailscreenMetadata(
            shareName: "robert's Screen", hostname: "robert-macbook",
            screenResolution: .init(width: 1920, height: 1080),
            isSharing: true, timestamp: Date(), videoCodec: .hevc)
    ]
    // Show the account menu in the preview (no-op actions).
    gSwitchProfile = { _ in }
    gAddAccount = {}
    // Render the "Join a Share…" card too (no-op), since the live idle hub
    // always offers it.
    gJoinShare = { _ in }
    // Jump straight to the video state so window-grows-to-video is
    // screenshot-reviewable.
    if gArgs.contains("--ui-preview-video") {
        // A 16:9 gradient stand-in, big enough for the annotation overlay to
        // be legible.
        gStore.set(makePreviewFrame(width: 960, height: 540))
        gViewerLifecycle.begin(
            ViewerSessionTarget(
                host: "100.64.0.12",
                displayName: "robert-macbook"
            )
        )
        gUIState.remoteControlAvailable = true
        gUIState.annotationsAvailable = true
        gUIState.openLinkAvailable = true
        gUIState.hasVideo = true
        gUIState.videoWidth = 1920
        gUIState.videoHeight = 1080
        gUIState.fps = 30
        gUIState.showStats = true
        gUIState.activeTool = .pen
        // One stroke per tool so the overlay + shape geometry are both visible.
        func seed(_ tool: AnnotationTool, _ points: [CGPoint], _ colorIndex: Int) {
            // Dated far ahead on purpose: `.click` is ephemeral (0.8s) and
            // would otherwise be swept before the screenshot's shutter fires.
            gAnnotations.apply(
                .add(
                    Annotation(
                        id: UUID(), tool: tool, points: points,
                        color: Annotation.RGBA.palette[colorIndex], width: 4)),
                nowNs: UInt64.max / 2)
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
    // The share card mid-share: preview thumbnail, drawing toolbar, a viewer
    // row with its remember/kick actions.
    if gArgs.contains("--ui-preview-sharing") {
        // A 16:10 gradient stand-in at the scaler's real output size.
        let (width, height) = (360, 225)
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * 4
                rgba[base] = UInt8(80 + (120 * x) / width)
                rgba[base + 1] = UInt8(90 + (100 * y) / height)
                rgba[base + 2] = 180
            }
        }
        gSharer.seedForUIPreview(
            preview: ThumbnailScaler.Thumbnail(width: width, height: height, rgba: rgba),
            // One healthy row and one not, so both dot colours show.
            viewers: [
                ConnectedViewer(
                    id: "100.64.0.12:52411", label: "robert-macbook",
                    stableID: "stable-1", health: .good),
                ConnectedViewer(
                    id: "100.64.0.44:39120", label: "living-room-tv",
                    stableID: "stable-2", health: .degraded)
            ],
            // One viewer parked at the gate, so the approval prompt is shown.
            pending: [
                PendingViewer(
                    id: "100.64.0.31:41822", label: "studio-imac", stableID: nil)
            ],
            micAvailable: true)
    }
} else {
    // Live path: reuse the tsnet transport, driving decoded frames into the
    // shared store. @MainActor, started as a Task, interleaved with the GTK
    // loop (swift-cross-ui ticks RunLoop.main).
    let (baseConfig, host, wantAudio, explicitStateDir, joinToken) = parseConfig()
    // Decided here, before anything reads it — must be set before
    // `transport.retainsNodeAcrossSessions` below, or the first viewing
    // session's teardown takes the sharer's borrowed node down with it.
    gPickerMode = host == nil && joinToken == nil
    let sink = GtkVideoSink(store: gStore, uiState: gUIState)
    let transport = TsnetTransport()
    // ALSA sink fronted by a background thread so its blocking device write
    // never runs on the GTK main thread. Best-effort: failure just drops to
    // video-only.
    var audioSink: AudioSink?
    if wantAudio {
        do {
            audioSink = try makeThreadedALSAAudioSink()
        } catch {
            FileHandle.standardError.write(Data("warning: audio disabled (\(error))\n".utf8))
        }
    }
    // Same best-effort rule, built once (not per session) since opening a
    // capture device is the slow, failable part. Nil means no mic control.
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
    // state machine. Relay finalized local annotation ops; apply relayed ops.
    gAnnotations.onLocalOp = { op in gAnnoForwarder.submit(op) }
    let backChannelHandlers = ViewerBackChannel.Handlers(
        onAnnotation: { op in gAnnotations.apply(op) },
        onControlGranted: { gUIState.setControlState(.active) },
        onControlRevoked: { reason in gUIState.setControlState(.revoked(reason: reason)) })

    // The sharer borrows this transport's node — one app, one tailnet
    // identity. `retainsNodeAcrossSessions` stops the node going down when a
    // viewing session ends and silently killing an in-progress share.
    transport.retainsNodeAcrossSessions = gPickerMode
    gSharer.nodeProvider = { transport.liveNode }
    // The sharer's own voice, handed over as closures so `SharerModel` names
    // no audio library. Factory opens at share start, releases at stop.
    if wantAudio {
        gSharer.microphoneFactory = { try makeALSAMicrophone() }
        // Kept for the process: an idle-but-open output device costs nothing,
        // and reopening it per share would stall Stop/Start.
        gSharer.playRemoteVoice = { pcm in SharerVoiceSink.shared.resolve()?.play(pcm) }
    }

    // Mute from outside the window: during a share this window sits behind
    // whatever's shown, exactly when muting matters most.
    if wantAudio {
        gMuteHotkey = makeMuteHotkeyController(
            sharerMicAvailable: { gSharer.micAvailable },
            viewerMicAvailable: { gUIState.micAvailable },
            toggleSharerMic: { gSharer.toggleMic() },
            toggleViewerMic: { gVoice.toggle() })
        // Mirror the chord's failure into the model the share card observes —
        // the controller's own report goes to stderr, which reaches nobody
        // mid-share.
        gMuteHotkey?.onUnavailabilityChange = { reason in
            gSharer.setMuteHotkeyUnavailability(reason)
        }
        gMuteHotkey?.start()
    }

    // Run a viewing session against a chosen host/IP. Shared by the
    // direct-host path, the picker's selection, and Reconnect. No timed
    // auto-return from an ended session — the explanation must stay readable
    // until the person acts.
    func startSession(host dialHost: String, displayName: String, guestToken: String? = nil) {
        var config = baseConfig
        if let guestToken {
            // The token names the relay and sharer, so everything
            // tailnet-related in `baseConfig` is inert.
            config = ViewerConfig(guestToken: guestToken)
        } else {
            config.hostname = dialHost
        }
        let sessionID = gViewerLifecycle.begin(
            ViewerSessionTarget(
                host: dialHost, displayName: displayName, guestToken: guestToken))
        sink.resetForNewSession()  // the sink outlives one session
        gStore.clear()
        gAnnotations.resetForNewSession()
        gUIState.beginSession()
        gUIState.setMicAvailable(false)
        // Set from the @Sendable onEnded callback; nil after `run` returns
        // means the USER ended it (Cancel / in-session Stop).
        final class EndedBox: @unchecked Sendable {
            var value: (reason: ViewerCloseReason, wasAdmitted: Bool)?
        }
        let ended = EndedBox()
        Task { @MainActor in
            // A fresh decoder per session (matching Windows/mac): no stale
            // codec context leaks across sessions.
            let decoder = FFmpegVideoDecoder()
            do {
                try await transport.run(
                    config: config, decoder: decoder, videoSink: sink,
                    audioSink: audioSink, shouldClose: { gUIState.closeRequested },
                    backChannelHandlers: backChannelHandlers,
                    microphone: microphone,
                    // `attach` publishes availability itself, off the latch.
                    onVoiceReady: { uplink in
                        guard gViewerLifecycle.isActive(sessionID) else { return }
                        gVoice.attach(uplink)
                    },
                    onBackChannelReady: { channel in
                        Task { @MainActor in
                            guard gViewerLifecycle.isActive(sessionID) else { return }
                            gControls.attach(channel)
                            gInput.attach(channel)
                            gAnnoForwarder.attach(channel)
                        }
                    },
                    onAdmitted: { caps in
                        Task { @MainActor in
                            guard gViewerLifecycle.markViewing(for: sessionID) else { return }
                            gUIState.setCaps(
                                remoteControl: caps.contains(.remoteControl),
                                annotations: caps.contains(.annotations),
                                openLink: caps.contains(.openLink))
                        }
                    },
                    onAwaitingApproval: {
                        Task { @MainActor in
                            guard gViewerLifecycle.markAwaitingApproval(for: sessionID) else {
                                return
                            }
                            gUIState.post(sessionPhase: .awaitingApproval)
                        }
                    },
                    onEnded: { reason, wasAdmitted in
                        ended.value = (reason, wasAdmitted)
                    },
                    // Decode-recovery ladder opt-in: drop the lazy libavcodec
                    // context so the next (fresh-keyframe) AU rebuilds it.
                    onDecoderResetNeeded: { decoder.reset() },
                    onDecodeFatal: {
                        guard gViewerLifecycle.isActive(sessionID) else { return }
                        // Say so over the frozen frame (`noteVideoStalled`
                        // owns that rule). Unlatch the sink first, so a later
                        // decode re-announces video and clears the banner.
                        sink.resetForNewSession()
                        gUIState.noteVideoStalled(
                            L(
                                "Video has stalled — decoding keeps failing and automatic recovery hasn't helped."
                            ))
                    })
                guard gViewerLifecycle.isCurrent(sessionID) else { return }
                FileHandle.standardError.write(Data("session ended\n".utf8))
                gVoice.detach()
                if let end = ended.value {
                    let reason = sessionEndReason(end.reason, wasAdmitted: end.wasAdmitted)
                    guard gViewerLifecycle.end(reason, for: sessionID) else { return }
                    gUIState.post(sessionPhase: .ended(reason))
                } else if gPickerMode {
                    // The user ended it — no explanation owed, straight back.
                    guard gViewerLifecycle.dismiss(ifCurrent: sessionID) else { return }
                    gReturnToPicker?()
                } else {
                    // Direct-host mode has no list; rest on the status pane.
                    guard gViewerLifecycle.dismiss(ifCurrent: sessionID) else { return }
                    gUIState.returnToPickerState()
                    gUIState.post(status: L("Session Ended"))
                }
            } catch {
                guard gViewerLifecycle.fail(L("Connection failed"), for: sessionID) else { return }
                FileHandle.standardError.write(Data("session failed: \(error)\n".utf8))
                gVoice.detach()
                gUIState.post(sessionPhase: .failed(L("Connection failed")))
            }
        }
    }

    // The ended/failed placard's Reconnect: redial whoever this session (or
    // the last one) dialed. Not the picker's row callback: the peer may have
    // dropped off the refreshed list while their share merely restarted.
    gReconnect = {
        guard let target = gViewerLifecycle.target else { return }
        startSession(
            host: target.host, displayName: target.displayName,
            guestToken: target.guestToken)
    }

    // The hub's join card (and `--join`): a guest session by parsed token.
    gJoinShare = { token in
        startSession(host: "", displayName: L("Shared screen"), guestToken: token)
    }

    if let host {
        // Direct connect — a host was named on the command line.
        startSession(host: host, displayName: host)
    } else if let joinToken {
        // Direct guest connect — a token was named on the command line.
        startSession(host: "", displayName: L("Shared screen"), guestToken: joinToken)
    } else {
        // Picker mode: bring the node up, discover sharers, let the user
        // choose. Dials the tailnet IP, not the hostname, sidestepping the
        // `from == dest` hostname-match limitation.
        gPicker.onSelect = { sharer in
            startSession(host: sharer.tailscaleIP, displayName: sharer.displayName)
        }
        // Ask a machine to start sharing. Parks for up to two minutes on the
        // far side; nothing here awaits it inline, so the window stays usable.
        gPicker.onAskToShare = { sharer in
            let id = sharer.id
            let ip = sharer.tailscaleIP
            gPicker.beginAsking(id)
            Task { @MainActor in
                let outcome = await transport.requestToShare(ip: ip, from: localShareName())
                switch outcome {
                case .accepted:
                    gPicker.finishAsking(
                        id, outcome: L("Accepted — they're choosing what to share"))
                case .declined:
                    gPicker.finishAsking(id, outcome: L("Declined"))
                case .noAnswer:
                    // One wording for away/closed/too-old, since the asker
                    // can't act on the difference.
                    gPicker.finishAsking(id, outcome: L("No reply"))
                }
            }
        }

        // Discover sharers on the live node, then sweep their live share
        // status concurrently. Reused by the initial bring-up and Refresh.
        @Sendable func discoverAndSweep() {
            Task { @MainActor in
                do {
                    gPicker.phase = .discovering
                    let peers = try await transport.discoverPeers()
                    // Raw and unfiltered, for the header filter to project
                    // from. Only the metadata sweep stays online-only: dialing
                    // a machine tsnet says is down buys nothing but a timeout.
                    gPicker.sharers = peers
                    let online = peers.filter { $0.isOnline }
                    // Prune share status for peers no longer online, or a
                    // returning id shows a stale "Sharing" chip until its next
                    // probe lands.
                    gPicker.shareInfo = PeerShareStatusMap.pruned(
                        gPicker.shareInfo, toPresent: Set(online.map(\.id)))
                    // Set before `.ready`, so the placard never flashes the
                    // old guidance text.
                    gPicker.tailnetName = transport.tailnetName
                    gPicker.accountIdentity = transport.accountIdentity
                    gPicker.phase = .ready
                    // Idempotent per node, so the 10s auto-refresh also
                    // re-points it after a profile switch.
                    gSharer.ensureControlListener()
                    // One dial, not two: the sharing chip + resolution and the
                    // route's latency come off the same probe.
                    await withTaskGroup(of: (String, PeerProbe).self) { group in
                        for sharer in online {
                            group.addTask { (sharer.id, await transport.probePeer(ip: sharer.tailscaleIP)) }
                        }
                        for await (id, probe) in group {
                            // No answer CLEARS the chip rather than keeping
                            // the last one — see `PeerShareStatusMap`.
                            gPicker.shareInfo = PeerShareStatusMap.recording(
                                probe.metadata, for: id, in: gPicker.shareInfo)
                            gPicker.latencyMs[id] = probe.latencyMs
                        }
                    }
                } catch {
                    FileHandle.standardError.write(Data("discovery failed: \(error)\n".utf8))
                    gPicker.phase = .ready  // renders "No screens found"
                }
            }
        }
        gPicker.onRefresh = { discoverAndSweep() }

        // Quiet auto-refresh: re-list every 10s without flipping to the
        // "discovering…" placard. Skips while a session/bring-up is in
        // flight.
        @Sendable func quietRefresh() {
            Task { @MainActor in
                guard gPicker.phase.isReady else { return }
                guard let peers = try? await transport.discoverPeers() else { return }
                guard gPicker.phase.isReady else { return }  // re-check after await
                gPicker.sharers = peers
                let online = peers.filter { $0.isOnline }
                gPicker.shareInfo = PeerShareStatusMap.pruned(
                    gPicker.shareInfo, toPresent: Set(online.map(\.id)))
                await withTaskGroup(of: (String, PeerProbe).self) { group in
                    for sharer in online {
                        group.addTask { (sharer.id, await transport.probePeer(ip: sharer.tailscaleIP)) }
                    }
                    // Same rule as `discoverAndSweep`: a no-answer is
                    // status-unknown, so it clears rather than keeping the
                    // last chip; see `PeerShareStatusMap`.
                    for await (id, probe) in group {
                        gPicker.shareInfo = PeerShareStatusMap.recording(
                            probe.metadata, for: id, in: gPicker.shareInfo)
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
            gViewerLifecycle.dismiss()
            gUIState.returnToPickerState()
            gAnnotations.resetForNewSession()
            gPicker.endDialing()
            // A signed-out link guest has no node and no list; send them back
            // to the pane they came from instead of an empty Screens list.
            guard transport.liveNode != nil else {
                gPicker.phase = .signedOut
                return
            }
            gPicker.phase = .ready
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

        /// Has this profile ever signed in? Distinguishes "restore the
        /// session I already have" from "start a login nobody asked for" —
        /// an empty state dir means a first launch that shouldn't emit a
        /// browser login URL unprompted.
        @Sendable func hasSavedLogin(_ profile: ViewerProfile) -> Bool {
            let path = stateDir(for: profile)
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            return !contents.isEmpty
        }

        // Bring up (or switch to) a profile: tear the current node down, reset
        // the picker, prepare under the profile's state dir, then discover.
        // `restoring` is the silent half (a launch reviving a saved session);
        // if it turns out to need the browser after all, the pane goes back
        // to signed-out carrying the URL rather than starting a second
        // bring-up behind the parked one.
        @Sendable func bringUp(
            profile: ViewerProfile, restoring: Bool = false, switching: Bool = false
        ) {
            Task { @MainActor in
                await transport.teardown()
                gPicker.loginURL = nil
                gPicker.sharers = []
                gPicker.shareInfo = [:]
                gPicker.endDialing()
                // Set on every path so a plain sign-in after a switch clears
                // it rather than inheriting the last one's word.
                gPicker.isSwitchingAccount = switching
                gPicker.phase = .startingNode
                var config = baseConfig
                config.statePath = stateDir(for: profile)
                // Register under a discoverable name when this host can
                // share, same as macOS (idle vs. sharing is told apart by the
                // metadata probe, not by hiding idle nodes).
                if gSharer.canShare {
                    config.nodeRole = .shareCapable(name: localShareName())
                }
                do {
                    try await transport.prepare(
                        config: config,
                        onLoginURL: { url in
                            Task { @MainActor in
                                gPicker.loginURL = url.absoluteString
                                guard restoring else { return }
                                // The saved state didn't authenticate; say so
                                // rather than sit on an unstarted login.
                                gPicker.phase = .failed(
                                    L("Your saved Tailscale sign-in needs renewing."))
                            }
                        })
                    gPicker.loginURL = nil
                    // Label the account by its resolved login once known.
                    if let identity = transport.accountIdentity {
                        gProfiles.rename(profile.id, to: identity)
                    }
                    discoverAndSweep()
                } catch {
                    FileHandle.standardError.write(Data("node bring-up failed: \(error)\n".utf8))
                    gPicker.phase = .failed(L("Could not start Tailscale: \(error)"))
                }
            }
        }

        // Account-menu actions.
        gSwitchProfile = { id in
            guard id != gProfiles.activeID else { return }
            gProfiles.setActive(id)
            bringUp(profile: gProfiles.active, switching: true)
        }
        gAddAccount = {
            bringUp(profile: gProfiles.addProfile(), switching: true)
        }
        // A parked login URL means a node is already blocked waiting on that
        // page — open it rather than queue a second bring-up behind it.
        gSignIn = {
            if gPicker.loginURL != nil {
                gPicker.isSwitchingAccount = false
                gPicker.phase = .startingNode
                gOpenLogin?()
                return
            }
            bringUp(profile: gProfiles.active)
        }
        // A share started from the welcome pane is link-only. Only there:
        // mid-bring-up the node is nil too, and Start then means "share on
        // my tailnet".
        gSharer.linkOnlyShareAllowed = { gPicker.phase.isSignedOut }

        // Restore a saved session, or sit on the welcome pane — never an
        // unconditional bring-up, so a first launch doesn't meet the person
        // with an unrequested login.
        if hasSavedLogin(gProfiles.active) {
            bringUp(profile: gProfiles.active, restoring: true)
        }
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
    private var showingPickerList: Bool { picker.phase.isReady }

    /// The tailnet card's body copy: the pitch by default, or whatever went
    /// wrong.
    private var welcomeTailnetMessage: String {
        picker.signInNote
            ?? L(
                "Every Tailscreen on your tailnet, listed by name — connect with one click, no link to pass around."
            )
    }

    /// The pane's join handler, absent (so the field is not drawn) in
    /// previews and self-tests.
    private var welcomeJoin: (@MainActor @Sendable (String) -> Void)? {
        guard gJoinShare != nil else { return nil }
        return { token in gJoinShare?(token) }
    }

    /// What the pane's share-link card offers, given this host's three flags.
    /// `.failed` counts as idle: `startSharing()` accepts it, and a dead-end
    /// reason with no retry button would need quitting the app.
    private var welcomeShareAction: WelcomePaneDecision.LinkShareAction {
        WelcomePaneDecision.linkShareAction(
            canShare: sharer.canShare,
            isIdle: sharer.phase.canStart,
            isLinkOnlyShare: sharer.isLinkOnlyShare)
    }

    /// …and its button. A parked login URL means the page is already waiting
    /// to be opened, different from starting a sign-in.
    private var welcomeButtonLabel: String {
        if picker.loginURL != nil { return L("Open the sign-in page") }
        return picker.phase.hasFailed ? L("Try again") : L("Sign in with Tailscale")
    }

    // Header subtitle: the picker's progress line, or the direct-connect status.
    private var headerSubtitle: String {
        gPickerMode ? picker.statusLine : ui.status
    }

    // A spinner rides the header while the node is coming up / discovering.
    private var headerShowsSpinner: Bool {
        gPickerMode && picker.phase.isBringingUp
    }

    // Captures the module-global `gPicker` (Sendable) rather than `self` so
    // the closure satisfies the Button action's `@MainActor @Sendable` type.
    private var headerOnRefresh: (@MainActor @Sendable () -> Void)? {
        guard gPickerMode && showingPickerList else { return nil }
        return { gPicker.refresh() }
    }

    /// The peer-list filter, offered from the same settled picking state as
    /// Refresh.
    private var headerFilter: HubFilter? {
        guard gPickerMode && showingPickerList else { return nil }
        return HubFilter(
            filter: picker.filter,
            tags: picker.knownTags,
            onChange: { gPicker.setFilter($0) })
    }

    var body: some Scene {
        // Plain "Tailscreen", matching the Windows app: this window is the hub
        // (sharer + viewer), not just a viewer, and brand nouns stay
        // unlocalized (see .claude/rules/localization.md).
        WindowGroup("Tailscreen") {
            rootView
        }
        // Opens hub-narrow (the picker is a single column, like the mac hub);
        // GtkVideoView grows the window to the video's size on the first frame.
        .defaultSize(width: 460, height: 680)
    }

    /// The window's content: the headless render self-test surface, live video
    /// with its remote-control bar, or the hub chrome before video.
    /// `GtkVideoView` is mounted only when there's something to show, so the
    /// hub chrome sits on the native GTK background rather than a black GL
    /// surface.
    // The host this session dialed, for the placard and watching bar —
    // `startSession` sets this synchronously before any re-render.
    private var sessionHost: String {
        gViewerLifecycle.target?.displayName ?? ""
    }

    /// The viewer's session state as the shared placard's phase.
    private static func hubPhase(_ phase: ViewerUIState.SessionPhase) -> HubSessionPhase {
        phase
    }

    /// The server's viewer health as the chrome's — case for case, so
    /// TailscreenHubUI draws the roster without importing the sharer tier.
    /// The Windows app carries the twin of this; the wording that would
    /// actually drift is written once, in `HubViewerHealth.note`.
    private static func hubHealth(_ health: ViewerHealth) -> HubViewerHealth {
        switch health {
        case .good: return .good
        case .degraded: return .degraded
        case .throttled: return .throttled
        }
    }

    /// Reconnect for the ended/failed placard — absent (nil) when nothing was
    /// ever dialed, e.g. the `--ui-preview` chrome shots.
    private var placardReconnect: (@MainActor @Sendable () -> Void)? {
        guard gViewerLifecycle.target != nil, gReconnect != nil else { return nil }
        return { gReconnect?() }
    }

    /// Back to the screen list — picker mode only; the direct-host CLI has no
    /// list to go back to, so the button is absent rather than dead.
    private var placardBack: (@MainActor @Sendable () -> Void)? {
        guard gPickerMode else { return nil }
        return { gReturnToPicker?() }
    }

    /// Sitting on the welcome pane — no node, no login in flight. A FAILED
    /// bring-up counts: `welcomeButtonLabel` relabels the same pane's button.
    private var isSignedOut: Bool { picker.phase.isSignedOut }

    /// A share running with nobody signed in — replaces the welcome pane.
    /// `.failed` deliberately NOT here: that has no share to show, and the
    /// reason goes to the pane's share-link card instead (`welcomeShareNote`).
    private var showingSignedOutShare: Bool {
        guard gPickerMode, isSignedOut else { return false }
        return sharer.phase == .starting || sharer.phase == .sharing
    }

    /// Whether the hub column renders the welcome pane rather than the
    /// picker. Hoisted out of the view body: a pattern match inside a
    /// multi-condition `if` in this result builder fails to typecheck.
    private var showingWelcome: Bool { gPickerMode && isSignedOut && !showingSignedOutShare }

    /// The live share, alone, in the hub's own column — signed out, this is
    /// the only surface the share's link/roster/approvals could be on.
    @ViewBuilder private var signedOutSharingColumn: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let shareCard {
                    shareCard
                }
            }
            .frame(maxWidth: HubStyle.contentMaxWidth)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A link-only start that failed, worded for the card that offered it.
    /// Nil otherwise, including while one is running.
    private var welcomeShareNote: String? {
        guard case .failed = sharer.phase else { return nil }
        return sharer.statusLine
    }

    /// The hub's sharing card. Only offered in picker mode: the direct-host
    /// path is a one-shot viewer invocation.
    private var shareCard: ShareCard? {
        guard gPickerMode else { return nil }
        return ShareCard(
            statusLine: sharer.statusLine,
            statusDetail: sharer.statusDetail,
            isSharing: sharer.phase == .sharing,
            isStarting: sharer.phase == .starting,
            canShare: sharer.canShare,
            // Signed out, the button says what it will do: no tailnet, so
            // the share comes up over the guest tunnel with its link as the
            // only way in.
            startLabel: isSignedOut ? L("Share your screen via Link…") : L("Share my screen"),
            notes: {
                var notes: [String] = []
                if let controlNote = sharer.controlNote { notes.append(controlNote) }
                // The share it failed to re-point is still running, so a note
                // rather than a phase — see `SharerModel.sourceChangeNote`.
                if let sourceNote = sharer.sourceChangeNote { notes.append(sourceNote) }
                // Said only while sharing, so the sharer is told before they
                // stop looking at this window. Splits "no daemon" from
                // "daemon drops buttons" like the Windows card does.
                if sharer.phase == .sharing && sharer.notificationsUnavailable {
                    notes.append(
                        L("No desktop notifications on this system — approvals appear here only"))
                } else if sharer.phase == .sharing && sharer.notificationsLackActions {
                    notes.append(
                        L(
                            "This desktop's notifications can't show buttons — answer approvals in this window"
                        ))
                }
                // The mute chord's failure, said beside the mic it would have
                // muted.
                if sharer.micAvailable, let hotkey = gMuteHotkey,
                    let reason = sharer.muteHotkeyUnavailability
                {
                    notes.append(
                        MuteHotkeyNote.text(
                            chord: hotkey.chordDisplay, unavailability: reason))
                }
                return notes
            }(),
            // The roster: who is watching, and what can be done about them.
            viewers: sharer.viewers.map { Self.hubViewerRow($0) },
            // Viewers parked at the approval gate, rendered like the Windows
            // app's control requests (same interaction).
            prompts: sharer.pendingViewers.map {
                // `id` is the server's `"ip:port"` key, which approve/deny take.
                HubPrompt(
                    id: $0.id, message: L("\($0.label) wants to watch"),
                    acceptLabel: L("Accept"), declineLabel: L("Deny"),
                    isGuest: $0.isGuest)
            }
                // Somebody already watching, asking to drive. Second, because
                // a viewer at the gate has nothing on screen at all while this
                // person can at least see what is happening.
                + sharer.controlRequests.map {
                    HubPrompt(
                        id: $0.id.uuidString,
                        message: "\($0.displayName) wants to control this machine")
                }
                // Last on purpose: a viewer at the gate is stuck on a blank
                // Connecting placard, while an asker is merely waiting.
                + sharer.shareRequests.map {
                    HubPrompt(
                        id: $0.id.uuidString,
                        message: L("\($0.fromHostname) wants you to share your screen"),
                        acceptLabel: L("Share"), declineLabel: L("Decline"))
                }
                // A link offer, last: nothing is stuck waiting on it, and the
                // whole URL rides in `detail` since a banner might truncate it.
                + sharer.linkOffers.map {
                    HubPrompt(
                        id: $0.id.uuidString, message: L("\($0.displayName) sent a link"),
                        detail: $0.url, acceptLabel: L("Open"), declineLabel: L("Dismiss"))
                },
            // The approval gate governs TAILNET viewers; a link-only share
            // has none (every viewer is a guest, always parked for explicit
            // approval), so showing it would be a switch wired to nothing.
            settings: sharer.isLinkOnlyShare
                ? []
                : [
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
            // Named after the person holding it, since "revoke control" alone
            // doesn't say who currently has it.
            extraAction: sharer.controlGrantedTo.map { holder in
                HubAction(label: L("Take back control from \(holder)")) {
                    gSharer.revokeControl()
                }
            },
            // Absent unless a capture device was actually opened, so a
            // machine with no microphone shows no control at all.
            microphone: sharer.micAvailable
                ? HubMicrophone(isOn: sharer.micOn, toggle: { gSharer.toggleMic() })
                : nil,
            // Only while sharing: the overlay these tools drive exists for
            // the share's lifetime.
            drawing: sharer.phase == .sharing
                ? HubDrawing(
                    activeTool: sharer.activeTool,
                    inkColor: gSharer.drawing.color,
                    note: sharer.drawingNote,
                    selectTool: { gSharer.selectTool($0) },
                    undo: { gSharer.undoDrawing() },
                    clear: { gSharer.clearDrawing() })
                : nil,
            // Absent, not disabled, when this session has no portal: an
            // X11-only desktop genuinely lacks this capability.
            secondaryStart: sharer.canShareWindow
                ? HubAction(
                    label: L("Share a window or app…"),
                    perform: { gSharer.startWindowShare() })
                : nil,
            // Only for a portal-backed share: an X11 session captures exactly
            // one thing.
            changeSource: sharer.canChangeSource && sharer.phase == .sharing
                ? HubAction(
                    label: L("Change source…"), perform: { gSharer.changeSource() })
                : nil,
            // Only while sharing, so a preview that somehow outlived its
            // capture can't show next to a Start button.
            preview: sharer.phase == .sharing
                ? sharer.preview.map {
                    HubPreview(width: $0.width, height: $0.height, rgba: $0.rgba)
                }
                : nil,
            linkSharing: hubLinkSharing,
            onStart: { gSharer.startSharing() },
            onStop: { gSharer.stopSharing() },
            onAccept: { Self.answerPrompt($0, accept: true) },
            onDecline: { Self.answerPrompt($0, accept: false) })
    }

    /// One roster row. A method, not an inline closure, since the guest
    /// branch (badge on, remember-actions off — those persist under a
    /// StableNodeID a guest never has) doubles the ternaries.
    @MainActor
    private static func hubViewerRow(_ viewer: ConnectedViewer) -> HubViewerRow {
        let stableID = viewer.stableID
        if viewer.isGuest {
            return HubViewerRow(
                id: viewer.id,
                label: viewer.label,
                health: hubHealth(viewer.health),
                onKick: { gSharer.disconnect(viewer.id) },
                isGuest: true)
        }
        let remembered = gSharer.remembered(stableID: stableID)
        return HubViewerRow(
            id: viewer.id,
            label: viewer.label,
            health: hubHealth(viewer.health),
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
    }

    /// The card's share-by-token half, live only while sharing.
    private var hubLinkSharing: HubLinkSharing? {
        guard sharer.phase == .sharing else { return nil }
        let guests =
            sharer.viewers.filter(\.isGuest).count
            + sharer.pendingViewers.filter(\.isGuest).count
        // Hoisted with explicit types: @MainActor @Sendable closure inference
        // inside one init call sinks the Swift 6 typechecker on Linux.
        let toggle: @MainActor @Sendable (Bool) -> Void = { gSharer.setLinkSharing($0) }
        var newLink: (@MainActor @Sendable () -> Void)?
        if sharer.linkToken != nil {
            newLink = { gSharer.rotateLink() }
        }
        return HubLinkSharing(
            token: sharer.linkToken,
            busy: sharer.linkBusy,
            guestCount: guests,
            // A link-only share has no off position short of Stop Sharing.
            isOnlyWayIn: sharer.isLinkOnlyShare,
            onToggle: toggle,
            onNewLink: newLink,
            onCopy: { copyToClipboard($0) })
    }

    /// Route a card prompt back to whichever feature raised it. Matched
    /// against the live pending list, never by inspecting the id's shape —
    /// an `"ip:port"` and a UUID are distinguishable today, but leaning on
    /// that is one id-format change from admitting a viewer when someone
    /// meant to start a share.
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
        // Two UUID-shaped sources share this id space, which is why the shape
        // is never consulted.
        if gSharer.controlRequests.contains(where: { $0.id == requestID }) {
            if accept {
                gSharer.grantControl(to: requestID)
            } else {
                gSharer.declineControl(requestID)
            }
            return
        }
        if gSharer.shareRequests.contains(where: { $0.id == requestID }) {
            gSharer.answerShareRequest(id: requestID, accept: accept)
            return
        }
        guard gSharer.linkOffers.contains(where: { $0.id == requestID }) else { return }
        if accept {
            gSharer.openLinkOffer(requestID)
        } else {
            gSharer.dismissLinkOffer(requestID)
        }
    }

    /// The picker's discovered machines as hub rows, with the metadata
    /// sweep's answer folded in. Built from the FILTERED projection;
    /// `picker.sharers` stays raw for the tag menu.
    private var hubScreens: [HubScreen] {
        picker.filteredSharers.map { sharer in
            HubScreen(
                id: sharer.id, hostname: sharer.hostname, tailscaleIP: sharer.tailscaleIP,
                isOnline: sharer.isOnline, metadata: picker.shareInfo[sharer.id],
                route: sharer.route, latencyMs: picker.latencyMs[sharer.id],
                tags: sharer.tags)
        }
    }

    /// The share-by-token way in, when the live block wired it (nil in
    /// previews/self-tests, which hides the card).
    private var hubJoinCard: HubJoinCard? {
        guard gJoinShare != nil else { return nil }
        return HubJoinCard(onJoin: { token in gJoinShare?(token) })
    }

    @ViewBuilder private var rootView: some View {
        if gSelfTest {
            GtkVideoView(store: gStore, selfTest: true)
        } else if ui.inSession && ui.sessionIsOver {
            // Checked BEFORE `hasVideo`: once video has flowed, `hasVideo`
            // stays set, so a finished session would otherwise render as a
            // frozen frame with the explanation unreachable underneath.
            VStack(spacing: 0) {
                ViewerHeader(subtitle: L("Viewer"))
                Divider()
                SessionPlacard(
                    phase: Self.hubPhase(ui.sessionPhase),
                    host: sessionHost,
                    onReconnect: placardReconnect,
                    onBack: placardBack)
            }
        } else if ui.hasVideo {
            // Toolbar ROW above the video, then the video with its overlays.
            VStack(spacing: 0) {
                // Who is being watched, and the one way to leave from this
                // side (the transport's `shouldClose` polls `closeRequested`).
                HStack(spacing: 8) {
                    Text(L("Watching \(sessionHost)"))
                        .font(.caption)
                        .foregroundColor(HubStyle.secondaryText)
                    Spacer()
                    Button(L("Stop")) { gUIState.requestSessionClose() }
                }
                .padding(.horizontal, 16)
                .frame(height: Double(HubStyle.toolbarHeight))
                .frame(maxWidth: .infinity)
                .background(HubStyle.barFill)
                Divider()
                // Something to say about a session that is still going
                // (today: the decode-stall ladder's last rung). A strip, not
                // a placard, so the picture underneath stays untouched.
                if let notice = ui.notice {
                    ViewerNoticeBanner(message: notice) { gUIState.notice = nil }
                    Divider()
                }
                if ui.annotationsAvailable {
                    AnnotationToolbar(
                        activeTool: ui.activeTool,
                        inkColor: ui.inkColor ?? gAnnotations.color,
                        statsShown: ui.showStats,
                        onSelectTool: { tool in
                            // Click-the-selected-tool disarms, since a Linux
                            // viewer still needs plain drags for zoom/pan.
                            let disarm = gUIState.activeTool == tool
                            gUIState.activeTool = disarm ? nil : tool
                            gAnnotations.mode = disarm ? .off : .drawing(tool)
                        },
                        onSelectColor: { color in
                            // The store is what strokes read; the published
                            // mirror is what re-renders the swatch.
                            gAnnotations.color = color
                            gUIState.inkColor = color
                        },
                        onUndo: { gAnnotations.undo() },
                        onClear: { gAnnotations.clearAll() },
                        onToggleStats: { gUIState.showStats.toggle() })
                    Divider()
                }
                ZStack {
                    GtkVideoView(
                        store: gStore, onInputEvent: { gInput.submit($0) },
                        // The wheel has a local fallback (zoom), so the view
                        // asks the gate itself rather than `submit` dropping
                        // it silently.
                        forwardsInput: { gUIState.forwardsRemoteInput },
                        annotations: gAnnotations,
                        chromeHeight: ui.annotationsAvailable ? HubStyle.toolbarHeight : 0)
                    // Stats HUD, pinned top-left, toggleable from the toolbar.
                    if ui.showStats {
                        VStack {
                            HStack {
                                StatsHUD(
                                    width: ui.videoWidth, height: ui.videoHeight, fps: ui.fps,
                                    colorLabel: ui.videoColorLabel)
                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(10)
                    }
                    // Session affordances, pinned at the bottom. Each appears
                    // on its own capability, independently.
                    if ui.micAvailable || ui.remoteControlAvailable || ui.openLinkAvailable {
                        VStack {
                            Spacer()
                            HStack(spacing: 8) {
                                if ui.micAvailable {
                                    MicrophoneButton(
                                        isOn: ui.micOn, failureNote: ui.micFailure,
                                        chordHint: gMuteHotkey?.chordHint,
                                        onToggle: { gVoice.toggle() })
                                }
                                if ui.remoteControlAvailable {
                                    RemoteControlBar(
                                        buttonLabel: controlButtonLabel,
                                        declinedReason: revokedReason,
                                        isControlling: ui.controlState == .active,
                                        controllingHost: sessionHost.isEmpty
                                            ? nil : sessionHost,
                                        onToggle: { gControls.toggleControl() })
                                }
                                if ui.openLinkAvailable {
                                    OpenLinkControl(
                                        isOpen: ui.openLinkComposerOpen,
                                        text: $ui.openLinkText,
                                        error: ui.openLinkError,
                                        sent: ui.openLinkSent,
                                        onOpen: { gControls.openLinkComposer() },
                                        onSend: { gControls.sendLink() },
                                        onCancel: { gControls.cancelLinkComposer() })
                                }
                            }
                            .padding(12)
                        }
                    }
                }
            }
        } else if ui.inSession {
            // Connecting / awaiting-approval placard, with a working Cancel.
            VStack(spacing: 0) {
                ViewerHeader(subtitle: L("Viewer"))
                Divider()
                SessionPlacard(
                    phase: Self.hubPhase(ui.sessionPhase),
                    host: sessionHost,
                    onCancel: { gUIState.requestSessionClose() })
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
                if showingWelcome {
                    // Nothing brought up yet. Offers sign-in, plus the two
                    // paths that need no account: joining or minting a link.
                    HubSignInPane(
                        tailnetMessage: welcomeTailnetMessage,
                        signInLabel: welcomeButtonLabel,
                        onSignIn: { gSignIn?() },
                        onJoin: welcomeJoin,
                        shareAction: welcomeShareAction,
                        onShare: { gSharer.startSharing() },
                        shareNote: welcomeShareNote)
                } else if showingSignedOutShare {
                    // Signed out WITH a share running: the sharing view owns
                    // the window until it stops.
                    signedOutSharingColumn
                } else if gPickerMode {
                    PickerContent(
                        statusLine: picker.statusLine,
                        isPicking: showingPickerList,
                        // Placeholder rows while a list is being built; the
                        // quiet 10s re-list never enters `.discovering` and so
                        // never blanks anything.
                        isDiscovering: picker.phase == .discovering,
                        screens: hubScreens,
                        loginURL: picker.loginURL,
                        autoExpandFirst: gUIPreview,
                        // The empty list's way out. Same link/key as macOS.
                        emptyAction: HubAction(
                            label: L("Get Tailscreen for your other devices"),
                            perform: { openInBrowser("https://tailscreen.dev/install/") }),
                        hiddenByFilter: picker.hiddenByFilter,
                        askingIDs: picker.asking,
                        askNotes: picker.askOutcome,
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
                        shareCard: shareCard,
                        joinCard: hubJoinCard)
                } else {
                    HubStatusPane(status: ui.status)
                }
            }
        }
    }
}

// Open the session record before the UI comes up, so a bundle starts with the
// build stamp. See .claude/rules/diagnostics.md; `TAILSCREEN_DIAGNOSTICS=1`/
// `=0` forces it (no settings toggle on this host yet).
DiagnosticsHost.start(environment: BuildInfo.diagnosticsEnvironment)

ViewerApp.main()
