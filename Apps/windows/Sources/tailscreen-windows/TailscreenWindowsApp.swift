import DefaultBackend
import Foundation
import SwiftCrossUI

// Targeted imports: pulling all of TailscreenProtocol collides with SwiftCrossUI's
// own `Published` / `ObservableObject` shims, the same collision the GTK app
// hits and solves the same way.
import struct TailscreenProtocol.QualitySettings
import struct TailscreenViewerTsnet.DiscoveredSharer
import class TailscreenViewerTsnet.TsnetTransport
import struct TailscreenViewerTsnet.ViewerConfig

// NOT named main.swift on purpose: Swift rejects `@main` in a file with that
// name, because main.swift is itself top-level code.

/// Stage W3 of the Windows port: a live tsnet node, interactive sign-in, and
/// the tailnet peer list.
///
/// W2 proved the chrome renders. This proves the thing the whole port actually
/// rests on — that libtailscale's Go↔native bridge, rebuilt for Windows in
/// patch 024, carries a real tsnet node on a real Windows machine. Everything
/// downstream (video, audio, remote control) is a consumer of that node, so
/// until it comes up nothing else is worth wiring.
///
/// Still no video: that needs a decoder and a render surface (W4). The peer
/// list is the deliberate stopping point, because it is the first screen whose
/// contents can only be correct if the node is genuinely on the tailnet.
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

                if state.phase == .ready {
                    HStack(spacing: 8) {
                        Button("Refresh") { state.refreshPeers() }
                        Button("Sign out") { state.signOut() }
                    }
                    Divider()
                    PeerList(peers: state.peers, isSearching: state.isSearching)
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

/// The discovered-sharer list.
///
/// An empty list is reported as such rather than left blank: "no screens found"
/// and "still looking" are different states, and on a tailnet with one machine
/// the first is the correct, permanent answer.
struct PeerList: View {
    let peers: [DiscoveredSharer]
    let isSearching: Bool

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
                                Text(peer.hostname)
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

    private let transport = TsnetTransport()

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

    func signOut() {
        guard phase == .ready else { return }
        phase = .idle
        status = "Not signed in"
        detail = ""
        peers = []
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
