import Foundation
import SwiftCrossUI
import TailscaleKit
import TailscreenSharer
import TailscreenSharerLinux
import TailscreenViewerTsnet
import X11CaptureKit

// Targeted imports: pulling in all of TailscreenProtocol collides with
// SwiftCrossUI's own `Published` / `ObservableObject` shims on Linux.
import struct TailscreenProtocol.AccountProfileLayout
import enum TailscreenProtocol.PeerPolicy
import class TailscreenProtocol.PeerAccessStore
import class TailscreenProtocol.SharerAccessCoordinator
import struct TailscreenProtocol.PickerSelection
import struct TailscreenProtocol.QualitySettings
import enum TailscreenProtocol.ViewerApprovalPreference
import enum TailscreenProtocol.ViewerRosterDecision

/// Somebody currently watching, as the share card needs them.
///
/// `stableID` rides along because the roster's remember/forget actions are
/// about the PERSON, not the connection: the store is keyed by Tailscale
/// StableNodeID and nothing else is safe to key on. It is nil until the netmap
/// lookup lands, which is what `SharerAccessCoordinator` queues around.
///
/// File scope, like `PendingViewer` and for the same reason: the server's
/// callback is not on the main actor and it is the code that builds these.
struct ConnectedViewer: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let stableID: String?
    let health: String?
}

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
    /// See `ConnectedViewer.stableID` — "Always Allow" / "Deny & Block" on a
    /// pending row persists under this, not under the hostname a peer sends.
    let stableID: String?
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
    /// Bumped whenever the remembered-policy layer changes.
    ///
    /// SwiftCrossUI's `ObservableObject` shim has no `objectWillChange`, and
    /// the thing that changed lives in `SharerAccessCoordinator` rather than in
    /// a `@Published` here — deliberately, since it is portable and this app
    /// only renders it. A counter is the shim's idiom for "something you cannot
    /// see moved"; the roster rows read the coordinator when they redraw.
    @Published private(set) var accessGeneration = 0

    /// Who is watching, for the sharing card's roster.
    ///
    /// Structured rather than a list of IP strings, which is what it was: this
    /// is the surface a sharer uses to change their mind about somebody
    /// already admitted, and before it existed this app could admit a viewer
    /// and then do nothing about them.
    @Published var viewers: [ConnectedViewer] = []
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

    /// Remembered allow/deny, and the queue for decisions made before a peer's
    /// identity resolved. Portable and tested on Linux CI — this app only
    /// renders rows and forwards taps.
    ///
    /// Built once and outliving each share on purpose: what a sharer decided
    /// about somebody is not a property of the session they decided it in.
    private let access = SharerAccessCoordinator(
        store: PeerAccessStore(directory: AccountProfileLayout.xdg().root))
    /// Viewers' strokes, drawn on this machine's own screen. Nil when the
    /// session cannot host one — see `SharerAnnotationOverlay.isSupported`.
    private var overlay: SharerAnnotationOverlay?
    /// Granted viewers' input, replayed on this machine. Nil when this X
    /// server has no XTEST extension.
    ///
    /// Held for the share's lifetime rather than handed to the server and
    /// forgotten, because the server's own teardown is asynchronous and the
    /// grant must be sealed the moment sharing stops — see `teardownOverlay`,
    /// which does the same for the same reason.
    private var injector: X11InputInjector?
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
            return viewers.isEmpty ? "Sharing — nobody watching yet" : "Sharing to \(viewers.count)"
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

        // The annotation overlay has to exist BEFORE the server, because
        // whether it exists is what the server advertises. Sized from the
        // capture's own geometry, not the monitor's: annotations arrive
        // normalized against the frame a viewer sees, and the capture rounds
        // both dimensions down to even for I420, so a screen with an odd
        // dimension would put every stroke a pixel out.
        let overlay = Self.makeOverlay(display: display)
        if overlay == nil {
            // Worth a line: the share works perfectly and viewers simply find
            // their drawing tools greyed out, with nothing on either end
            // saying why. Matches this app's other diagnostics (stderr, not a
            // logger — there is no TSLogger convention on this side).
            FileHandle.standardError.write(
                Data(
                    """
                    warning: no annotation overlay (needs a compositing X11 session) — \
                    viewers' drawing tools will be disabled\n
                    """.utf8))
        }
        self.overlay = overlay

        // Likewise the injector, and for the same reason: supplying one is
        // what makes the server advertise `.remoteControl`. Nil when this X
        // server has no XTEST extension — optional in the protocol, absent on
        // some remote and kiosk servers — in which case every injected click
        // would silently vanish, so viewers must not be invited to try.
        let injector = Self.makeInjector(display: display)
        if injector == nil {
            FileHandle.standardError.write(
                Data(
                    """
                    warning: no input injection (this X server has no XTEST extension) — \
                    viewers will not be offered Request Control\n
                    """.utf8))
        }
        self.injector = injector

        let server = TailscaleScreenShareServer(
            captureFactory: { X11CaptureEncoder(display: display) },
            // Present iff XTEST is: the server derives `.remoteControl` from
            // whether this is non-nil, so a host that cannot inject withholds
            // the bit and viewers hide Request Control rather than sending
            // requests nothing can serve.
            inputInjector: injector,
            // Claimed only when there is a real surface to draw on. Without a
            // compositor there is none (see `SharerAnnotationOverlay`), and a
            // sharer that claims `.annotations` it cannot render leaves every
            // viewer drawing strokes that reach nobody — silently, which is
            // exactly the failure Phase 0 flipped this default to prevent.
            rendersAnnotations: overlay != nil
        )
        // Fires on the server's control-channel thread; the overlay marshals
        // onto the GTK main thread itself.
        server.onAnnotationReceived = { [overlay] op in overlay?.apply(op) }
        // The server's own default is OFF — right for the headless CLI sharer
        // that automation drives, wrong for anything with a person in front of
        // it — so the gate has to be asserted here on every start. Assert the
        // user's setting rather than a literal `true`, or the toggle would be
        // a switch the share ignores.
        server.setRequireApproval(requireApproval)
        // Push what is already remembered BEFORE the first HELLO can arrive,
        // so a blocked peer is rejected on its first attempt rather than
        // admitted and then swept out a moment later.
        server.setAccessPolicies(access.policies)
        access.onPoliciesChanged = { [weak server] policies in
            server?.setAccessPolicies(policies)
        }
        server.onViewersChanged = { infos in
            // Mapped off the main actor (the callback is not on it), then
            // handed over whole. `stableID` travels with each row because the
            // remember/forget actions key on it.
            let rows = infos.map {
                ConnectedViewer(
                    id: $0.id, label: $0.hostname ?? $0.tailscaleIP, stableID: $0.stableID,
                    health: $0.health == .good ? nil : "\($0.health)")
            }
            Task { @MainActor [weak self] in self?.applyConnected(rows) }
        }
        server.onPendingViewersChanged = { pending in
            // Keyed by the server's `"ip:port"` id, NOT the bare IP — see
            // `PendingViewer`. Fires off the main actor; hop.
            let waiting = pending.map {
                PendingViewer(
                    id: $0.id, label: $0.hostname ?? $0.tailscaleIP, stableID: $0.stableID)
            }
            Task { @MainActor [weak self] in self?.applyPending(waiting) }
        }
        server.onCaptureStopped = { error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.phase = .failed("\(error)")
                } else {
                    self.phase = .idle
                }
                self.viewers = []
                self.pendingViewers = []
                self.teardownOverlay()
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
                self.teardownOverlay()
            }
        }
    }

    func stopSharing() {
        guard let server else {
            phase = .idle
            teardownOverlay()
            return
        }
        self.server = nil
        viewers = []
        pendingViewers = []
        phase = .idle
        // Queued decisions do not outlive the share they were made during:
        // the rows are gone, and an intent that survived would land on whoever
        // connects to the NEXT share from the same address.
        access.reset()
        teardownOverlay()
        Task { await server.stop() }
    }

    /// Hide the overlay and seal the injector.
    ///
    /// Both are torn down explicitly rather than left to `deinit`, and for the
    /// same reason: the server holds them too, and its own teardown is
    /// asynchronous. Dropping only this reference would leave viewers' strokes
    /// on screen and — much worse — a live control grant, for however long the
    /// server took to finish stopping. "Stop Sharing" has to mean the remote
    /// hands are off *now*.
    ///
    /// `deactivate()` also releases any button held mid-drag, so stopping a
    /// share while a viewer is dragging cannot leave a button stuck down. On
    /// X11 that matters more than elsewhere: a held button grabs the pointer,
    /// so a stuck one makes the whole desktop unusable.
    private func teardownOverlay() {
        overlay?.clear()
        overlay = nil
        injector?.deactivate()
        injector = nil
    }

    /// Build the injector, or nil when this X server cannot inject.
    ///
    /// `isTrusted()` is the real question and it is asked HERE, before the
    /// server exists, because its answer decides whether `.remoteControl` goes
    /// out on the wire at all. Asking later would mean advertising a
    /// capability and then declining every request that arrived because of it.
    private static func makeInjector(display: String?) -> X11InputInjector? {
        let injector = X11InputInjector(display: display)
        return injector.isTrusted() ? injector : nil
    }

    /// Build the overlay at the capture's exact pixel geometry, or nil if this
    /// session cannot host one.
    ///
    /// The size comes from an `X11ScreenCapture` rather than from GDK's
    /// monitor list because it must match what the encoder actually sends:
    /// `captureWidth`/`captureHeight` round down to even for I420, and
    /// annotations are normalized against the encoded frame.
    private static func makeOverlay(display: String?) -> SharerAnnotationOverlay? {
        guard SharerAnnotationOverlay.isSupported else { return nil }
        guard let probe = try? X11ScreenCapture(display: display) else { return nil }
        return SharerAnnotationOverlay(
            width: probe.captureWidth, height: probe.captureHeight)
    }

    // MARK: Roster

    /// Publish a connected-roster snapshot and let the access layer see it.
    ///
    /// The roster is re-emitted whenever anything about it changes — including
    /// a StableNodeID finishing resolution, which is precisely the event a
    /// queued "Deny & Block" is waiting for. So feeding it here, rather than
    /// only on join and leave, is what makes the queue drain at all.
    private func applyConnected(_ rows: [ConnectedViewer]) {
        viewers = rows
        noteRoster()
    }

    private func applyPending(_ rows: [PendingViewer]) {
        pendingViewers = rows
        noteRoster()
    }

    /// Both lists together: a peer moves between them (pending → connected on
    /// Accept), and feeding one at a time would prune the other's queued
    /// intents as "gone" the instant it moved.
    private func noteRoster() {
        let identities =
            viewers.map {
                ViewerRosterDecision.RosterIdentity(
                    id: $0.id, stableID: $0.stableID, displayName: $0.label)
            }
            + pendingViewers.map {
                ViewerRosterDecision.RosterIdentity(
                    id: $0.id, stableID: $0.stableID, displayName: $0.label)
            }
        if access.noteRoster(identities) {
            // A queued decision just landed; the roster's own rows now render
            // differently (the standing decision replaces the two buttons).
            accessGeneration &+= 1
        }
    }

    /// What is remembered about a row's peer, for the roster's label.
    func remembered(stableID: String?) -> PeerPolicy? { access.remembered(stableID: stableID) }

    /// Whether a decision on this row is queued behind identity resolution.
    func isDeferred(rowID: String) -> Bool { access.isDeferred(rowID: rowID) }

    /// "Always Allow" / "Deny & Block" on a roster row.
    ///
    /// Persisting fires `onPoliciesChanged`, which pushes the map at the live
    /// server — which is what makes a block on somebody already watching
    /// actually expel them, rather than merely stop them coming back.
    func remember(rowID: String, stableID: String?, label: String, policy: PeerPolicy) {
        access.remember(
            rowID: rowID, stableID: stableID, displayName: label, policy: policy)
        accessGeneration &+= 1
    }

    /// Drop what is remembered about a row's peer.
    func forget(rowID: String, stableID: String?) {
        access.forget(rowID: rowID, stableID: stableID)
        accessGeneration &+= 1
    }

    /// One-time disconnect of a connected viewer — the roster's Disconnect.
    ///
    /// Nothing is remembered: their next HELLO goes back through the normal
    /// admission gate. That is the difference between this and Deny & Block,
    /// and it is why both exist.
    func disconnect(_ addr: String) { server?.disconnectViewer(addr: addr) }

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
