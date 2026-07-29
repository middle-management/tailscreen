import DefaultBackend
import Foundation
import SwiftCrossUI

// Targeted imports: pulling all of TailscreenProtocol collides with SwiftCrossUI's
// own `Published` / `ObservableObject` shims, the same collision the GTK app
// hits and solves the same way.
import struct TailscreenProtocol.QualitySettings
import enum TailscreenProtocol.TailscreenInstance
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

    var body: some Scene {
        WindowGroup("Tailscreen") {
            VStack(spacing: 12) {
                Text("Tailscreen")
                    .font(.title2)

                Text(state.status)
                    .font(.caption)

                if let url = state.loginURL {
                    LoginCard(url: url) { state.openLoginURL() }
                }

                if state.phase == .idle || state.phase == .failed {
                    Button(state.phase == .failed ? "Try again" : "Sign in to Tailscale") {
                        state.signIn()
                    }
                }

                if let host = state.watching {
                    // Watching: the video fills the window, with one way out.
                    HStack(spacing: 8) {
                        Text("Watching \(host)")
                            .font(.caption)
                        Spacer()
                        Button("Stop") { state.disconnect() }
                    }
                    WinUIVideoView(
                        store: state.frameStore,
                        generation: state.frameGeneration
                    )
                } else if state.sharing.isSharing {
                    SharingCard(
                        status: state.sharing,
                        onStop: { state.stopSharing() }
                    )
                } else if state.phase == .ready {
                    HStack(spacing: 8) {
                        Button("Refresh") { state.refreshPeers() }
                        if state.canShare {
                            Button("Share this screen") { state.startSharing() }
                        }
                        Button("Sign out") { state.signOut() }
                    }
                    Divider()
                    PeerList(
                        peers: state.peers,
                        isSearching: state.isSearching,
                        onSelect: { state.connect(to: $0) }
                    )
                }

                if !state.detail.isEmpty {
                    Text(state.detail)
                        .font(.caption)
                }

                Spacer()

                Text(state.environmentLine)
                    .font(.caption)
            }
            .padding(12)
        }
        .defaultSize(width: 520, height: 460)
    }
}

/// The interactive-login placard. tsnet emits a browser URL on the IPN bus when
/// a fresh node has no auth key; until it is visited, `up()` does not return.
///
/// The URL is shown as text rather than only offered as a button on purpose:
/// launching a browser is the part most likely to fail on a locked-down or
/// headless machine, and a URL you can select and paste always works.
struct LoginCard: View {
    let url: String
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text("Sign in to your tailnet to continue")
                .font(.caption)
            Text(url)
                .font(.caption)
            Button("Open in browser") { onOpen() }
        }
        .padding(8)
    }
}

/// What is on screen while this machine is sharing.
///
/// The viewer count is spelled out rather than shown as a badge: "nobody is
/// watching yet" and "two people are watching" are the two facts a sharer
/// actually wants, and a number alone leaves the first ambiguous.
struct SharingCard: View {
    let status: WindowsShareSession.Status
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Sharing \(status.target)")
                    .font(.caption)
                Spacer()
                Button("Stop sharing") { onStop() }
            }
            Text(
                status.viewerCount == 0
                    ? "No one is watching yet"
                    : "\(status.viewerCount) watching"
            )
            .font(.caption)
        }
        .padding(8)
    }
}

/// The discovered-sharer list. Selecting a row dials that peer.
///
/// An empty list is reported as such rather than left blank: "no screens found"
/// and "still looking" are different states, and on a tailnet with one machine
/// the first is the correct, permanent answer.
struct PeerList: View {
    let peers: [DiscoveredSharer]
    let isSearching: Bool
    let onSelect: (DiscoveredSharer) -> Void

    var body: some View {
        VStack(spacing: 6) {
            if isSearching {
                Text("Looking for peers…")
                    .font(.caption)
            } else if peers.isEmpty {
                Text("No Tailscreen peers found on this tailnet")
                    .font(.caption)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(peers, id: \.id) { peer in
                            HStack(spacing: 8) {
                                Text(peer.isOnline ? "●" : "○")
                                // A real Button, not a tap-handler on the row:
                                // keyboard and screen readers can reach a
                                // button, which is the same reason the macOS
                                // peer rows use always-visible controls.
                                Button(peer.hostname) { onSelect(peer) }
                                Spacer()
                                Text(peer.tailscaleIP)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        }
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
        return "\(Self.architecture) · fps cap \(quality.fpsCap) · codec \(quality.codecPreference)"
    }

    func signIn() {
        guard phase == .idle || phase == .failed else { return }
        phase = .starting
        status = "Starting Tailscale…"
        detail = ""
        loginURL = nil

        Task {
            do {
                try await transport.prepare(
                    config: ViewerConfig(
                        // The dial target, used only by `run()` when a viewing
                        // session starts. Discovery never reads it, and this
                        // stage stops before dialing.
                        hostname: "",
                        statePath: Self.stateDirectory()
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

    /// Whether to offer the share button at all. Withheld rather than shown
    /// and then failing: a Windows build without Windows.Graphics.Capture
    /// cannot share, and finding that out by pressing a button is worse than
    /// not being offered one.
    var canShare: Bool { shareSession.isSupported && watching == nil }

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
                    hostname: Self.sharerHostname(),
                    statePath: Self.sharerStateDirectory(),
                    quality: quality
                )
            } catch {
                self.detail = "Could not start sharing: \(error)"
            }
        }
    }

    func stopSharing() {
        Task { [weak self] in await self?.shareSession.stopSharing() }
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

    /// A SEPARATE state directory from the viewer's.
    ///
    /// The screen-share server brings up its own tsnet node, and a tsnet state
    /// directory holds a machine key — one identity. Pointing both at the same
    /// directory would have two live nodes fighting over one key, which is the
    /// same defect `TAILSCREEN_INSTANCE` exists to prevent for two copies of
    /// the mac app on one machine. Reusing the viewer's NODE (the server's
    /// `existingNode:` parameter) is the better answer and the one macOS uses;
    /// it needs the app to own the node rather than the transport, which is a
    /// larger change than this stage.
    private static func sharerStateDirectory() -> String {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: base)
            .appendingPathComponent("Tailscreen")
            .appendingPathComponent("tailscale-sharer")
            .path
    }

    /// The name this machine advertises while sharing.
    ///
    /// Built from `serverHostnamePrefix` rather than spelled out, because
    /// discovery's rule is "starts with the server prefix and NOT with the
    /// client prefix" — a share registered under the viewer prefix is
    /// deliberately invisible to the peers meant to watch it. Machine names
    /// are filtered to what a hostname may contain, and one that would
    /// collide with the client prefix falls back rather than disappearing.
    private static func sharerHostname() -> String {
        let machine =
            ProcessInfo.processInfo.environment["COMPUTERNAME"]
            ?? ProcessInfo.processInfo.hostName
        var cleaned = machine.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let candidate = TailscreenInstance.serverHostnamePrefix + cleaned
        if cleaned.isEmpty || !TailscreenInstance.isTailscreenServerHostname(candidate) {
            cleaned = "windows"
        }
        return TailscreenInstance.serverHostnamePrefix + cleaned
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
