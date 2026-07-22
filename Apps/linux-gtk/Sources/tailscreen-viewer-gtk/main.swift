import DefaultBackend
import Foundation
import SwiftCrossUI
import TailscreenProtocol
import TailscreenViewer
import TailscreenViewerCore
import TailscreenViewerGtk
import TailscreenViewerTsnet

// tailscreen-viewer-gtk — native GTK desktop viewer.
//
//   tailscreen-viewer-gtk [<sharer-host>] [--port N] [--state-dir PATH] [--control-url URL]
//   tailscreen-viewer-gtk --render-self-test
//   Env: TAILSCREEN_TS_AUTHKEY, TAILSCREEN_TS_CONTROL_URL
//
// With a host argument the viewer dials it directly. WITHOUT one it enters
// picker mode: it brings the tsnet node up, discovers Tailscreen sharers on the
// tailnet, and shows a native list to choose from (L4).
//
// The window shows decoded video via the downstream GtkVideoView. The tsnet
// transport (reused from Apps/linux) runs on the main actor as a Task that
// swift-cross-ui's RunLoop tick services, feeding frames into the shared
// FrameStore; `present` (main thread) requests a GLArea repaint. The live tsnet
// leg is local-only. `--render-self-test` is the headless CI render gate (no
// network): it renders a colour-bars frame, reads the pixels back, and exits.

// swift-cross-ui's `App.main()` default-constructs the app, so shared state
// lives at module scope.
let gStore = FrameStore()
let gUIState = ViewerUIState()
let gControls = ViewerControls(ui: gUIState)
let gPicker = PickerModel()
let gArgs = Array(CommandLine.arguments.dropFirst())
let gSelfTest = gArgs.contains("--render-self-test")
// True when launched with no host arg → the picker drives host selection.
var gPickerMode = false

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    FileHandle.standardError.write(
        Data("usage: tailscreen-viewer-gtk [<sharer-host>] [--port N] [--state-dir PATH] [--control-url URL]\n".utf8))
    exit(2)
}

/// Parse the live-run arguments. The host is OPTIONAL — its absence selects
/// picker mode. The returned `ViewerConfig` carries an empty hostname then
/// (`prepare` ignores hostname; the chosen sharer's IP fills it in before `run`).
func parseConfig() -> (config: ViewerConfig, host: String?) {
    var args = gArgs
    var host: String?
    var port: UInt16 = 7447
    var statePath = FileManager.default.currentDirectoryPath + "/.tailscreen-viewer-gtk-state"
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
        case "--state-dir":
            guard let value = args.first else { fail("--state-dir needs a path") }
            statePath = value
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
    return (config, host)
}

if gSelfTest {
    // Headless render gate: a colour-bars frame the GtkVideoView renders and
    // the self-test verifies via glReadPixels. No transport.
    gStore.set(makeColorBarsFrame())
} else {
    // Live path: reuse the tsnet transport, driving decoded frames into the
    // shared store. The transport is @MainActor; started as a Task here, it
    // runs interleaved with the GTK loop (swift-cross-ui ticks RunLoop.main),
    // so `present` — and thus the GLArea repaint — happens on the main thread.
    let (baseConfig, host) = parseConfig()
    let sink = GtkVideoSink(store: gStore, uiState: gUIState)
    let decoder = FFmpegVideoDecoder()
    let transport = TsnetTransport()
    // Inbound back-channel handlers: control grant/revoke drive the toolbar's
    // state machine. Inbound annotation *rendering* (drawing relayed strokes on
    // an overlay canvas) is a follow-up — the plumbing already carries the ops.
    let backChannelHandlers = ViewerBackChannel.Handlers(
        onAnnotation: { _ in },
        onControlGranted: { gUIState.setControlState(.active) },
        onControlRevoked: { reason in gUIState.setControlState(.revoked(reason: reason)) })

    // Run a viewing session against a chosen host/IP. Shared by the direct-host
    // path and the picker's selection callback (both on the main actor).
    func startSession(host dialHost: String) {
        var config = baseConfig
        config.hostname = dialHost
        Task { @MainActor in
            do {
                // audio (ALSA) wiring is deferred to a later phase; video first.
                try await transport.run(
                    config: config, decoder: decoder, videoSink: sink,
                    audioSink: nil, shouldClose: { false },
                    backChannelHandlers: backChannelHandlers,
                    onBackChannelReady: { channel in gControls.attach(channel) },
                    onAdmitted: { caps in
                        gUIState.setCaps(
                            remoteControl: caps.contains(.remoteControl),
                            annotations: caps.contains(.annotations))
                    })
                FileHandle.standardError.write(Data("session ended\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("session failed: \(error)\n".utf8))
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
        Task { @MainActor in
            do {
                gPicker.phase = .startingNode
                try await transport.prepare(config: baseConfig, onLoginURL: { url in
                    Task { @MainActor in gPicker.loginURL = url.absoluteString }
                })
                gPicker.loginURL = nil
                gPicker.phase = .discovering
                let peers = try await transport.discoverPeers()
                gPicker.sharers = peers.filter { $0.isOnline }
                gPicker.phase = .picking
            } catch {
                FileHandle.standardError.write(Data("discovery failed: \(error)\n".utf8))
                gPicker.phase = .picking  // renders "No screens found"
            }
        }
    }
}

struct ViewerApp: App {
    // Observe the shared UI state so the placard reactively hides once video
    // flows (swift-cross-ui @State tracks the ObservableObject's @Published).
    @State var ui = gUIState
    @State var picker = gPicker

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

    var body: some Scene {
        WindowGroup("Tailscreen viewer") {
            ZStack {
                GtkVideoView(store: gStore, selfTest: gSelfTest)
                // Pre-video chrome (never in self-test). In picker mode this is
                // the sharer list + status; otherwise the connection placard.
                if !gSelfTest && !ui.hasVideo {
                    if gPickerMode {
                        VStack {
                            Text(picker.statusLine)
                            if let login = picker.loginURL {
                                Text("Open this URL in a browser to log in:")
                                Text(login)
                            }
                            if showingPickerList {
                                ScrollView {
                                    VStack {
                                        ForEach(picker.sharers, id: \.id) { sharer in
                                            Button(sharer.hostname) { picker.select(sharer) }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        Text(ui.status)
                    }
                }
                // Remote-control toolbar, pinned to the bottom. Shown only when
                // the sharer advertised `.remoteControl` (caps-gated, like the
                // mac viewer). Input capture (pointer/keyboard → `sendInputEvent`)
                // is the follow-up; this delivers the request/grant handshake.
                if !gSelfTest && ui.remoteControlAvailable {
                    VStack {
                        Spacer()
                        HStack {
                            Button(controlButtonLabel) { gControls.toggleControl() }
                            if let reason = revokedReason {
                                Text("Control declined: \(reason)")
                            }
                        }
                    }
                }
            }
        }
        .defaultSize(width: 960, height: 540)
    }
}

ViewerApp.main()
