import Foundation
import SwiftCrossUI
import TailscaleKit
import TailscreenSharer
import TailscreenSharerLinux
import TailscreenViewerTsnet

// Targeted imports: pulling in all of TailscreenProtocol collides with
// SwiftCrossUI's own `Published` / `ObservableObject` shims on Linux.
import struct TailscreenProtocol.PickerSelection
import struct TailscreenProtocol.QualitySettings
import enum TailscreenProtocol.ViewerApprovalPreference

/// A viewer parked at the approval gate, as the share card needs it.
///
/// `id` is the server's own viewer key — `"ip:port"`, not the bare IP. That
/// distinction is the whole reason this is a struct rather than a string:
/// `approveViewer` and `denyViewer` look the address up in the pending map, and
/// an IP with the port dropped matches nothing, so both silently no-op. The
/// sharer gets a row with two buttons that do nothing and the viewer waits
/// forever. `label` is the readable half — a hostname once the netmap lookup
/// lands, the IP until then.
///
/// File scope rather than nested in `SharerModel`, which is `@MainActor`: the
/// server's pending callback is not, and it is the code that builds these.
struct PendingViewer: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
}

/// Drives the *sharing* half of the app: start/stop a share, and publish who's
/// watching so the chrome can render it.
///
/// The counterpart of `PickerModel`, and deliberately just as thin. Everything
/// that makes sharing work — admission, RTP fan-out, NACK/FEC, congestion
/// control, the idle sweep — is the portable `TailscaleScreenShareServer`; this
/// only decides *what* to capture and marshals state onto the main actor for
/// the UI.
///
/// **It borrows the viewer's tsnet node** rather than bringing up its own. Two
/// nodes would mean two tailnet identities for one app: peers would see a
/// phantom second machine, and the sharer wouldn't be reachable at the address
/// the viewer half advertises. The macOS app solves this the same way —
/// `AppState` owns one node and passes it to both the server and the client.
@MainActor
final class SharerModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case sharing
        case failed(String)
    }

    @Published var phase: Phase = .idle
    /// Tailscale IPs of admitted viewers, for the sharing card.
    @Published var viewerIPs: [String] = []
    /// Viewers parked awaiting approval, when the approval gate is on.
    @Published var pendingViewers: [PendingViewer] = []
    /// Whether new viewers have to be let in by hand.
    ///
    /// Persisted, and read back at launch through the shared
    /// `ViewerApprovalPreference` so this app, the Windows app and the macOS
    /// app cannot disagree about the default (on) or the
    /// `TAILSCREEN_OPEN_DOOR=1` harness override. Mutate via
    /// `setRequireApproval` — assigning here would change the switch without
    /// telling the live server, which is the one place it matters.
    @Published private(set) var requireApproval: Bool = ViewerApprovalPreference.load()

    /// Whether this host can share at all. X11 capture needs a display; on a
    /// Wayland-only or headless session there's nothing to capture, and the UI
    /// should say so rather than offer a button that always fails.
    let canShare: Bool
    /// Why sharing is unavailable, when it is.
    let unavailableReason: String?

    private var server: TailscaleScreenShareServer?
    /// Supplied by `main` — hands back the live tsnet node to share.
    var nodeProvider: (() -> TailscaleNode?)?

    init(display: String? = nil) {
        let display = display ?? ProcessInfo.processInfo.environment["DISPLAY"]
        if let display, !display.isEmpty {
            canShare = true
            unavailableReason = nil
        } else {
            canShare = false
            unavailableReason = "No X display — screen sharing needs X11 (Wayland uses the portal, not yet supported)"
        }
        self.display = display
    }

    private let display: String?

    var statusLine: String {
        switch phase {
        case .idle: return unavailableReason ?? "Not sharing"
        case .starting: return "Starting share…"
        case .sharing:
            if !pendingViewers.isEmpty {
                return "\(pendingViewers.count) waiting for approval"
            }
            return viewerIPs.isEmpty ? "Sharing — nobody watching yet" : "Sharing to \(viewerIPs.count)"
        case .failed(let why): return "Share failed: \(why)"
        }
    }

    /// Begin sharing this host's display.
    func startSharing() {
        guard canShare, phase == .idle || isFailed else { return }
        guard let node = nodeProvider?() else {
            phase = .failed("Tailscale isn't up yet")
            return
        }
        phase = .starting

        let selection = PickerSelection(kind: .display, displayID: 0, windowID: nil, bundleIDs: [])
        guard let selectionData = try? JSONEncoder().encode(selection) else {
            phase = .failed("could not describe the display to capture")
            return
        }

        let display = self.display
        let server = TailscaleScreenShareServer(
            captureFactory: { X11CaptureEncoder(display: display) },
            // No injector on Linux yet (that's the RemoteDesktop portal), so
            // the server withholds `.remoteControl` and viewers correctly hide
            // their Request Control affordance.
            inputInjector: nil
        )
        // The server's own default is OFF — right for the headless CLI sharer
        // that automation drives, wrong for anything with a person in front of
        // it — so the gate has to be asserted here on every start. Assert the
        // user's setting rather than a literal `true`, or the toggle would be
        // a switch the share ignores.
        server.setRequireApproval(requireApproval)
        server.onViewersChanged = { viewers in
            let ips = viewers.map(\.tailscaleIP)
            Task { @MainActor [weak self] in self?.viewerIPs = ips }
        }
        server.onPendingViewersChanged = { pending in
            // Keyed by the server's `"ip:port"` id, NOT the bare IP — see
            // `PendingViewer`. Fires off the main actor; hop.
            let waiting = pending.map {
                PendingViewer(id: $0.id, label: $0.hostname ?? $0.tailscaleIP)
            }
            Task { @MainActor [weak self] in self?.pendingViewers = waiting }
        }
        server.onCaptureStopped = { error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.phase = .failed("\(error)")
                } else {
                    self.phase = .idle
                }
                self.viewerIPs = []
                self.pendingViewers = []
            }
        }
        self.server = server

        Task { @MainActor in
            do {
                try await server.start(
                    filterData: selectionData,
                    quality: .default,
                    existingNode: node
                )
                phase = .sharing
            } catch {
                phase = .failed("\(error)")
                self.server = nil
            }
        }
    }

    func stopSharing() {
        guard let server else {
            phase = .idle
            return
        }
        self.server = nil
        viewerIPs = []
        pendingViewers = []
        phase = .idle
        Task { await server.stop() }
    }

    /// Admit a viewer parked at the approval gate. `addr` is the
    /// `PendingViewer.id` (`"ip:port"`), never a bare IP.
    func approve(_ addr: String) { server?.approveViewer(addr: addr) }
    /// Reject a viewer parked at the approval gate.
    func deny(_ addr: String) { server?.denyViewer(addr: addr) }

    /// Flip the approval gate, persist it, and push it at a live share.
    ///
    /// Applied mid-share on purpose: `setRequireApproval(false)` drains
    /// whoever is already parked (minus anyone remembered-deny), so turning
    /// the gate off is also how you admit a queue in one click. Turning it on
    /// mid-share affects the next HELLO — viewers already admitted stay
    /// admitted, exactly as on macOS.
    func setRequireApproval(_ enabled: Bool) {
        guard enabled != requireApproval else { return }
        requireApproval = enabled
        ViewerApprovalPreference.save(enabled)
        server?.setRequireApproval(enabled)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}

/// A stable, tailnet-legal node name for this host's share-capable node.
///
/// Stable across launches on purpose: a peer that reconnects should find the
/// same screen rather than a new one each time the app restarts. Sanitised
/// because tsnet hostnames are DNS labels — anything outside `[a-z0-9-]` would
/// be rejected or silently mangled by the control plane.
@MainActor
func localShareName() -> String {
    let raw = ProcessInfo.processInfo.hostName
    let cleaned = raw.lowercased().map { ch -> Character in
        ch.isLetter || ch.isNumber ? ch : "-"
    }
    let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "linux" : String(trimmed.prefix(48))
}
