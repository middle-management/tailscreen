import AppKit
import ApplicationServices
import Combine
import CoreAudio
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Observation
import QuartzCore
import ScreenCaptureKit
import ServiceManagement
import SwiftUI
import TailscaleKit
import TailscreenViewer

/// Sharing-side lifecycle: `idle` → `starting` (SCStream coming up) →
/// `active` (first preview frame landed, viewers can join) → `idle`. The
/// shared `ShareBringUpPhase` (TailscreenProtocol) — unlike this app's old
/// `idle/starting/active`, it has a `.failed` case that survives to explain
/// the button, and `active` is renamed `sharing` to match the other hosts.
typealias SharingState = ShareBringUpPhase

/// Viewer-side lifecycle: `idle` → `connecting` (dial + HELLO in flight) →
/// `viewing` → `idle`. Mirrors `SharingState` so the popover shows
/// "Connecting…" instead of sitting on the device picker silently.
enum ConnectionState: Equatable {
    case idle
    case connecting
    case viewing
}

/// Why the last viewer session ended, presented in-window (reason text +
/// Reconnect/Close over the last frame) rather than the window vanishing.
/// The shared `ViewerSessionEndReason` (TailscreenProtocol), also used by the
/// GTK/WinUI hub chrome; the local name stays because call sites here read as
/// `ViewerSessionEnding`.
typealias ViewerSessionEnding = ViewerSessionEndReason

@MainActor
class AppState: ObservableObject {
    @Published var sharingState: SharingState = .idle
    @Published var connectionState: ConnectionState = .idle
    /// True while a mid-share "Change Source…" flow is in flight. Disables
    /// the SharingCard's button so a second picker can't spawn on top.
    @Published var isChangingSource = false
    @Published var connectedHostname: String?
    @Published var statusMessage = ""
    /// Whether the sharer's drawing overlay panel is visible and accepting
    /// input. Only created while sharing.
    @Published var isSharerOverlayVisible = false
    @Published var isMicOn = false

    /// Whether the current share is sending system/computer audio to viewers.
    /// Flipped by `toggleSystemAudio()`; reset on `stopSharing`.
    @Published var isSystemAudioOn = false

    /// Turn system audio on automatically when a share starts. Persisted
    /// under `shareSystemAudio` (defaults off).
    @Published var shareSystemAudioByDefault: Bool = SystemAudioDefaults.load() {
        didSet { SystemAudioDefaults.save(shareSystemAudioByDefault) }
    }

    /// Refreshed every time the popover opens — `AudioDevices.all()` is
    /// cheap.
    @Published var availableInputDevices: [AudioDevice] = []
    @Published var availableOutputDevices: [AudioDevice] = []

    /// User-selected device IDs. `nil` = follow system default. Set via
    /// `selectInputDevice(_:)`/`selectOutputDevice(_:)`, which also push the
    /// change into the live `MicCapture` engine.
    @Published var selectedInputDeviceID: AudioDeviceID?
    @Published var selectedOutputDeviceID: AudioDeviceID?

    private var voiceChannel: VoiceChannel?
    private var micCapture: MicCapture?
    private var micHotkey: GlobalHotkey?

    /// Cross-instance advisory lock, held while sharing, so other Tailscreen
    /// instances on this Mac can grey out their Share button.
    private let shareLock = ShareLock()

    /// Mirrors `ShareLock.isHeldByAnyone()` minus our own hold. Polled every
    /// 2s; the Share button's disabled state binds to it.
    @Published var anotherInstanceSharing: Bool = false
    private var shareLockProbeTimer: Timer?

    /// Viewers connected to our server. Populated from
    /// `TailscaleScreenShareServer.onViewersChanged`.
    @Published var currentViewers: [ViewerInfo] = []

    /// Viewers waiting for Accept/Deny, when `requireViewerApproval` is on.
    /// Mirrors `onPendingViewersChanged`. Cleared on `stopSharing`.
    @Published var pendingViewers: [PendingViewerInfo] = []

    /// Viewers asking for remote control. Mirrors `onControlRequestsChanged`.
    /// Cleared on stopSharing.
    @Published var controlRequests: [ControlRequestInfo] = []

    /// Links viewers sent, awaiting Open/Dismiss. Mirrors
    /// `onLinkOffersChanged`. Cleared on stopSharing.
    @Published var linkOffers: [LinkOfferInfo] = []

    /// The viewer that currently holds remote control, or nil. Mirrors
    /// `onControlGrantChanged`; drives the "X is controlling your Mac"
    /// banner. Cleared on stopSharing.
    @Published var controlGrantee: ControlGrantInfo?

    /// Viewer-side remote-control mode. `.requested` until the sharer
    /// answers, `.controlling` once granted. Reset on disconnect.
    @Published var viewerControlState: ViewerControlState = .none

    /// Whether the current sharer advertised `ScreenShareCaps.remoteControl`
    /// in HELLO_ACK — hides "Request Control" until then. False on
    /// disconnect.
    @Published var sharerSupportsRemoteControl = false

    /// Whether the current sharer advertised `ScreenShareCaps.openLink` —
    /// hides "Open Link on Sharer…" until then. False on disconnect.
    @Published var sharerSupportsOpenLink = false {
        didSet {
            if !sharerSupportsOpenLink { dismissOpenLinkSheet() }
        }
    }

    /// Whether the current sharer advertised `ScreenShareCaps.annotations`.
    /// Defaults *true* (unlike remote control) so mac→mac shows tools
    /// immediately with no disable-flash; a non-supporting HELLO_ACK
    /// corrects it. Reset to true on disconnect.
    @Published var sharerSupportsAnnotations = true {
        didSet {
            guard oldValue != sharerSupportsAnnotations else { return }
            viewerToolbar?.setAnnotationsEnabled(sharerSupportsAnnotations)
        }
    }

    /// Second global hotkey (⌃⌥. by default) — a panic revoke of the live
    /// remote-control grant. Grant-scoped (see `syncRevokeControlHotkey`) so
    /// idle sessions and pure viewers don't swallow ⌃⌥. system-wide.
    private var revokeControlHotkey: GlobalHotkey?

    /// Whether viewers may ask for remote control at all. Persisted via
    /// `RemoteControlDefaults`; synced to the live server so it takes effect
    /// mid-share (off declines pending `.controlRequest`s immediately).
    @Published var allowControlRequests: Bool = RemoteControlDefaults.load() {
        didSet {
            RemoteControlDefaults.save(allowControlRequests)
            server?.setAllowControlRequests(allowControlRequests)
        }
    }

    /// Viewer IPs whose *currently pending* control request already fired a
    /// notification. Keyed by IP so parallel connections collapse to one
    /// notification; pruned when the request leaves the pending snapshot, so
    /// a genuine re-request notifies again. Cleared on `stopSharing`.
    private var notifiedControlRequestIPs: Set<String> = []

    /// Link offers that already fired a notification, by offer id. Pruned
    /// with the offer. Cleared on `stopSharing`.
    private var notifiedLinkOfferIDs: Set<String> = []

    /// Highest grant-change generation applied so far. Reset when a new
    /// server is wired up and on `stopSharing`.
    private var lastControlGrantGeneration: UInt64 = 0

    /// True when a grant-change notification's generation is older than one
    /// already applied — the MainActor hop can reorder deliveries, and a
    /// stale nil snapshot applied last would unregister the panic hotkey
    /// while a grant is live. Equal generations are NOT stale (idempotent
    /// re-apply). Pure, for `RemoteControlPolicyTests`.
    nonisolated static func isStaleGrantNotification(generation: UInt64, lastApplied: UInt64) -> Bool {
        generation < lastApplied
    }

    /// True only when we *know* macOS won't display our notifications (user
    /// explicitly denied). Never true for "not asked yet".
    ///
    /// One-directional: `false` does NOT mean notifications will arrive (a
    /// Focus filter, revoked Time Sensitive, or alert style None are all
    /// invisible to the app) — so the UI only ever warns, never reassures.
    @Published private(set) var notificationsDenied = false

    /// Park new viewers pending explicit Accept/Deny. Persisted under
    /// `requireViewerApproval`, defaults **on** (tri-state migration in
    /// `ViewerApprovalPreference.load`); `TAILSCREEN_OPEN_DOOR=1` forces it
    /// off for scripted harnesses. Setter syncs the live server too.
    @Published var requireViewerApproval: Bool = ViewerApprovalPreference.load() {
        didSet {
            ViewerApprovalPreference.save(requireViewerApproval)
            server?.setRequireApproval(requireViewerApproval)
        }
    }

    // MARK: - Diagnostics

    /// Whether session diagnostics are being recorded. Resolved by
    /// `DiagnosticsPreference` against the build's release channel: on by
    /// default in a release candidate, off in a shipped release, on locally.
    /// An explicit choice outranks the channel and survives into the next
    /// candidate.
    ///
    /// Not a `didSet` (unlike `requireViewerApproval`): flipping this has to
    /// persist, move the recorder, AND attach/detach the log tee in order —
    /// `setRecordDiagnostics(_:)` is the one way in.
    @Published private(set) var recordDiagnostics: Bool =
        DiagnosticsPreference.load(channel: BuildInfo.releaseChannel)

    /// Turn recording on or off, persist the choice, and move the recorder.
    func setRecordDiagnostics(_ enabled: Bool) {
        guard enabled != recordDiagnostics else { return }
        AppDiagnostics.setRecording(enabled)
        // Read back what the recorder actually did rather than assume it:
        // `TAILSCREEN_DIAGNOSTICS` pins the live value, so under `=0` a
        // toggle-on must not claim to be recording.
        recordDiagnostics = AppDiagnostics.recorder?.isRecording ?? enabled
        if enabled {
            // Re-baseline the device snapshot: Settings may have enumerated
            // (and cached) while recording was off, and without this every
            // later enumeration compares equal and records nothing.
            lastRecordedAudioDevices = nil
            recordAudioDevicesIfChanged()
            // Same problem for surfaces: nothing re-fires `onAppear` just
            // because the switch moved, so replay what's currently visible.
            DiagnosticSurfaceTracker.shared.replayVisible()
        }
    }

    /// Write the current recording out and show the user where it went in
    /// Finder, rather than only naming a path they'd have to go find.
    func exportDiagnostics() {
        do {
            let url = try AppDiagnostics.export()
            logger.log("Diagnostics exported to \(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentError(
                .legacy(
                    title: L("Couldn't Export Diagnostics"),
                    message: L(
                        "The diagnostics file could not be written: \(error.localizedDescription)")
                ))
        }
    }

    /// Pick bundles somebody sent and merge them with this Mac's recording —
    /// `tailscreen-diagnostics-merge` does the same thing but needs a
    /// checkout and toolchain the person who hit the bug doesn't have.
    /// Multiple selection: a sharer with two viewers is three bundles.
    ///
    /// No content-type filter: `jsonl` has no registered UTI, so deriving one
    /// would grey out the files on any Mac that hasn't been taught the
    /// extension (i.e. all of them).
    func mergeDiagnostics() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = L("Choose the diagnostics files you were sent.")
        panel.prompt = L("Merge")
        // Open where this app's own exports land.
        panel.directoryURL = AppDiagnostics.exportDirectory

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        do {
            let url = try AppDiagnostics.merge(with: panel.urls)
            logger.log("Diagnostics merged to \(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentError(
                .legacy(
                    title: L("Couldn't Merge Diagnostics"),
                    message: L(
                        "The diagnostics could not be merged: \(error.localizedDescription)")
                ))
        }
    }

    // MARK: - Link sharing (share-by-token guests)

    /// Settings feature gate for sharing via link. Default on but inert until
    /// a share flips "Share via Link" on. Off hides the menubar section.
    @Published var linkSharingEnabled: Bool = LinkSharingDefaults.loadEnabled() {
        didSet { LinkSharingDefaults.saveEnabled(linkSharingEnabled) }
    }

    /// DERP relay map URL guests bootstrap through (self-hosted derper).
    /// Empty = Tailscale's public map. Snapshotted at link creation.
    @Published var linkShareRelayURL: String = LinkSharingDefaults.loadRelayURL() {
        didSet { LinkSharingDefaults.saveRelayURL(linkShareRelayURL) }
    }

    /// The live share link's token — non-nil exactly while the guest node is
    /// up. Dies with the share, the toggle, or a New Link rotation.
    @Published private(set) var shareLinkToken: String?

    /// True while the current share is guest-only (started signed out): the
    /// link section renders without its off-toggle (turning it off would
    /// strand the only way in) and the approval toggle hides (no tailnet
    /// viewers to approve).
    @Published private(set) var isGuestOnlyShare = false

    /// True while a link is being created or rotated (DERP bootstrap blocks).
    /// Drives the section's spinner and disables the toggle.
    @Published private(set) var shareLinkBusy = false

    /// User-facing reason the last link creation failed, cleared on the next
    /// attempt or with the share.
    @Published private(set) var shareLinkError: String?

    /// The pinned `WelcomePaneDecision` all three hubs read for the *sharing*
    /// half of the link feature (joining is never gated). This hub's `canShare`
    /// is the Settings link-sharing switch; `.sharingViaLink` must survive the
    /// gate closing underneath a live share.
    var welcomeLinkShareAction: WelcomePaneDecision.LinkShareAction {
        WelcomePaneDecision.linkShareAction(
            canShare: linkSharingEnabled,
            isIdle: !sharingState.isLive,
            isLinkOnlyShare: isGuestOnlyShare)
    }

    /// The link's whole lifecycle, portable: the guest node up and down,
    /// the attach/detach handshake with the server, New Link rotation, and
    /// the deny→tunnel-evict mapping. `SharerLinkSession` (TailscreenSharer)
    /// is the same object the GTK and WinUI engines drive; this app grew the
    /// logic first and its copy of the rules is gone.
    ///
    /// An actor, so every call below is an `await` and the ordering the
    /// rules depend on — detach before close, unwind a half-built link —
    /// lives there rather than in each caller. What stays here is the two
    /// things a hub owns: the published mirrors (`shareLinkToken`,
    /// `guestPeersByIP`) SwiftUI renders from synchronously, and the
    /// `onGuestViewerDenied` wire, which needs this app's server instance.
    ///
    /// Its own `AppLogger` because a property initializer cannot read
    /// `logger`; the type is a stateless `print` sink, so a second one costs
    /// nothing and both lines land in the same place.
    private let link = SharerLinkSession(logger: AppLogger())

    /// The share-generation stamp, so a bring-up that was superseded can
    /// tell. `SharerSessionCore` rather than a counter of this app's own:
    /// it is the same struct the GTK and WinUI engines stamp their shares
    /// with, pinned once in `SharerSessionCoreTests`, and the rule it
    /// encodes — an attempt from a share the app has moved on from must not
    /// publish, unwind, or release anything the current one owns — is the
    /// same rule on all three. Only the generation half is used here; the
    /// grant high-water mark has `lastControlGrantGeneration` and the
    /// invite queue has `pendingPreApprovedIPs`.
    private var shareCore = SharerSessionCore()

    /// Tunnel IP → admitted guest peer, mirrored from `link` whenever the
    /// roster changes while a link is live. Supplies the roster's key
    /// fingerprints — the mirror exists because those are read from a
    /// SwiftUI body, where the actor's `await` is not available.
    @Published private(set) var guestPeersByIP: [String: GuestPeer] = [:]

    /// Persistent per-peer allow/deny store behind "Always Allow" /
    /// "Deny & Block" and the Settings "Remembered viewers" list. Keyed by
    /// Tailscale StableNodeID. The live server never touches this store —
    /// it gets a value snapshot via `setAccessPolicies` at share start and
    /// on every change (see the `$entries` subscription in `init`).
    let viewerAccessPolicies = ViewerAccessPolicyStore()
    /// Multi-account profile registry (Tailscale-style): each profile owns
    /// a tsnet state directory; exactly one is active per process. See
    /// `switchProfile(to:)` / `addAccountAndSignIn()`.
    let profileStore = ProfileStore()
    /// True while `switchProfile(to:)` is tearing one node down and
    /// silently restoring the next profile's session. The main window
    /// shows a "Switching to …" pane for the duration — without it, the
    /// gap renders the signed-out welcome pane, which reads as "my login
    /// vanished".
    @Published private(set) var isSwitchingProfile = false

    /// Persistent Cloaked Apps list behind the Settings "Cloaked Apps" section:
    /// apps whose windows are hidden from viewers whenever a whole display
    /// is shared. Baked into `PickerSelection.excludedBundleIDs` at share
    /// start (`applyingShareTransforms`) and live re-pushed on every
    /// list/toggle change via the debounced `scheduleCloakRepush` (see the
    /// subscriptions in `init`).
    let appCloak = AppCloakStore()

    /// User preference: sharing-side quality knobs (fps cap, codec
    /// preference, encoder quality, bandwidth ceiling). Persisted as a
    /// JSON blob under `qualitySettings`. The bandwidth ceiling
    /// live-applies to an active share via `updateQualityCeiling`; the
    /// other knobs are snapshotted per share session
    /// (`server.start(quality:)`) and apply the next time sharing starts —
    /// the Settings pane says so in a caption.
    ///
    /// The save + live push are debounced (~500 ms, cancel-and-replace):
    /// each ceiling down-push forces an IDR at the helper, so an
    /// un-debounced Stepper run from 10 → 3 Mbps would burst seven
    /// keyframes. The UI reads the property directly, so it stays live.
    @Published var qualitySettings: QualitySettings = QualitySettingsStore.load() {
        didSet {
            qualitySettingsSyncTask?.cancel()
            qualitySettingsSyncTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                QualitySettingsStore.save(self.qualitySettings)
                self.server?.updateQualityCeiling(self.qualitySettings.maxBitrateBps)
            }
        }
    }

    /// Debounce task for `qualitySettings.didSet` (see above). MainActor,
    /// like everything else on AppState.
    private var qualitySettingsSyncTask: Task<Void, Never>?

    /// Opt the capture helper into 10-bit HEVC. A spawn-time env knob
    /// (`TAILSCREEN_ENABLE_10BIT`) pushed into
    /// `HelperScreenCapture.colorEnvironment`, so a mid-share flip applies on
    /// the next helper spawn, not instantly.
    @Published var enable10BitCapture: Bool = ColorCaptureDefaults.load10Bit() {
        didSet {
            guard enable10BitCapture != oldValue else { return }
            ColorCaptureDefaults.save10Bit(enable10BitCapture)
            pushColorCaptureEnvironment()
        }
    }

    /// Same knob for HDR (`TAILSCREEN_ENABLE_HDR`, implies 10-bit). The
    /// helper additionally gates it on the display having EDR headroom, so
    /// this is a request, not a promise.
    @Published var enableHDRCapture: Bool = ColorCaptureDefaults.loadHDR() {
        didSet {
            guard enableHDRCapture != oldValue else { return }
            ColorCaptureDefaults.saveHDR(enableHDRCapture)
            pushColorCaptureEnvironment()
        }
    }

    /// Project the two color toggles into the helper-spawn environment
    /// overlay. Explicit "0"s (not removal) so a Settings choice also
    /// overrides a launch-time env var.
    private func pushColorCaptureEnvironment() {
        // Snapshot on the MainActor first — `withLock`'s closure is
        // @Sendable, so it may not read actor-isolated properties.
        let overlay = [
            ColorCaptureDefaults.tenBitEnvKey: enable10BitCapture ? "1" : "0",
            ColorCaptureDefaults.hdrEnvKey: enableHDRCapture ? "1" : "0"
        ]
        HelperScreenCapture.colorEnvironment.withLock { $0 = overlay }
        // Live, not spawn-time: turning 10-bit ON while an incapable viewer
        // watches must latch the share to 8-bit before the next spawn.
        server?.setTenBitCaptureRequested(wantsTenBitCapture)
    }

    /// Either color toggle implies 10-bit (HDR is BT.2020 PQ, Main 10 in the
    /// helper); both are still gated there on display capability — this is
    /// the request, not the outcome.
    private var wantsTenBitCapture: Bool { enable10BitCapture || enableHDRCapture }

    // MARK: - Global hotkey chords

    /// User-configurable chord for the global mic toggle (⌃⌥M unless
    /// remapped). Persisted via `HotkeyChordStore`.
    @Published var micHotkeyChord: HotkeyChord = HotkeyChordStore.loadMic() {
        didSet {
            guard micHotkeyChord != oldValue else { return }
            HotkeyChordStore.saveMic(micHotkeyChord)
            registerMicHotkey()
            syncShortcutChordDisplays()
            viewerToolbar?.refreshMicChordDisplay()
        }
    }

    /// User-configurable chord for the panic revoke (⌃⌥. unless remapped).
    /// The real registration is grant-scoped (`syncRevokeControlHotkey`), so
    /// outside a grant the setter only *probes* it to keep
    /// `revokeHotkeyRegistered` honest.
    @Published var revokeHotkeyChord: HotkeyChord = HotkeyChordStore.loadRevoke() {
        didSet {
            guard revokeHotkeyChord != oldValue else { return }
            HotkeyChordStore.saveRevoke(revokeHotkeyChord)
            if revokeControlHotkey != nil {
                // A grant is live: tear the old registration down first (its
                // deinit unregisters) so (signature, id: 2) is free for the
                // replacement.
                revokeControlHotkey = nil
                syncRevokeControlHotkey(grantActive: true)
            } else {
                revokeHotkeyRegistered = GlobalHotkey.probeAvailability(
                    keyCode: revokeHotkeyChord.keyCode,
                    modifiers: revokeHotkeyChord.modifiers)
            }
            // The viewer-side twins: capture-layer intercept + cheat sheet.
            viewerControlInput?.releaseChord = revokeHotkeyChord
            syncShortcutChordDisplays()
        }
    }

    /// Whether the last (re)registration of each global hotkey actually took.
    /// `RegisterEventHotKey` refuses a chord another app already owns via a
    /// silent return code, so Settings → Keyboard Shortcuts shows a warning
    /// when either is false.
    @Published private(set) var micHotkeyRegistered = true
    @Published private(set) var revokeHotkeyRegistered = true

    /// "⌃⌥M"-style display strings, nil when the stored chord names a key
    /// outside the display vocabulary (consumers hide it rather than misprint).
    var micShortcutDisplay: String? { micHotkeyChord.displayString }
    var revokeShortcutDisplay: String? { revokeHotkeyChord.displayString }

    /// (Re)register the global mic-toggle hotkey. Tears any prior
    /// registration down first so (signature, id: 1) is free for the
    /// replacement.
    private func registerMicHotkey() {
        micHotkey = nil
        micHotkey = GlobalHotkey(
            keyCode: micHotkeyChord.keyCode,
            modifiers: micHotkeyChord.modifiers
        ) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.toggleMic()
            }
        }
        micHotkeyRegistered = micHotkey?.isRegistered ?? false
    }

    /// Debounce task + force latch for the Cloaked Apps live re-push (see
    /// `scheduleCloakRepush`).
    private var cloakSyncTask: Task<Void, Never>?
    private var cloakRepushForce = false

    /// Viewer IDs already sent a "joined" notification this session. Keyed
    /// by `"ip:port"` so a dropped-and-rejoined viewer gets a fresh ping but
    /// a hostname-resolution update doesn't double-fire. Cleared on
    /// `stopSharing`.
    private var notifiedViewerIDs: Set<String> = []

    /// Pending-viewer IDs already announced, same key and forget-on-leave
    /// rule as `notifiedViewerIDs`. Cleared on `stopSharing`.
    private var notifiedPendingViewerIDs: Set<String> = []

    /// Request-to-share source keys already announced, keyed by
    /// `PendingShareRequest.sourceKey` so a retry while the first ask is
    /// still on screen replaces one row. Not cleared on `stopSharing`: these
    /// arrive while idle and prune themselves when answered.
    private var notifiedShareRequestKeys: Set<String> = []

    /// The whole ask-to-share flow (idempotent-per-node control listener,
    /// bounded inbox, answer sequencing) is `TailscreenSharer`'s
    /// `SharerAskToShareCoordinator`, shared with GTK/Windows. What stays
    /// here: the `@Published` mirror, notification reconcile, and the
    /// metadata handler riding the same listener.
    private let askToShare = SharerAskToShareCoordinator()

    /// The coordinator's inbox, mirrored for the banner rows, the Dock badge
    /// and the notification-press router.
    @Published private(set) var pendingShareRequests: [PendingShareRequest] = []

    /// Requester IPs the sharer accepted (via request-to-share) but hasn't
    /// pushed to a live server yet — applied to `server.preApproveViewer`
    /// once the share starts. Cleared on `stopSharing`.
    private var pendingPreApprovedIPs: Set<String> = []

    /// "Always Allow" / "Deny & Block" intents recorded before the peer's
    /// StableNodeID resolved, keyed by the roster row's `ip:port` id, applied
    /// once a roster snapshot carries that id's stableID. The shared
    /// `ViewerRosterDecision.PendingIntents` (also used by GTK/WinUI): last-
    /// write-wins, and `prune` forgets an intent whose row is gone, so a
    /// disconnect-before-resolve can't land a block on the next machine to
    /// reuse that address behind one NAT.
    private var policyIntents = ViewerRosterDecision.PendingIntents()

    /// Set while a roster note is queued behind the current main-actor turn.
    /// See `scheduleNoteRoster()`.
    private var rosterNoteScheduled = false

    private var server: TailscaleScreenShareServer?
    private var client: TailscaleScreenShareClient?
    private var node: TailscaleNode?
    /// Where `node`'s bring-up got to, so `getOrCreateNode` can tell a node
    /// whose `up()` is still blocking (interactive login, hand it back) from
    /// one whose `up()` threw (dead, rebuild) from one that reached Running
    /// and may have died since (ask the backend).
    private enum NodeBringUpState { case notUp, upInFlight, up }
    private var nodeBringUpState: NodeBringUpState = .notUp
    private var sharerOverlay: SharerOverlayWindow?
    /// Border around the captured region for the whole share. Unlike
    /// `sharerOverlay` this is NOT lazy — it must be present whenever a
    /// capture is running, even if nobody draws anything.
    private var captureOutline: CaptureOutlineWindow?
    /// Decoded picker selection backing the current share, captured in
    /// `startSharing(filterData:)` so `ensureSharerOverlay` can scope itself
    /// to the shared window/app rather than always covering the full
    /// display.
    private var currentSelection: PickerSelection?

    // Persistent viewer window + renderer. Owned for the process lifetime:
    // closing/releasing the NSWindow + CAMetalLayer chain autoreleases pooled
    // IOSurfaces into a pool a Swift Task is about to pop, producing a
    // SIGSEGV on disconnect. Disconnect orderOuts the window and clears the
    // renderer's pending frame; connect reuses the existing instances.
    @Published var viewerWindow: NSWindow?

    /// The viewer window's name in the diagnostics surface trail. Reported
    /// at real `orderFront`/`orderOut` transitions, through the tracker's
    /// idempotent presence path (not a reference count, since
    /// `orderFrontRegardless` runs on every connect/refocus but `orderOut`
    /// runs once).
    static let viewerWindowSurface = "ViewerWindow"
    /// Preferences window, lazily created, kept for the process lifetime so
    /// reopening is instant and edits stay put.
    private var settingsWindow: NSWindow?
    /// Opens (or re-focuses) the docked main window scene. Stashed by the
    /// SwiftUI layer since `openWindow` is only reachable from view context,
    /// while callers here are AppKit menu items and popover rows.
    var openMainWindowAction: (@MainActor () -> Void)?
    private var viewerRenderer: MetalViewerRenderer?
    private var viewerOverlay: AnnotationOverlayHostView?
    /// Input-capture layer above the annotation overlay, active only while
    /// this viewer holds a remote-control grant. Framed to the video rect by
    /// `AspectFitHostView.layout`.
    private var viewerControlInput: RemoteControlInputView?
    /// Serialize captured input and locally drawn annotation ops onto the
    /// back-channel in production order. Two outboxes, not one: drawing and
    /// controlling are mutually exclusive in the UI, so the two streams
    /// never need ordering against each other.
    private var viewerInputOutbox: OrderedOutbox<InputEvent>?
    private var viewerAnnotationOutbox: OrderedOutbox<AnnotationOp>?
    /// The viewer window's aspect-fit host, owning the continuous zoom/pan
    /// state. Weak: the window's contentView holds it. Used to reset zoom on
    /// preset/video-size change/disconnect, and to route View-menu zoom.
    private weak var viewerHost: AspectFitHostView?
    /// Hosts the stats overlay subview pinned top-left. Held strongly so its
    /// visibility-toggle Combine subscription lives for the window's life.
    private var viewerStatsHost: ViewerStatsOverlayHost?
    /// Hosts the keyboard-shortcut cheat-sheet overlay. Toggled by the
    /// toolbar's "?" button and Help → Keyboard Shortcuts (⇧⌘/).
    private var viewerShortcutsHost: ViewerShortcutsOverlayHost?
    /// "Waiting for sharer to accept your connection" placard, shown between
    /// HELLO_PENDING and the first decoded frame.
    private var viewerWaitingPlacard: NSView?
    /// The placard's text field, so one placard can say either phase. Weak:
    /// the placard view owns it.
    private weak var viewerPlacardLabel: NSTextField?

    /// Set by `onDeniedBySharer` when a HELLO_DENY arrives — including while
    /// `connect()` is still `.connecting`. Read once by `connect()` after
    /// `client.connect()` returns so a deny that raced the connect doesn't
    /// get re-promoted to `.viewing`. Reset at the top of `connect()`.
    private var viewerWasDenied = false
    /// Orders `connect()` invocations across the suspension required to stop a
    /// previous client. The newest request alone may create the replacement.
    private var viewerConnectRequestID: UInt64 = 0

    /// Derived from the portable HELLO_PENDING phase. Drives the placard
    /// overlaid on the viewer window until HELLO_ACK admits this attempt.
    let viewerPresentation = ViewerPresentationState()
    var viewerAwaitingApproval: Bool {
        viewerPresentation.awaitingApproval
    }

    /// True from `connect()` until the sharer's HELLO_ACK admits us (SSRC
    /// assignment; the first decoded frame clears it too, belt-and-braces).
    /// `connect()` returns after HELLO but before admission, so `.viewing`
    /// alone would claim "Viewing" too early. Drives the "Connecting to
    /// <host>…" title.
    var isAwaitingAdmission: Bool {
        get { viewerPresentation.awaitingAdmission }
        set {
            guard newValue != viewerPresentation.awaitingAdmission else { return }
            viewerPresentation.setAwaitingAdmission(newValue)
            refreshViewerWindowTitle()
        }
    }

    /// Lifecycle projection for the in-window "session ended" state.
    /// Reconnect/dismiss/a fresh `connect()` clears it by transitioning the
    /// lifecycle, never by mutating a parallel slot.
    var viewerSessionEnding: ViewerSessionEnding? {
        viewerPresentation.ending
    }

    /// A terminal pane is on screen — ended OR failed. Use this, never
    /// `viewerSessionEnding != nil`, since `failed` is its own state now.
    var viewerSessionIsOver: Bool {
        viewerPresentation.isOver
    }

    /// What the in-window placard says right now, or nil to hide it. Two
    /// phases, one placard.
    private var viewerPlacardText: String? {
        switch viewerPresentation.placardPhase {
        case .connecting:
            let host = viewerPresentation.lifecycle.target?.displayName ?? ""
            return host.isEmpty ? L("Connecting…") : L("Connecting to \(host)…")
        case .awaitingApproval:
            return L("Waiting for the sharer to accept your connection…")
        default:
            return nil
        }
    }

    /// The terminal pane's copy: an end reason worded by `sessionEndedPresentation`,
    /// or a failure in its own words.
    private func viewerTerminalPresentation() -> ViewerSessionEndedModel.EndedState? {
        if let reason = viewerSessionEnding { return sessionEndedPresentation(reason) }
        guard let message = viewerPresentation.failureMessage else { return nil }
        // Its own title rather than "Session Ended": the session never opened.
        return .init(title: L("Connection Failed"), message: message)
    }

    /// True while the viewer session (current or connecting) runs over a
    /// guest tunnel. Drives the stats overlay's connection row and the
    /// join-flavored copy.
    var viewerIsGuestSession: Bool {
        viewerPresentation.isGuestSession
    }

    /// Apply portable lifecycle projections to the AppKit objects that cannot
    /// observe `ViewerPresentationState` themselves. Call once after every
    /// accepted lifecycle transition rather than maintaining parallel flags.
    private func syncViewerPresentationEffects() {
        let placardText = viewerPlacardText
        viewerWaitingPlacard?.isHidden = placardText == nil
        if let placardText { setViewerPlacardText(placardText) }
        viewerSessionEndedHost?.model.state = viewerTerminalPresentation()
        viewerRenderer?.statsModel.isGuestSession = viewerIsGuestSession
        refreshViewerWindowTitle()
    }

    /// Join-a-Share state. `joinInput` is the pasted token or link, shared
    /// by the sheet's field and the welcome pane's inline one — pre-filled
    /// by a `tailscreen:` URL open. One property rather than two because
    /// both fields drive the same `joinShare(input:)`, and a half-typed
    /// token surviving the hop between them is the friendly behaviour.
    @Published var joinSheetPresented = false
    @Published var joinInput = ""

    /// Hosts for the ended-state pane and the non-modal notice banner,
    /// built alongside the other viewer overlays in `ensureViewer`.
    private var viewerSessionEndedHost: ViewerSessionEndedOverlayHost?
    private var viewerNoticeBannerHost: ViewerNoticeBannerHost?
    /// Auto-dismiss task for the transient banner (cancel-and-replace).
    private var viewerNoticeDismissTask: Task<Void, Never>?

    /// Target trampoline for the waiting placard's Cancel button — AppKit
    /// target/action needs an NSObject, which AppState isn't.
    private var viewerPlacardCancelTarget: ClosureActionTarget?

    /// The video surface's accessibility stand-in (image role, "Shared
    /// screen from <host>"), framed to the fit rect by AspectFitHostView.
    private var viewerVideoAccessibilityView: ViewerVideoAccessibilityView?

    /// Standalone ⌘? cheat-sheet panel used while sharing, when there is
    /// no viewer window to overlay. Lazy, process-lifetime like the
    /// settings window.
    private var shortcutsPanelHost: ViewerShortcutsPanelHost?

    /// True when the shortcuts panel is on screen — read by ⌘? menu
    /// validation.
    var isShortcutsPanelVisible: Bool { shortcutsPanelHost?.isVisible ?? false }

    /// Set at viewer-window creation when a frame saved by a previous run
    /// was restored: the user put the window there, so the first-frame
    /// auto-snap must not fight it. Cleared by the View-menu size presets,
    /// which are an explicit "snap me" ask.
    private var viewerRestoredSavedFrame = false

    /// `frameAutosaveName` for the viewer window.
    private static let viewerFrameAutosaveName = "TailscreenViewerWindow"

    // Peer discovery
    @Published var availablePeers: [TailscreenPeer] = []
    @Published var isDiscovering = false
    /// User's peer-list filter (hide offline / by ACL tag), persisted like
    /// the quality settings so it survives relaunch. `availablePeers` stays
    /// the raw netmap-derived list — the filter UI needs it to enumerate
    /// every known tag and count hidden rows, and the
    /// `TAILSCREEN_AUTOCONNECT_TO` automation path must not be filtered.
    @Published var peerFilter: PeerListFilter = PeerListFilterStore.load() {
        didSet {
            guard peerFilter != oldValue else { return }
            PeerListFilterStore.save(peerFilter)
            // Turning the sharing-status axis on makes stale/missing
            // answers user-visible immediately — kick a fresh sweep so
            // rows fill in rather than sit hidden until the next open.
            if peerFilter.onlySharing && !oldValue.onlySharing {
                Task { @MainActor [weak self] in await self?.refreshPeerShareStatus() }
            }
        }
    }

    /// Fetched share status per peer. No entry means status-unknown (never
    /// fetched, offline, no answer, legacy build). Entries for peers that
    /// answered nothing are removed rather than left stale.
    @Published private(set) var peerShareInfo: [String: TailscreenMetadata] = [:]
    /// Rough per-peer round-trip estimate over the metadata TCP fetch —
    /// includes TCP setup, so read as a quality indicator, not a ping. Same
    /// lifecycle as `peerShareInfo`.
    @Published private(set) var peerLatencyMs: [String: Int] = [:]
    private var shareStatusRefreshInFlight = false

    /// The peers the main window's Screens list renders: `availablePeers`
    /// projected through `peerFilter` (pinned by `PeerListFilterTests`).
    var filteredPeers: [TailscreenPeer] {
        peerFilter.narrow(availablePeers, shareInfo: peerShareInfo)
    }

    /// Tags offered by the filter menu: every discovered peer's tags plus
    /// any currently-selected ones, so a tag whose peers left the tailnet
    /// stays listed long enough to be unselected.
    var knownPeerTags: [String] {
        peerFilter.knownTags(in: availablePeers)
    }
    /// True once any discovery pass has finished. The menubar devices
    /// section shows its loading skeleton until this flips, so an empty
    /// `availablePeers` before the first pass reads as "no answer yet", not
    /// "no devices". Reset on sign-out.
    @Published var hasCompletedInitialDiscovery = false
    /// Why the last node bring-up failed — the payload of
    /// `NodeBringUpPhase.failed`. The alert fires once, at the moment of
    /// failure; this is the state that outlives it on the welcome card whose
    /// button retries.
    ///
    /// Cleared when a fresh attempt starts and by every teardown, so a
    /// reason can't outlive the attempt or follow an account switch.
    @Published private(set) var nodeFailure: String?
    private var peerDiscovery: TailscalePeerDiscovery?
    /// The node the current `peerDiscovery` is bound to. Sign-out replaces
    /// the node; an identity mismatch tells `discoverPeers` to rebuild the
    /// watcher instead of reusing one bound to a closed node.
    private weak var peerDiscoveryNode: TailscaleNode?

    // IPN-bus watcher for the interactive-login URL: tsnet's `node.up()`
    // blocks until login completes, so this listens for the BrowseToURL it
    // emits and opens it in the user's browser.
    private var authIPNWatcher: TailscaleIPNWatcher?

    // Live thumbnail of the shared screen for the menu preview
    @Published var previewImage: NSImage?

    // One-shot continuation used by `startSharing` to hold the `isSharing`
    // flip until the first preview frame lands, so SharingCard never renders
    // its black "Capturing…" placeholder.
    private var pendingFirstPreview: CheckedContinuation<Void, Never>?

    // Authentication
    var tailscaleAuth = TailscaleAuth()

    // Metadata and requests
    @Published var metadataService = TailscreenMetadataService()

    /// Re-entrancy guard for `login()`, and half of `nodePhase`'s in-flight
    /// signal — `@Published` so the welcome card doesn't stay on "Signing
    /// in…" over a sign-in that already failed (this stays true when
    /// `nodeFailure` publishes in the `catch`, cleared only in the `defer`).
    @Published private var isLoggingIn = false

    // Gates whether the IPN-bus BrowseToURL handler opens a browser tab.
    // False during silent session restore at launch (a stale state file
    // can't pop an unsolicited sign-in tab); true once `login()` runs.
    private var interactiveLoginRequested = false

    // `[AppState]`-prefixed log sink, same per-file `TSLogger` pattern as the
    // screen-share + tsnet wrappers.
    private let logger = AppLogger()

    // NotificationCenter observer tokens added in `init`, removed in `deinit`
    // (else the weakly-retained closures keep firing on a dead instance).
    // `nonisolated(unsafe)`: `deinit` of a `@MainActor` class is itself
    // nonisolated, and only `init`/`deinit` mutate this.
    nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []

    // NSWorkspace's notification center + its launch-observer token (the
    // Cloaked Apps "cloaked app launched mid-share" trigger). Kept separate
    // from `notificationObservers` since those tokens belong to a different
    // center — removing from the wrong one silently leaks it.
    nonisolated(unsafe) private var workspaceNotificationCenter: NotificationCenter = .default
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []

    /// True once the user has manually resized the viewer window. Skips
    /// auto-snap on incoming video-size changes so the sharer's live resize
    /// drag doesn't tug the window out from under the user. Reset on
    /// disconnect and any `setViewerZoom` call.
    private var userResizedViewer: Bool = false
    /// Set around programmatic `setContentSize` calls so the synchronous
    /// `windowDidResize` callback isn't mistaken for a user resize.
    private var suppressViewerResizeTracking: Bool = false

    /// One-shot guard so the `E2E_MARKER firstFrame ...` log line fires once
    /// per viewer session, for the scripted harness's grep.
    private var didLogFirstViewerFrame: Bool = false

    init() {
        // Observe changes in tailscaleAuth and propagate them
        tailscaleAuth.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // Same forwarding for the profile registry, so the account menu
        // re-renders on add/switch/remove/identity updates.
        profileStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        viewerPresentation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // Browser-opening is host-app policy: TailscaleAuth is portable and
        // never touches NSWorkspace itself.
        tailscaleAuth.onOpenAuthURL = { NSWorkspace.shared.open($0) }

        // `@Published var metadataService` only fires when the *reference*
        // changes, not its inner `@Published` properties — mirror its
        // `objectWillChange` too.
        metadataService.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // The listener lifecycle, inbox and answer sequencing are the shared
        // coordinator's; these closures are the parts that are this host's.
        askToShare.onRequestReceived = { [weak self] hostname in
            self?.logger.log("Incoming request-to-share from \(hostname)")
        }
        askToShare.onRequestsChanged = { [weak self] requests in
            guard let self else { return }
            self.pendingShareRequests = requests
            // On every change (arrival AND answer): the notice for a request
            // answered in the app has to come down with it.
            self.refreshShareRequestNotices()
        }
        askToShare.onPreApproveViewer = { [weak self] sourceKey in
            guard let self else { return }
            // The sharer just consented to this peer, so pre-approve its
            // imminent HELLO rather than park it behind a redundant consent.
            self.pendingPreApprovedIPs.insert(sourceKey)
            self.server?.preApproveViewer(ip: sourceKey)
        }
        askToShare.onStartShare = { [weak self] in
            Task { await self?.presentNativePicker() }
        }
        askToShare.configureListener = { [weak self] listener in
            // Answer peer metadata queries on the same connection they
            // arrived on. Exposes nothing the tailnet can't already see.
            listener.onMetadataRequest = { [weak self, weak listener] connectionID in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, let listener else { return }
                    let metadata = self.metadataService.wireMetadata()
                    Task { await listener.send(.metadataResponse(metadata), to: connectionID) }
                }
            }
        }

        // Mirror the remembered-viewers store to the UI on every change,
        // including cosmetic display-name refreshes.
        viewerAccessPolicies.$entries.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // Push a fresh policy snapshot to the live server so Always Allow /
        // Deny & Block take effect mid-share — but ONLY when the
        // policy-by-StableNodeID projection changes, not on a cosmetic
        // display-name refresh.
        viewerAccessPolicies.$entries
            .map { ViewerAccessPolicyStore.policiesByStableID($0) }
            .removeDuplicates()
            .sink { [weak self] policies in
                self?.server?.setAccessPolicies(policies)
            }.store(in: &cancellables)

        // Mirror the Cloaked Apps store to the UI, and re-cloak a live share
        // when the list or the main toggle changes.
        appCloak.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        appCloak.$entries
            .map { entries in entries.map(\.bundleID) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleCloakRepush() }
            .store(in: &cancellables)
        appCloak.$isEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleCloakRepush() }
            .store(in: &cancellables)

        // A cloaked app *launching* mid-share can't be hidden by the running
        // helper: its SCContentFilter resolved applications at build time, so
        // an app not yet running never made the exclusion list. Watch for
        // launches and force a re-push (helper respawn).
        workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let launched =
                    note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = launched?.bundleIdentifier
                Task { @MainActor [weak self] in
                    guard let self, let bundleID else { return }
                    guard self.sharingState == .sharing,
                        let selection = self.currentSelection,
                        selection.excludedBundleIDs.contains(bundleID)
                    else { return }
                    self.scheduleCloakRepush(force: true)
                }
            }
        )

        // Try to restore a previous session silently; a stale/missing state
        // suppresses the BrowseToURL tab (`interactiveLoginRequested`) rather
        // than popping one unsolicited. Skipped in UI-preview mode: the
        // restore would overwrite the seeded signed-in state mid-screenshot.
        if Self.isUIPreview {
            seedUIPreview()
        } else {
            Task { @MainActor [weak self] in
                await self?.attemptSessionRestore()
            }
        }

        // Scripted local E2E harness affordances; see CLAUDE.md ("Local
        // screen-share E2E").
        if ProcessInfo.processInfo.environment["TAILSCREEN_AUTOSTART_SHARE"] == "1" {
            Task { @MainActor [weak self] in
                await self?.runAutoStartShare()
            }
        }
        let autoConnectTarget = ProcessInfo.processInfo.environment["TAILSCREEN_AUTOCONNECT_TO"]
        if let target = autoConnectTarget, !target.isEmpty {
            Task { @MainActor [weak self] in
                await self?.runAutoConnect(prefix: target)
            }
        }

        // The session is over without the user asking — sharer stop, idle
        // timeout, or a socket-error storm. End in the in-window "session
        // ended" state rather than the window silently vanishing.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenViewerPeerClosed,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let reason =
                    (note.userInfo?[ViewerCloseReason.userInfoKey] as? String)
                    .flatMap(ViewerCloseReason.init(rawValue:)) ?? .connectionLost
                let source = note.object as? TailscaleScreenShareClient
                Task { @MainActor [weak self, weak source] in
                    guard
                        let self,
                        let source,
                        source === self.client,
                        self.connectionState == .viewing,
                        let sessionID = self.viewerPresentation.lifecycle.sessionID
                    else { return }
                    await self.endViewerSession(
                        reason: Self.sessionEnding(for: reason), sessionID: sessionID)
                }
            }
        )

        // Viewer's decoder couldn't build a session for the stream's codec;
        // recovery (fallback to H.264) is imminent, so a transient banner,
        // not a modal alert.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenViewerDecodeFailed,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let codec = (note.userInfo?["codec"] as? String) ?? "this"
                let source = note.object as? TailscaleScreenShareClient
                Task { @MainActor [weak self, weak source] in
                    guard
                        let self,
                        let source,
                        source === self.client,
                        self.connectionState == .viewing
                    else { return }
                    self.showViewerNotice(
                        message: L(
                            "This Mac can't decode the \(codec) video stream. Asking the sharer to switch to H.264 — the picture should return in a moment."
                        ),
                        persistent: false)
                }
            }
        )

        // The decode-failure escalation ladder's last rung: a persistent
        // banner, replacing the alert that told the user to reconnect by
        // hand.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenViewerVideoStalled,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let source = note.object as? TailscaleScreenShareClient
                Task { @MainActor [weak self, weak source] in
                    guard
                        let self,
                        let source,
                        source === self.client,
                        self.connectionState == .viewing
                    else { return }
                    self.showViewerNotice(
                        message: L(
                            "Video has stalled — decoding keeps failing and automatic recovery hasn't helped."
                        ),
                        persistent: true,
                        actionTitle: L("Reconnect"),
                        action: { [weak self] in self?.reconnectViewerSession() })
                }
            }
        )

        // File → Disconnect (⌘W) posts this; bounce to disconnect(), or —
        // on the ended-state window — to a plain close.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenDisconnectRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if self.connectionState == .viewing {
                        await self.disconnect()
                    } else if self.viewerSessionIsOver {
                        self.dismissViewerWindow()
                    }
                }
            }
        )

        // File → Microphone / toolbar mic button posts this; bounce to toggleMic().
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenToggleMicrophone,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.toggleMic()
                }
            }
        )

        // View → Actual Size / 50% / 200% — explicit reset for users who
        // dragged the window to a custom size and want to snap back.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenViewerSetZoom,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let factor = (note.userInfo?["factor"] as? Double) ?? 1.0
                Task { @MainActor [weak self] in
                    self?.setViewerZoom(CGFloat(factor))
                }
            }
        )

        // ⌃⌥M (by default — Settings → Keyboard Shortcuts can remap it)
        // from anywhere — toggle mic without finding the menubar popover
        // or clicking through. Useful during a screen share when the
        // popover isn't visible.
        registerMicHotkey()

        // The ⌃⌥. panic-revoke hotkey is grant-scoped
        // (`syncRevokeControlHotkey`), not registered here, so idle sessions
        // don't swallow it system-wide. Probe the chord once anyway so
        // Settings can warn about a combo another app owns.
        revokeHotkeyRegistered = GlobalHotkey.probeAvailability(
            keyCode: revokeHotkeyChord.keyCode,
            modifiers: revokeHotkeyChord.modifiers)

        // Seed the helper-spawn environment overlay with the persisted
        // color-capture opt-ins (the didSet only fires on later changes).
        pushColorCaptureEnvironment()

        ViewerCommands.shared.appState = self

        // Poll every 2s: any other Tailscreen instance on this Mac holding
        // the share lock? Drives the Share button's disabled state.
        let probe = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let othersSharing = !self.shareLock.isHeldBySelf && ShareLock.isHeldByAnyone()
                if othersSharing != self.anotherInstanceSharing {
                    self.anotherInstanceSharing = othersSharing
                }
            }
        }
        RunLoop.main.add(probe, forMode: .common)
        shareLockProbeTimer = probe

        // Posted by the SIGTERM/SIGINT trap just before terminate.
        // `applicationWillTerminate` alone fires too late via the run loop:
        // on a fast SIGTERM→SIGKILL chain the helper could still be running
        // when the main process vanishes, orphaning the SCStream session.
        NotificationCenter.default.addObserver(
            forName: .tailscreenWillTerminateBySignal,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.synchronouslyTerminateHelpers()
        }
    }

    /// Synchronous best-effort kill of any active capture-helper child,
    /// called before `NSApplication.terminate` so replayd sees it die and
    /// releases the SCStream slot deterministically. Safe if none is active.
    nonisolated func synchronouslyTerminateHelpers() {
        // Background queue with a short timeout — can't block forever in
        // the signal-handler tail.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            Task { @MainActor in
                await self.server?.stop()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + .seconds(2))
    }

    deinit {
        // `removeObserver` is thread-safe, so no Task hop needed here (which
        // would be unsafe per CLAUDE.md's "no Task { self } in deinit").
        let center = NotificationCenter.default
        for token in notificationObservers {
            center.removeObserver(token)
        }
        for token in workspaceObservers {
            workspaceNotificationCenter.removeObserver(token)
        }
    }

    private var cancellables = Set<AnyCancellable>()

    /// Spawn the `--picker-helper` subprocess to present the native
    /// `SCContentSharingPicker`. User cancellation is silent. macOS drives
    /// the Screen Recording TCC prompt inside the helper; the parent process
    /// never preflights it.
    func presentNativePicker() async {
        guard let filterData = await runPickerOrAlert() else {
            return
        }
        await startSharing(filterData: filterData)
    }

    /// Spawn the `--picker-helper` subprocess and return the JSON
    /// `PickerSelection` bytes. Returns nil on user cancel, or on spawn
    /// failure after surfacing the alert — one error surface shared by
    /// `presentNativePicker()` and `changeShareSource()`.
    private func runPickerOrAlert() async -> Data? {
        do {
            return try await PickerHelperClient.run()
        } catch {
            showAlertMessage(
                title: L("Couldn't Open Picker"),
                message: L("macOS's screen-sharing picker failed to start: \(error.localizedDescription)")
            )
            return nil
        }
    }

    /// Bake sharer-side settings into the picker's selection bytes:
    /// `captureAudio = true` (so the helper's `.audio` output exists;
    /// emission stays gated by the `setAudioEnabled` latch) and the Cloaked
    /// Apps exclusion list. Shared by `startSharing` and `changeShareSource`
    /// so the two bring-up paths can't drift. Updates `currentSelection` on
    /// success; a decode/encode failure falls back to the original bytes.
    private func applyingShareTransforms(to filterData: Data) -> Data {
        guard let selection = try? JSONDecoder().decode(PickerSelection.self, from: filterData)
        else { return filterData }
        let transformed =
            selection
            .settingCaptureAudio(true)
            .settingExcludedBundleIDs(appCloak.effectiveExclusions(for: selection.kind))
        guard let reencoded = try? JSONEncoder().encode(transformed) else { return filterData }
        currentSelection = transformed
        return reencoded
    }

    /// Coalesce Cloaked Apps edits into one helper respawn (~500ms
    /// cancel-and-replace). `force` skips the no-change guard — used when a
    /// cloaked app *launches* mid-share: the exclusion list is
    /// byte-identical, but the live filter was built before the app existed.
    private func scheduleCloakRepush(force: Bool = false) {
        cloakRepushForce = cloakRepushForce || force
        cloakSyncTask?.cancel()
        cloakSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            let forced = self.cloakRepushForce
            self.cloakRepushForce = false
            await self.applyCloakToActiveShare(force: forced)
        }
    }

    /// Re-bake the Cloaked Apps exclusions into the cached selection and
    /// retarget the live capture-helper. No-op unless a share is active and
    /// the exclusion set changed (or `force`). Rides the same
    /// `server.changeSource` restart path as "Change Source…"; the overlay
    /// and annotations are untouched since the shared surface is unchanged.
    private func applyCloakToActiveShare(force: Bool) async {
        guard sharingState == .sharing, let server, let selection = currentSelection else { return }
        let exclusions = appCloak.effectiveExclusions(for: selection.kind)
        guard force || exclusions != selection.excludedBundleIDs else { return }
        let updated = selection.settingExcludedBundleIDs(exclusions)
        guard let data = try? JSONEncoder().encode(updated) else { return }
        currentSelection = updated
        do {
            _ = try await server.changeSource(filterData: data)
            logger.log("appCloak: re-pushed cloak to live share (\(exclusions.count) cloaked)")
        } catch is CancellationError {
            // Share stopped while the re-push was in flight — the stop path
            // owns teardown.
        } catch {
            logger.log("appCloak: live re-push failed (\(error)); tearing sharing down")
            await stopSharing(reason: "appCloak repush failed: \(error)")
            presentError(.sharingGeneric(error))
        }
    }

    /// Tailnet-visible hostname for this instance. Shared by `startSharing`
    /// and `changeShareSource` so the strings can't drift apart.
    private static func localHostname() -> String {
        "\(Host.current().localizedName ?? "tailscreen-share")\(TailscreenInstance.hostnameSuffix)"
    }

    /// Share name published to peers. Deliberately not localized — it
    /// travels to viewers of unknown locale.
    private static func localShareName() -> String {
        "\(localHostname())'s Screen"
    }

    /// Mid-share "Change Source…": re-run the picker-helper and retarget the
    /// live server *without* disconnecting viewers or releasing the share
    /// lock. Picker cancel/error leaves the share untouched; a failed
    /// retarget tears it down (the old helper is already gone by then). A
    /// racing Stop Sharing is a quiet no-op — every success effect below is
    /// gated on a post-await re-validation.
    ///
    /// Separate from `presentNativePicker()`, the share *entry point*: this
    /// one requires an already-active share.
    func changeShareSource() async {
        guard sharingState == .sharing, let server, !isChangingSource else { return }
        isChangingSource = true
        defer { isChangingSource = false }

        guard let filterData = await runPickerOrAlert() else {
            return
        }
        // The user may have clicked Stop Sharing (or the helper may have
        // died past its crash budget) while the picker was up. Identity-check
        // the server so a stale selection can't retarget an ended/restarted
        // share.
        guard sharingState == .sharing, self.server === server else { return }

        currentSelection = try? JSONDecoder().decode(PickerSelection.self, from: filterData)
        let effectiveFilterData = applyingShareTransforms(to: filterData)
        let didRetarget: Bool
        do {
            didRetarget = try await server.changeSource(filterData: effectiveFilterData)
        } catch is CancellationError {
            // A deliberate stop mid-retarget, not a retarget failure — the
            // stop path owns teardown.
            logger.log("changeShareSource: share stopped mid-retarget — leaving teardown to the stop path")
            return
        } catch {
            logger.log("changeShareSource: retarget failed (\(error)); tearing sharing down")
            await stopSharing(reason: "changeSource failed: \(error)")
            presentError(.sharingGeneric(error))
            return
        }

        // Re-validate after the awaits: the share may have been torn down
        // (or restarted with a fresh server) while the retarget was in
        // flight. Running the success effects below against a stopped share
        // would resurrect overlay state the stop path just tore down.
        guard didRetarget, sharingState == .sharing, self.server === server else {
            logger.log("changeShareSource: share ended mid-retarget — skipping success side effects")
            return
        }

        // Annotations were scoped to the old surface, so clear every
        // viewer's canvas (the sharer's is cleared by the overlay rebuild
        // below). Queued so it lands AFTER strokes still in the outbox.
        server.enqueueAnnotationBroadcast(.clearAll)

        // The overlay's mode is immutable — rebuild for the new selection,
        // preserving the draw toggle. Leave nil when off:
        // `ensureSharerOverlay` lazily rebuilds on the next op or toggle.
        let wasDrawing = isSharerOverlayVisible
        sharerOverlay?.hide()
        sharerOverlay = nil
        if wasDrawing {
            ensureSharerOverlay().setInputEnabled(true)
        }
        // Same reason: the outline's mode is fixed at construction, so it
        // must be rebuilt or it keeps framing the wrong region.
        showCaptureOutline()

        // Refresh metadata and drop the stale thumbnail — the fresh helper
        // repopulates it. Viewers need no signaling: the new helper's first
        // AU is an IDR with in-band parameter sets.
        metadataService.updateMetadata(isSharing: true, shareName: Self.localShareName())
        previewImage = nil
        logger.log("changeShareSource: retargeted capture (filter=\(filterData.count)B)")
    }

    /// Start a share against the `PickerSelection` produced by the picker
    /// subprocess. The JSON-encoded selection is cached on the server so a
    /// mid-stream helper crash can rebuild the same SCStream without
    /// re-presenting the picker.
    func startSharing(filterData: Data) async {
        // Take the cross-instance share lock first: another local instance
        // already capturing would make replayd refuse our SCStream anyway.
        // A new session gets its own protected prologue, so this share's
        // handshake cannot be evicted by an earlier one's traffic.
        AppDiagnostics.recorder?.beginSession()
        AppDiagnostics.action(.actionShareStart)
        guard shareLock.tryAcquire() else {
            anotherInstanceSharing = true
            showAlertMessage(
                title: "Another Tailscreen Is Sharing",
                message:
                    "Another Tailscreen instance on this Mac is already capturing the screen. Stop sharing on the other instance, then try again."
            )
            return
        }
        // Re-read notification authorization at every share start — the
        // one-shot prompt is answered once, but the user can revoke it later,
        // and with approval defaulting on, a sharer without banners strands
        // viewers silently. Lands on `notificationsDenied`.
        SharerNoticeCenter.shared.onAuthorizationChanged = { [weak self] state in
            self?.notificationsDenied = (state == .denied)
        }
        SharerNoticeCenter.shared.refreshAuthorization()
        // Decode so the sharer overlay (built lazily) can scope its panel to
        // the shared window/app. A decode failure falls back to the legacy
        // full-display overlay.
        currentSelection = try? JSONDecoder().decode(PickerSelection.self, from: filterData)
        // Bake system-audio output + Cloaked Apps exclusions into the bytes
        // the server caches.
        let effectiveFilterData = applyingShareTransforms(to: filterData)
        // A share started while signed out can only be reached by link: run
        // it guest-only (the guest node is the whole transport).
        let guestOnly = !tailscaleAuth.isAuthenticated
        let generation = shareCore.beginShare()
        sharingState = .starting
        // Why this attempt failed, if it did — read by the `defer` below
        // rather than assigned per failure site, so every exit funnels
        // through one cleanup block.
        var startFailure: String?
        // Cleanup contract: any exit (success/failure/cancellation) leaves
        // `sharingState` consistent. Success sets `.sharing` below; this
        // defer is the safety net for anything else.
        defer {
            // Only for the share this attempt is: a stop that let a
            // REPLACEMENT start means the `.starting` on screen is theirs.
            if shareCore.isCurrentShare(generation), sharingState == .starting {
                // A reason if recorded, idle otherwise — user cancellation
                // isn't a failure to report.
                sharingState = startFailure.map { .failed($0) } ?? .idle
                shareLock.release()
                // A share that never reached `.sharing` must not leave a
                // border on screen claiming one is running.
                captureOutline?.hide()
                captureOutline = nil
            }
        }
        if guestOnly && !linkSharingEnabled {
            // The welcome pane hides its Share-via-Link button behind the
            // same gate, so reaching here means Settings changed underneath
            // an open picker.
            let failure = AppError.linkSharingDisabled()
            startFailure = failure.message
            presentError(failure)
            return
        }
        do {
            // If Tailscale is already initialized, just start sharing
            // Otherwise, initialize it first
            if server == nil {
                let hostname = Self.localHostname()
                let srv = TailscaleScreenShareServer()
                srv.recorder = AppDiagnostics.recorder
                server = srv

                // SCStream can die from two distinct causes:
                //   1. User clicks the macOS Control Center "Stop" button —
                //      reported as SCStreamErrorDomain / .userStopped. Tear
                //      sharing down quietly; the menubar icon already
                //      reflects the new idle state.
                //   2. replayd drops its XPC connection mid-stream — any
                //      other error (or nil). Transient, recoverable,
                //      viewer is still connected and waiting for video.
                //      Try restartCapture once; only fall through to a
                //      teardown if recovery fails.
                srv.onCaptureStopped = { [weak self] error in
                    Task { @MainActor [weak self] in
                        // React in either `.starting` (helper crashed
                        // during bring-up) or `.active` (helper died
                        // mid-share). The earlier guard limited this
                        // to `.active` only, which left the UI stuck
                        // on "Starting share…" indefinitely when the
                        // first SCStream attempt got `-3805` and our
                        // crash budget was exhausted.
                        guard let self else { return }
                        guard self.sharingState == .sharing || self.sharingState == .starting else { return }
                        let desc = error?.localizedDescription ?? "nil"
                        switch Self.captureStopAction(error) {
                        case .userInitiated:
                            await self.stopSharing(reason: "SCStream userStopped: \(desc)")
                        case .connectionLost:
                            // The share's UDP control loop is dead — that's
                            // not something a fresh capture helper can fix,
                            // so skip the restart path and tear down. Tell
                            // the user: the share ending on its own must
                            // not be a silent mystery.
                            self.logger.log("Share receive loop dead (\(desc)); tearing sharing down.")
                            await self.stopSharing(reason: "receive loop dead: \(desc)")
                            self.showAlertMessage(
                                title: L("Sharing Stopped"),
                                message: L(
                                    "The connection to your viewers was lost and couldn't be re-established, so the share was stopped. Check the network and start sharing again."
                                ))
                        case .helperUnrecoverable:
                            // Non-retryable helper *error*: another instance
                            // holds the capture slot, a decode failure, etc.
                            // Respawning just hits the same wall, so tear down
                            // and say why — otherwise the menubar stays
                            // "sharing" with frozen capture and viewers are
                            // never released.
                            self.logger.log("Capture stopped unrecoverably (\(desc)); tearing sharing down.")
                            await self.stopSharing(reason: "helper unrecoverable: \(desc)")
                            self.showAlertMessage(
                                title: L("Sharing Stopped"),
                                message: L(
                                    "Screen sharing couldn't continue because the capture source became unavailable. Start sharing again to pick a new source."
                                ))
                        case .sourceClosed:
                            // Expected stop: the user closed the shared window
                            // or app. Tear the share down (nothing left to
                            // capture) but report it as a gentle notice, not an
                            // error — this wasn't a failure.
                            self.logger.log("Shared source closed (\(desc)); stopping share.")
                            await self.stopSharing(reason: "shared source closed: \(desc)")
                            self.presentNotice(
                                title: L("Sharing Stopped"),
                                message: L(
                                    "The window you were sharing was closed, so screen sharing stopped."
                                ))
                        case .attemptRestart:
                            guard let server = self.server else { return }
                            do {
                                try await server.restartCapture()
                                self.logger.log("ScreenCapture: restarted after mid-stream stop.")
                            } catch {
                                self.logger.log("ScreenCapture: restart failed (\(error)); tearing sharing down.")
                                await self.stopSharing(reason: "SCStream restart failed: \(error)")
                            }
                        }
                    }
                }
                srv.onPreviewImage = { [weak self] jpeg in
                    // The portable server hands up encoded bytes; decoding
                    // to `NSImage` is this host's job.
                    guard let image = NSImage(data: jpeg) else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.previewImage = image
                        if let cont = self.pendingFirstPreview {
                            self.pendingFirstPreview = nil
                            cont.resume()
                        }
                    }
                }

                // Viewer-originated annotations land on the sharer's overlay
                // panel. In display mode SCStream captures the panel too, so
                // drawings reach every viewer via the H.264 stream for free;
                // in window/app modes the panel isn't captured, so those
                // modes only mirror strokes back to the sharer.
                srv.onAnnotationReceived = { [weak self] op in
                    Task { @MainActor [weak self] in
                        self?.ensureSharerOverlay().apply(remoteOp: op)
                    }
                }

                srv.onViewersChanged = { [weak self] viewers in
                    Task { @MainActor [weak self] in
                        self?.handleViewersChanged(viewers)
                    }
                }

                srv.onPendingViewersChanged = { [weak self] pending in
                    Task { @MainActor [weak self] in
                        self?.handlePendingViewersChanged(pending)
                    }
                }

                srv.onControlRequestsChanged = { [weak self] requests in
                    Task { @MainActor [weak self] in
                        self?.handleControlRequestsChanged(requests)
                    }
                }

                srv.onLinkOffersChanged = { [weak self] offers in
                    Task { @MainActor [weak self] in
                        self?.handleLinkOffersChanged(offers)
                    }
                }

                lastControlGrantGeneration = 0  // fresh server, fresh counter
                srv.onControlGrantChanged = { [weak self] generation, grant in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // The Task hop can reorder deliveries; apply only
                        // monotonically newer generations.
                        guard
                            !Self.isStaleGrantNotification(
                                generation: generation,
                                lastApplied: self.lastControlGrantGeneration)
                        else { return }
                        self.lastControlGrantGeneration = generation
                        self.controlGrantee = grant
                        // Grant-scoped panic hotkey: revoke/stop/disconnect
                        // all funnel through this callback.
                        self.syncRevokeControlHotkey(grantActive: grant != nil)
                    }
                }

                srv.onControlAccessibilityRequired = { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.presentAccessibilityRequiredAlert()
                    }
                }

                // Sync toggle state to the server before `start()` so a
                // viewer racing to HELLO during bring-up is caught.
                srv.setRequireApproval(requireViewerApproval)
                srv.setAccessPolicies(viewerAccessPolicies.policiesByStableID)
                srv.setAllowControlRequests(allowControlRequests)
                // Apply the persisted default before the helper (re)spawns so
                // the latch is in place when it comes up.
                isSystemAudioOn = shareSystemAudioByDefault
                srv.setShareSystemAudio(shareSystemAudioByDefault)
                // The env overlay tells the HELPER what to capture; this
                // tells the SERVER whether to police viewers' `.tenBit`.
                srv.setTenBitCaptureRequested(wantsTenBitCapture)
                // Carry over request-to-share pre-approvals so an accepted
                // requester's HELLO auto-admits on this fresh server. Cleared
                // as replayed: holding one past the handover would re-invite
                // a peer on a later rebuild of the same share.
                for ip in pendingPreApprovedIPs {
                    srv.preApproveViewer(ip: ip)
                }
                pendingPreApprovedIPs.removeAll()

                // Sharer's audio SSRC is fixed at 0. Build the channel up
                // front so inbound viewer audio can decode, and start
                // playback immediately so the sharer can hear viewers
                // without toggling their own mic on first.
                do {
                    let voice = try VoiceChannel(localSSRC: RTPHeader.sharerVoiceSSRC) { [weak srv] packet in
                        srv?.sendAudioRTP(packet)
                    }
                    self.voiceChannel = voice
                    self.publishOutputDeviceToVoice()
                    srv.onAudioReceived = { [weak voice] packet in
                        voice?.receive(packet)
                    }
                    let cap = MicCapture(channel: voice)
                    try cap.startPlayback()
                    self.micCapture = cap
                } catch {
                    presentError(.voiceInitFailed(error))
                }

                // Non-nil once the link-only path has minted, so the paths
                // below unwind exactly what this attempt created.
                var mintedLink: String?
                do {
                    if guestOnly {
                        // The guest node comes up first (it is the whole
                        // transport); `startLinkOnly` owns that ordering and
                        // unwinds its own node if any step throws. Eviction
                        // is wired before it, since a guest can arrive as
                        // soon as the server is up.
                        wireGuestEviction(on: srv)
                        let minted = try await link.startLinkOnly(
                            on: srv,
                            filterData: effectiveFilterData,
                            quality: qualitySettings,
                            relayMapURL: linkRelayMapURL)
                        mintedLink = minted
                        // Stop Sharing can land inside that await; the mint
                        // is scoped to itself so a replacement share's link
                        // isn't what gets closed.
                        guard shareCore.isCurrentShare(generation) else {
                            await link.teardown(mintedToken: minted)
                            throw CancellationError()
                        }
                        shareLinkToken = minted
                        isGuestOnlyShare = true
                    } else {
                        // Reuse the AppState-owned tsnet node rather than
                        // spinning up a second machine with its own login.
                        let sharedNode = try await getOrCreateNode()
                        try await srv.start(
                            hostname: hostname,
                            filterData: effectiveFilterData,
                            quality: qualitySettings,
                            existingNode: sharedNode,
                            controlListener: askToShare.controlListener
                        )
                    }
                } catch {
                    // Tear down anything `start` brought up so a future Start
                    // Sharing rebuilds from scratch, guest node included.
                    await srv.stop()
                    // A REPLACEMENT share may already own `server`/the token
                    // by now; the unwind below is scoped to this attempt.
                    let isCurrent = shareCore.isCurrentShare(generation)
                    if let mintedLink { await link.teardown(mintedToken: mintedLink) }
                    guard isCurrent else { return }
                    server = nil
                    shareLinkToken = nil
                    isGuestOnlyShare = false
                    // A CancellationError means the user clicked Stop Sharing
                    // mid-bring-up — no alert for an intentional cancel.
                    if error is CancellationError {
                        return
                    }
                    let failure: AppError
                    if case ScreenCaptureError.startTimeout = error {
                        failure = .screenCaptureStartTimeout()
                    } else if case ScreenCaptureError.bundleSlotPoisoned = error {
                        failure = .screenCaptureBundlePoisoned()
                    } else if case ScreenCaptureError.noFramesDelivered = error {
                        failure = .screenCaptureNoFrames()
                    } else if guestOnly {
                        // Most likely the relay bootstrap or guest node, not
                        // screen capture.
                        failure = .linkShareStartFailed(error)
                    } else {
                        failure = .screenCaptureGeneric(error)
                    }
                    // Both: the alert fires once, the card keeps the reason.
                    startFailure = failure.message
                    presentError(failure)
                    return
                }
            }

            // Update metadata
            metadataService.updateMetadata(isSharing: true, shareName: Self.localShareName())

            // Hold the UI on the picker until the first preview frame
            // arrives, so SharingCard skips its black "Capturing…"
            // placeholder.
            await waitForFirstPreview(timeout: .milliseconds(500))

            // Raise the outline once capture is genuinely running — earlier
            // would frame a share that may still fail to start.
            showCaptureOutline()

            sharingState = .sharing

            // Automation affordance (e2e scripts): mint the link and print a
            // greppable marker so a second instance can join by token.
            if ProcessInfo.processInfo.environment["TAILSCREEN_AUTOSHARE_LINK"] == "1" {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.shareLinkToken == nil {
                        await self.enableShareLink()
                    }
                    if let token = self.shareLinkToken {
                        self.logger.log("E2E_MARKER shareLink token=\(token)")
                    }
                }
            }
        } catch {
            // Record it for the `defer`, which publishes the phase. The
            // inner `do`'s own catch returns before reaching here, so this
            // covers the paths before it and anything added after.
            let failure = AppError.sharingGeneric(error)
            startFailure = failure.message
            presentError(failure)
        }
    }

    /// Reentrancy guard for `stopSharing`: the give-up paths can fire
    /// `onCaptureStopped` concurrently with a user-initiated Stop Sharing,
    /// interleaving across await points and double-running `server.stop()`.
    private var isStoppingShare = false

    func stopSharing(reason: String = "<unknown>", caller: String = #function) async {
        if isStoppingShare {
            logger.log("stopSharing: already in progress — ignoring reentrant call by \(caller) (reason=\(reason))")
            return
        }
        isStoppingShare = true
        defer { isStoppingShare = false }
        logger.log("stopSharing: called by \(caller) (reason=\(reason))")
        // A lifecycle event, NOT `action.share.stop`: this is the teardown
        // funnel for capture failure, a dead receive loop, sign-out, quit,
        // etc, not just the Stop button. Recording every one as a user
        // action would falsely claim the person stopped the share.
        AppDiagnostics.recorder?.record(
            .sharePhaseChanged,
            fields: [
                "to": .string("idle"),
                "reason": .string(reason),
                "caller": .string(caller)
            ])
        // Unblock any startSharing still waiting on the first preview, so a
        // fast start→stop doesn't strand its continuation.
        if let cont = pendingFirstPreview {
            pendingFirstPreview = nil
            cont.resume()
        }

        // Ends the generation first, so a bring-up suspended inside
        // `startSharing` learns it was superseded before it can publish a
        // token or arm an outline this stop is clearing.
        shareCore.endShare()
        let stopping = server
        await server?.stop()
        server = nil
        // The token dies with the share; server.stop() already sent everyone
        // SERVER_BYE, so only the guest node is left to tear down. Passed by
        // server, not token, since a mid-bootstrap link toggle has no token
        // yet and only its own server can invalidate the claim.
        await link.teardown(for: stopping)
        shareLinkToken = nil
        shareLinkError = nil
        guestPeersByIP = [:]
        isGuestOnlyShare = false
        micCapture?.stop()
        micCapture = nil
        voiceChannel = nil
        isMicOn = false
        isSystemAudioOn = false
        previewImage = nil
        currentViewers = []
        pendingViewers = []
        controlRequests = []
        linkOffers = []
        controlGrantee = nil
        revokeControlHotkey = nil
        lastControlGrantGeneration = 0
        // Take the actionable banners down with the share — their buttons
        // can do nothing once the server is gone. Withdrawn before the sets
        // are cleared, since the sets are the record of what was posted.
        SharerNoticeCenter.shared.withdraw(
            kind: .viewerPending, identities: Array(notifiedPendingViewerIDs))
        SharerNoticeCenter.shared.withdraw(
            kind: .controlRequested, identities: Array(notifiedControlRequestIPs))
        SharerNoticeCenter.shared.withdraw(
            kind: .linkOffered, identities: Array(notifiedLinkOfferIDs))
        notifiedControlRequestIPs.removeAll()
        notifiedLinkOfferIDs.removeAll()
        notifiedViewerIDs.removeAll()
        notifiedPendingViewerIDs.removeAll()
        pendingPreApprovedIPs.removeAll()
        // The rows are gone, and an intent that outlived the share would
        // apply to whoever connects to the NEXT one from the same address.
        policyIntents = ViewerRosterDecision.PendingIntents()

        // Update metadata
        metadataService.updateMetadata(isSharing: false)

        // Stop peer monitoring if active
        peerDiscovery?.stopRealTimeMonitoring()

        sharerOverlay?.hide()
        sharerOverlay = nil
        isSharerOverlayVisible = false
        captureOutline?.hide()
        captureOutline = nil
        currentSelection = nil

        sharingState = .idle
        shareLock.release()
    }

    /// Suspend until the first preview frame lands or `timeout` elapses,
    /// whichever comes first. Both resume paths run on the main actor and
    /// gate on `pendingFirstPreview != nil`, so there's no double-resume.
    private func waitForFirstPreview(timeout: Duration) async {
        guard previewImage == nil else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pendingFirstPreview = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let pending = self.pendingFirstPreview else { return }
                self.pendingFirstPreview = nil
                pending.resume()
            }
        }
    }

    /// (Re)build the capture outline for the current selection and show it.
    ///
    /// Called at share start and again after a mid-share "Change Source…",
    /// because the outline's mode — like the annotation overlay's — is fixed
    /// at construction. It reuses `overlayMode(for:)`, the same pure
    /// projection `OverlayModeDecisionTests` covers, so the outline and the
    /// annotation panel can never disagree about where the shared region is.
    private func showCaptureOutline() {
        captureOutline?.hide()
        let outline = CaptureOutlineWindow(mode: Self.overlayMode(for: currentSelection))
        outline.show()
        captureOutline = outline
    }

    /// Create the sharer overlay lazily so it's always present when needed —
    /// either the sharer toggles input on, or a viewer sends us an op.
    /// In display mode the panel needs to be on-screen so ScreenCaptureKit
    /// picks up its annotations and carries them into the video for every
    /// viewer. In window / application modes the panel renders viewer ops
    /// locally for the sharer; reaching other viewers will need a separate
    /// server-side annotation fan-out.
    @discardableResult
    private func ensureSharerOverlay() -> SharerOverlayWindow {
        if let overlay = sharerOverlay { return overlay }
        let overlay = SharerOverlayWindow(mode: Self.overlayMode(for: currentSelection))
        // Broadcast sharer-painted strokes through the server so every
        // connected viewer applies them on their own canvas. In display
        // mode the strokes also still flow through SCStream's capture of
        // the overlay panel (the panel sits inside the captured display
        // region) — that's redundant, not wrong, and lets a viewer who
        // joins mid-stroke render an in-progress one from video bytes
        // alone if their annotation back-channel is down.
        // Queued, never one task per op: a `.undo` that overtakes its `.add`
        // is dropped by every viewer as an unknown id and leaves the stroke
        // on their canvas for the rest of the share.
        overlay.onOp = { [weak self] op in
            self?.server?.enqueueAnnotationBroadcast(op)
        }
        overlay.show()
        sharerOverlay = overlay
        return overlay
    }

    /// Project a `PickerSelection` onto the overlay mode that matches it.
    /// Nil / empty selections (legacy entry points, decode failures) fall
    /// back to the full-display overlay so the feature degrades gracefully
    /// rather than refusing to render annotations. Internal (not private)
    /// so the pure selection→mode decision is unit testable
    /// (`OverlayModeDecisionTests`).
    static func overlayMode(for selection: PickerSelection?) -> SharerOverlayWindow.Mode {
        guard let selection else { return .display(nil) }
        switch selection.kind {
        case .display:
            return .display(selection.displayID)
        case .window:
            if let id = selection.windowID {
                return .window(id)
            }
            return .display(nil)
        case .application:
            return .application(displayID: selection.displayID)
        }
    }

    /// True when the SCStream stopped because the user clicked Control
    /// Center's "Stop" button. Anything else is treated as recoverable and
    /// triggers `restartCapture()`. Static so it's unit-testable without a
    /// live stream.
    nonisolated static func isUserInitiatedCaptureStop(_ error: Error?) -> Bool {
        guard let nsErr = error as NSError? else { return false }
        // The portable server raises its own domain; a real `SCStreamError`
        // can also reach us from elsewhere in the mac capture stack.
        if nsErr.domain == TailscaleScreenShareServer.userStoppedErrorDomain { return true }
        return nsErr.domain == SCStreamError.errorDomain
            && nsErr.code == SCStreamError.Code.userStopped.rawValue
    }

    /// What `onCaptureStopped` should do about a capture failure. The server
    /// already ran its own crash-budget restarts, so every error handed up
    /// is a give-up — but only some are recoverable with a fresh-budget
    /// retry; the terminal domains must tear the share down rather than loop
    /// forever against a source that will never come back.
    enum CaptureStopAction: Equatable {
        /// User clicked Control Center "Stop" — quiet teardown.
        case userInitiated
        /// UDP control loop is dead — teardown + "connection lost" alert.
        case connectionLost
        /// Helper failed non-retryably for a genuine error (slot refused,
        /// decode failure) — teardown + error alert.
        case helperUnrecoverable
        /// The shared window / display / app was closed by the user —
        /// teardown + a gentle, non-error notice.
        case sourceClosed
        /// Transient/unclassified — grant one fresh-budget `restartCapture()`,
        /// tearing down only if that spawn itself throws.
        case attemptRestart
    }

    nonisolated static func captureStopAction(_ error: Error?) -> CaptureStopAction {
        if isUserInitiatedCaptureStop(error) { return .userInitiated }
        guard let nsErr = error as NSError? else { return .attemptRestart }
        switch nsErr.domain {
        case TailscaleScreenShareServer.receiveLoopErrorDomain:
            return .connectionLost
        case TailscaleScreenShareServer.helperSourceGoneErrorDomain:
            return .sourceClosed
        case TailscaleScreenShareServer.helperUnrecoverableErrorDomain:
            return .helperUnrecoverable
        default:
            return .attemptRestart
        }
    }

    /// Toggle whether the sharer can draw on their own screen. The panel is
    /// always present while sharing (so viewer-originated drawings render);
    /// this only flips input capture vs. click-through.
    func toggleSharerOverlay() {
        guard sharingState == .sharing else { return }
        let overlay = ensureSharerOverlay()
        isSharerOverlayVisible.toggle()
        overlay.setInputEnabled(isSharerOverlayVisible)
    }

    /// Refresh `availableInputDevices`/`availableOutputDevices`. Call before
    /// any device-picker UI renders. Cheap — a few HAL property reads.
    func refreshAudioDevices() {
        availableInputDevices = AudioDevices.inputs()
        availableOutputDevices = AudioDevices.outputs()
        // If the user's previous pick was unplugged, fall back to the system
        // default so the picker doesn't sit on a stale ID.
        if let id = selectedInputDeviceID, !availableInputDevices.contains(where: { $0.id == id }) {
            selectedInputDeviceID = nil
        }
        if let id = selectedOutputDeviceID, !availableOutputDevices.contains(where: { $0.id == id }) {
            selectedOutputDeviceID = nil
        }
        recordAudioDevicesIfChanged()
    }

    /// Last device lists recorded, so the diagnostics event fires only on
    /// change (a picker render is frequent and usually the same answer).
    private var lastRecordedAudioDevices: AudioDeviceDiagnostics.Snapshot?

    /// Record which audio devices exist and which are selected, when that
    /// changed. The **available** list matters as much as the selection: a
    /// headset that was never enumerated could never have been picked.
    private func recordAudioDevicesIfChanged() {
        let current = AudioDeviceDiagnostics.Snapshot(
            inputs: availableInputDevices.map(\.name),
            outputs: availableOutputDevices.map(\.name),
            defaultInput: systemDefaultInputName,
            defaultOutput: systemDefaultOutputName)
        guard AudioDeviceDiagnostics.changed(from: lastRecordedAudioDevices, to: current)
        else { return }
        lastRecordedAudioDevices = current
        AppDiagnostics.recorder?.record(
            .audioDevicesChanged,
            fields: AudioDeviceDiagnostics.fields(
                snapshot: current,
                selectedInput: selectedInputDeviceName,
                selectedOutput: selectedOutputDeviceName))
        publishOutputDeviceToVoice()
    }

    /// Tell the voice path which output every `audio.summary` row was
    /// measured through. Pushed on each device change and on attach, since a
    /// `VoiceChannel` built after the last change would otherwise record
    /// rows naming no device.
    private func publishOutputDeviceToVoice() {
        voiceChannel?.setOutputDeviceName(selectedOutputDeviceName ?? systemDefaultOutputName)
    }

    /// Name of the selected input, or nil for "system default" — a real
    /// state, not a missing answer.
    private var selectedInputDeviceName: String? {
        guard let id = selectedInputDeviceID else { return nil }
        return availableInputDevices.first { $0.id == id }?.name
    }

    private var selectedOutputDeviceName: String? {
        guard let id = selectedOutputDeviceID else { return nil }
        return availableOutputDevices.first { $0.id == id }?.name
    }

    /// What the system default input currently resolves to, by name.
    /// "System default" names the user's *choice*, not the *device*, and
    /// macOS moves the default on its own (headset plug/unplug) — without
    /// this a bundle can't show what actually changed.
    private var systemDefaultInputName: String? {
        AudioDevices.name(of: AudioDevices.defaultInputID(), in: availableInputDevices)
    }

    private var systemDefaultOutputName: String? {
        AudioDevices.name(of: AudioDevices.defaultOutputID(), in: availableOutputDevices)
    }

    /// The input actually in use: the explicit pick, else the system default.
    private var effectiveInputDeviceName: String {
        AudioDeviceDiagnostics.effective(
            selected: selectedInputDeviceName, systemDefault: systemDefaultInputName)
    }

    func selectInputDevice(_ deviceID: AudioDeviceID?) {
        selectedInputDeviceID = deviceID
        // By name, not `AudioDeviceID`: the ID is a machine-local handle
        // that changes across reboots and means nothing to a reader.
        AppDiagnostics.action(
            .actionAudioDeviceSelected,
            [
                "direction": .string("input"),
                "device": .string(selectedInputDeviceName ?? "system default"),
                "effective": .string(effectiveInputDeviceName)
            ])
        guard let cap = micCapture else { return }
        Task { @MainActor in await cap.setInputDevice(deviceID) }
    }

    func selectOutputDevice(_ deviceID: AudioDeviceID?) {
        selectedOutputDeviceID = deviceID
        AppDiagnostics.action(
            .actionAudioDeviceSelected,
            [
                "direction": .string("output"),
                "device": .string(selectedOutputDeviceName ?? "system default")
            ])
        micCapture?.setOutputDevice(deviceID)
    }

    func toggleMic() async {
        guard let voice = voiceChannel, let cap = micCapture else {
            presentError(.voiceNotReady())
            return
        }
        if isMicOn {
            cap.disableCapture()
            voice.isMuted = true
            isMicOn = false
            AppDiagnostics.action(.actionMicToggle, ["on": .bool(false)])
            AppDiagnostics.recorder?.record(.micDetached)
            return
        }
        AppDiagnostics.action(.actionMicToggle, ["on": .bool(true)])
        // Enumerate first: the lists are otherwise only filled by pickers'
        // `onAppear`, so a viewer who never opened Settings has an empty
        // list and no `audio.devices.changed` for `mic.attached` to key off.
        refreshAudioDevices()
        do {
            try await cap.enableCapture()
            voice.isMuted = false
            isMicOn = true
            AppDiagnostics.recorder?.record(
                .micAttached,
                fields: [
                    "device": .string(effectiveInputDeviceName),
                    "selection": .string(selectedInputDeviceName ?? "system default")
                ])
        } catch {
            // Recorded as well as surfaced: `presentError` records the
            // `TS-…` code but not which device failed.
            AppDiagnostics.recorder?.record(
                .micFailed,
                fields: [
                    "device": .string(effectiveInputDeviceName),
                    "selection": .string(selectedInputDeviceName ?? "system default"),
                    "error": .string(String(describing: error))
                ])
            presentError(.microphoneUnavailable(error))
            isMicOn = false
        }
    }

    /// Flip whether the current share sends system audio. Instant — the
    /// helper always has the audio output configured, this just toggles the
    /// emission latch. No-op when not sharing.
    func toggleSystemAudio() {
        isSystemAudioOn.toggle()
        AppDiagnostics.action(.actionSystemAudioToggle, ["on": .bool(isSystemAudioOn)])
        server?.setShareSystemAudio(isSystemAudioOn)
    }

    // MARK: - Link sharing (share-by-token) actions

    /// The menubar "Share via Link" toggle. `on` brings the guest node up
    /// and mints the token; `off` kills the token and drops every guest.
    /// Both run async (the DERP bootstrap blocks for the network), with
    /// `shareLinkBusy` guarding double-fires.
    func setShareLinkActive(_ on: Bool) {
        guard !shareLinkBusy else { return }
        AppDiagnostics.action(.actionLinkToggle, ["on": .bool(on)])
        // A guest-only share IS its link (the UI hides the off-toggle
        // there); turning it off here would strand a share nobody can reach.
        if !on, isGuestOnlyShare { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if on {
                await self.enableShareLink()
            } else {
                await self.disableShareLink()
            }
        }
    }

    /// Kill the current link and mint a fresh one — new node key, new token;
    /// every current guest is dropped. Composed from the two mirrored
    /// halves rather than `SharerLinkSession.rotate` directly, so
    /// `shareLinkBusy`/`shareLinkError`/the token mirror stay in step.
    func rotateShareLink() {
        guard !shareLinkBusy, shareLinkToken != nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.disableShareLink()
            await self.enableShareLink()
        }
    }

    private func enableShareLink() async {
        guard linkSharingEnabled, sharingState == .sharing, let server, shareLinkToken == nil else {
            return
        }
        shareLinkBusy = true
        shareLinkError = nil
        defer { shareLinkBusy = false }
        wireGuestEviction(on: server)
        do {
            shareLinkToken = try await link.enable(on: server, relayMapURL: linkRelayMapURL)
        } catch SharerLinkError.attachRefused, SharerLinkError.superseded {
            // The share raced to a stop while the node was coming up; no
            // share is left to put a link on. Deliberately silent — an error
            // banner would be a second surprise on a window whose share just
            // ended.
        } catch {
            logger.log("Share link failed to start: \(error)")
            shareLinkError = L("Couldn't create the link. Check the network and try again.")
        }
    }

    private func disableShareLink() async {
        guard shareLinkToken != nil else { return }
        // Detach-before-close (so a guest's window says "disconnected"
        // rather than timing out) is the session's ordering, not this
        // caller's.
        await link.disable(on: server)
        shareLinkToken = nil
        guestPeersByIP = [:]
    }

    /// Tunnel-level eviction: a Deny also closes the guest's tunnel and
    /// denylists their node key for this link's life. Wired per share
    /// (closes over the server instance), and BEFORE the share starts on the
    /// link-only path, where a guest can arrive as soon as it returns.
    private func wireGuestEviction(on server: TailscaleScreenShareServer) {
        server.onGuestViewerDenied = { [weak self] ip in
            Task { @MainActor [weak self] in
                await self?.evictGuest(ip: ip)
            }
        }
    }

    /// The Settings relay override for the guest tunnel's bootstrap, or nil
    /// for the default DERP map. Both mint paths read it from here.
    private var linkRelayMapURL: String? {
        let trimmed = linkShareRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Evict a denied guest at the tunnel, then re-mirror the peer map the
    /// roster reads. Fired by the server's deny paths via
    /// `onGuestViewerDenied`.
    private func evictGuest(ip: String) async {
        await link.evict(ip: ip)
        await refreshGuestPeers()
    }

    /// Mirror the tunnel-IP → guest-peer map from `link`. Called whenever
    /// the roster changes while a link is live, and after an eviction.
    func refreshGuestPeers() async {
        await link.refreshPeers()
        let peers = await link.peersByIP
        if guestPeersByIP != peers { guestPeersByIP = peers }
    }

    /// Roster label for a guest row: the short node-key fingerprint
    /// ("9c8d…4f21") once the peer map has it, nil (fall back to the tunnel
    /// IP) until then. Guests have no hostname — the key is their identity.
    func guestFingerprint(forIP ip: String) -> String? {
        guestPeersByIP[ip].map { ShareLinkFormat.keyFingerprint($0.key) }
    }

    /// Connected + pending guests, the count the link section shows.
    var guestCount: Int {
        currentViewers.filter(\.isGuest).count + pendingViewers.filter(\.isGuest).count
    }

    /// Connect to a sharer. `displayName` is what titles and messages call
    /// the peer (defaults to `host`, which may be a bare tailnet IP).
    /// With `guestToken` set the session runs over a share-by-token guest
    /// tunnel instead: `host` is ignored (pass ""), there is no tsnet node
    /// or sign-in, and the sharer must approve the join — the waiting
    /// placard is the expected first state.
    func connect(to host: String, displayName: String? = nil, guestToken: String? = nil) async {
        guard !host.isEmpty || guestToken != nil else { return }
        viewerConnectRequestID &+= 1
        let connectRequestID = viewerConnectRequestID
        // A lifecycle ID rejects callbacks that were already queued, but it
        // must not become a substitute for stopping the superseded client's
        // receive/listener tasks.
        if client != nil {
            await disconnectCurrentViewer(invalidatePendingConnects: false)
        }
        // Another connect may have entered while the previous transport was
        // shutting down. It owns the next client; this request must not
        // overwrite it after resuming.
        guard connectRequestID == viewerConnectRequestID else { return }
        let sessionID = viewerPresentation.begin(
            target: ViewerSessionTarget(
                host: host, displayName: displayName ?? host, guestToken: guestToken))

        connectionState = .connecting
        viewerWasDenied = false
        dismissViewerNotice()
        isAwaitingAdmission = true
        let renderer = ensureViewer()
        // Reconnect from the ended pane skips `dismissViewerWindow`, so the
        // frozen frame would otherwise sit under the connecting placard.
        renderer.clearPendingBuffer()
        syncViewerPresentationEffects()
        refreshViewerVideoAccessibilityLabel()
        // Belt-and-braces zoom reset at session entry: disconnect()
        // already resets, and `videoSize.didSet` resets on a resolution
        // change — but a new sharer streaming at the *same* resolution
        // fires neither, and must not inherit the previous session's zoom.
        viewerHost?.zoomState = ViewerZoomState()
        AppDiagnostics.recorder?.beginSession()
        let c = TailscaleScreenShareClient(renderer: renderer)
        c.recorder = AppDiagnostics.recorder
        client = c
        AppDiagnostics.action(
            .actionConnect,
            [
                "peer": .string(displayName ?? host),
                // The token itself never goes near the recorder — only whether
                // this was a link join, which is the part that changes how the
                // rest of the timeline should be read (guest admission is
                // mandatory-approval and identity is a node key, not a host).
                "via_link": .bool(guestToken != nil)
            ])
        do {
            // HELLO_PENDING means the sharer parked us behind the approval
            // gate. Surface the placard so the viewer doesn't sit on a
            // black window with no explanation; HELLO_ACK clears it through
            // the admission callback below.
            c.onAwaitingApproval = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                        self.viewerPresentation.markAwaitingApproval(for: sessionID)
                    else {
                        return
                    }
                    self.syncViewerPresentationEffects()
                }
            }

            // HELLO_DENY: the sharer clicked Deny (or has us blocked). Tear
            // the session down first, then explain — the alert is modal, so
            // running it before disconnect would leave a dead session on
            // screen behind it.
            c.onDeniedBySharer = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.viewerPresentation.isActive(sessionID) else { return }
                    // Accept the deny in `.connecting` too: a synchronous
                    // HELLO_DENY can land while `connect()` is mid-flight.
                    // `viewerWasDenied` keeps `connect()` from re-promoting
                    // to `.viewing` after this teardown.
                    let state = self.connectionState
                    guard state == .viewing || state == .connecting else { return }
                    // Same wire byte, told apart by where we were: still on
                    // the approval placard means declined; already watching
                    // means kicked mid-session. Snapshot before teardown
                    // resets `viewerAwaitingApproval`.
                    let wasWatching = state == .viewing && !self.viewerAwaitingApproval
                    self.viewerWasDenied = true
                    // When the window is already on screen, land it in the
                    // ended state so it doesn't vanish under the alert; a
                    // deny that raced `connect()` (window never shown)
                    // keeps the plain teardown.
                    if self.viewerWindow?.isVisible == true {
                        await self.endViewerSession(
                            reason: wasWatching ? .disconnectedBySharer : .declined,
                            sessionID: sessionID)
                    } else {
                        await self.disconnect()
                    }
                    if wasWatching {
                        self.showAlertMessage(
                            title: L("Disconnected by Sharer"),
                            message: L("The sharer disconnected you from their screen share.")
                        )
                    } else {
                        self.showAlertMessage(
                            title: L("Connection Declined"),
                            message: L("The sharer declined your request to view their screen.")
                        )
                    }
                }
            }

            // Server fans out sharer-painted (and other viewers') strokes
            // over the back-channel; apply to the local overlay's model.
            c.onAnnotationReceived = { [weak self] op in
                Task { @MainActor [weak self] in
                    guard let self, self.viewerPresentation.isActive(sessionID) else { return }
                    self.viewerOverlay?.model.apply(remoteOp: op)
                }
            }

            c.onRemoteControlSupportChanged = { [weak self] supported in
                Task { @MainActor [weak self] in
                    guard let self, self.viewerPresentation.isActive(sessionID) else { return }
                    self.sharerSupportsRemoteControl = supported
                }
            }

            c.onAnnotationSupportChanged = { [weak self] supported in
                Task { @MainActor [weak self] in
                    guard let self, self.viewerPresentation.isActive(sessionID) else { return }
                    self.sharerSupportsAnnotations = supported
                }
            }

            c.onOpenLinkSupportChanged = { [weak self] supported in
                Task { @MainActor [weak self] in
                    guard let self, self.viewerPresentation.isActive(sessionID) else { return }
                    self.sharerSupportsOpenLink = supported
                }
            }

            c.onControlGranted = { [weak self] in
                Task { @MainActor [weak self] in
                    guard
                        let self,
                        self.viewerPresentation.isActive(sessionID),
                        self.connectionState == .viewing
                    else { return }
                    // Only enter control if we're still actually asking for
                    // it — a late grant after Request-then-Stop should
                    // release, not silently start capturing.
                    guard self.viewerControlState == .requested else {
                        Task { [weak self] in await self?.client?.releaseControl() }
                        return
                    }
                    self.enterViewerControl()
                }
            }

            c.onControlRevoked = { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self, self.viewerPresentation.isActive(sessionID) else { return }
                    self.logger.log("Remote control revoked by sharer (\(reason))")
                    let wasControlling = self.viewerControlState == .controlling
                    self.exitViewerControl()
                    if wasControlling {
                        self.showAlertMessage(
                            title: L("Remote Control Ended"),
                            message: L("The sharer ended your remote-control session.")
                        )
                    }
                }
            }

            // Install BEFORE connecting: HELLO_ACK can arrive on the receive
            // loop the moment connect() returns (or slightly before), and a
            // callback installed afterwards may miss the only assignment.
            c.onAudioSSRCAssigned = { [weak self, weak c] ssrc in
                Task { @MainActor [weak self, weak c] in
                    guard
                        let self, let c,
                        self.viewerPresentation.isActive(sessionID)
                    else { return }
                    // The SSRC assignment IS the admission signal.
                    guard self.viewerPresentation.markViewing(for: sessionID) else { return }
                    self.connectionState = .viewing
                    self.isAwaitingAdmission = false
                    self.connectedHostname = displayName ?? host
                    self.syncViewerPresentationEffects()
                    self.refreshViewerVideoAccessibilityLabel()
                    NSApp.activate(ignoringOtherApps: true)
                    self.viewerWindow?.orderFrontRegardless()
                    self.viewerWindow?.makeKeyAndOrderFront(nil)
                    AppDiagnostics.viewVisible(Self.viewerWindowSurface, true)
                    guard self.voiceChannel == nil else { return }
                    self.micCapture?.stop()
                    self.micCapture = nil
                    self.voiceChannel?.reset()
                    self.voiceChannel = nil
                    self.isMicOn = false
                    do {
                        let voice = try VoiceChannel(localSSRC: ssrc) { [weak c] packet in
                            c?.sendAudioRTP(packet)
                        }
                        self.voiceChannel = voice
                        self.publishOutputDeviceToVoice()
                        c.onAudioReceived = { [weak voice] packet in
                            voice?.receive(packet)
                        }
                        let cap = MicCapture(channel: voice)
                        try cap.startPlayback()
                        self.micCapture = cap
                    } catch {
                        self.presentError(.voiceViewerInitFailed(error))
                    }
                }
            }

            if let guestToken {
                // The token names the relay and sharer: no node, no sign-in.
                try await c.connectGuest(token: guestToken)
            } else {
                // Reuse the AppState-owned tsnet node rather than spinning up
                // a third machine with its own login.
                let sharedNode = try await getOrCreateNode()
                try await c.connect(
                    to: host, port: NetworkConfig.tailscreenPort, existingNode: sharedNode)
            }

            // A HELLO_DENY that landed while we were still `.connecting` has
            // already torn the session down and alerted; don't re-promote it
            // to `.viewing` (which would resurrect a dead session).
            if viewerWasDenied { return }

            guard viewerPresentation.isCurrent(sessionID) else {
                await c.disconnect()
                return
            }
            connectedHostname = displayName ?? host
            refreshViewerWindowTitle()
            refreshViewerVideoAccessibilityLabel()
            NSApp.activate(ignoringOtherApps: true)
            viewerWindow?.orderFrontRegardless()
            viewerWindow?.makeKeyAndOrderFront(nil)
            AppDiagnostics.viewVisible(Self.viewerWindowSurface, true)
        } catch {
            await c.disconnect()
            // Build the AppError first and carry its message into the
            // lifecycle, rather than a raw `String(describing:)`.
            let failure = AppError.connectionFailed(host: host, underlying: error)
            guard viewerPresentation.fail(failure.message, for: sessionID) else { return }
            if client === c {
                client = nil
            }
            connectionState = .idle
            isAwaitingAdmission = false
            syncViewerPresentationEffects()
            // Only the SUCCESS path ordered the window front, so on a FIRST
            // attempt (a refused dial) nothing ever revealed it — the
            // "Connection Failed" placard would render into an invisible
            // window.
            viewerWindow?.orderFrontRegardless()
            viewerWindow?.makeKeyAndOrderFront(nil)
            AppDiagnostics.viewVisible(Self.viewerWindowSurface, true)
            presentError(failure)
        }
    }

    /// Join a share from whatever the user pasted — a bare token or a
    /// `tailscreen:` link. Returns false (caller shows its inline error) for
    /// no plausible token; true dismisses the sheet and starts the connect.
    func joinShare(input: String) -> Bool {
        guard let token = ShareLinkFormat.token(fromUserInput: input) else { return false }
        joinSheetPresented = false
        joinInput = ""
        Task { @MainActor [weak self] in
            await self?.connect(to: "", displayName: L("Shared screen"), guestToken: token)
        }
        return true
    }

    /// A `tailscreen:` URL landed. Open the join sheet with the token
    /// pre-filled rather than connecting outright — a clicked link is a
    /// request to *look at* joining.
    func handleOpenURL(_ url: URL) {
        guard let token = ShareLinkFormat.token(fromUserInput: url.absoluteString) else {
            logger.log("Ignoring un-parseable \(ShareLinkFormat.scheme): URL")
            return
        }
        joinInput = token
        joinSheetPresented = true
        presentMainWindow()
    }

    /// Holds a strong ref to the window's delegate; NSWindow.delegate is
    /// weak. The delegate intercepts windowShouldClose so the close button
    /// disconnects via AppState rather than letting AppKit destroy the
    /// persistent NSWindow.
    private var viewerWindowDelegate: ViewerWindowDelegate?

    /// Strong ref to the viewer toolbar's NSToolbarDelegate — NSWindow.toolbar
    /// holds the toolbar but the delegate is weak, so without this it would
    /// dealloc and the toolbar would stop building items.
    private var viewerToolbar: ViewerToolbar?

    /// Build (once) and return the shared viewer renderer. The window's
    /// close button maps to AppState.disconnect via a delegate returning
    /// false from windowShouldClose, so AppKit never tears the NSWindow +
    /// CAMetalLayer graph down (that release cascade was the SIGSEGV source).
    func ensureViewer() -> MetalViewerRenderer {
        if let r = viewerRenderer { return r }

        let r = MetalViewerRenderer()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Reflect the peer in the title bar; falls back to the app name
        // before the first connect. `refreshViewerWindowTitle` owns it from
        // here on.
        win.title = connectedHostname.map { L("Viewing \($0)") } ?? "Tailscreen"
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        // Full-screen capable (⌃⌘F / the zoom button's Enter Full Screen).
        win.collectionBehavior.insert(.fullScreenPrimary)
        // A restored frame must win over the first-frame auto-snap; the
        // View-menu size presets clear this latch as an explicit "snap me".
        viewerRestoredSavedFrame = win.setFrameUsingName(Self.viewerFrameAutosaveName)
        _ = win.setFrameAutosaveName(Self.viewerFrameAutosaveName)

        let toolbar = ViewerToolbar(appState: self)
        win.toolbar = toolbar.toolbar
        win.toolbarStyle = .unified
        self.viewerToolbar = toolbar
        // In case HELLO_ACK already resolved this before the window came up.
        toolbar.setAnnotationsEnabled(sharerSupportsAnnotations)

        let delegate = ViewerWindowDelegate(
            onClose: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if self.connectionState != .idle {
                        await self.disconnect()
                    } else {
                        // Ended state or stray close: orders out rather than
                        // letting AppKit run the release cascade, since the
                        // NSWindow itself stays alive (process-lifetime).
                        self.dismissViewerWindow()
                    }
                }
            },
            onUserResize: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self = self, !self.suppressViewerResizeTracking else { return }
                    self.userResizedViewer = true
                }
            })
        win.delegate = delegate
        self.viewerWindowDelegate = delegate

        // The host view explicitly aspect-fits both the metal layer and the
        // annotation overlay to the video's pixel size — without this a
        // click at 50% across a letterboxed window lands off by a
        // noticeable amount. `contentView` guard is defence-in-depth.
        let hostFrame: NSRect
        if let cv = win.contentView {
            hostFrame = cv.bounds
        } else {
            logger.log("ensureViewer: NSWindow.contentView was nil; falling back to window frame")
            hostFrame = NSRect(origin: .zero, size: win.frame.size)
        }
        let host = AspectFitHostView(frame: hostFrame)
        host.wantsLayer = true
        host.layer = CALayer()
        host.layer?.backgroundColor = NSColor.black.cgColor
        // Clip at the host's edges: while content-zoomed the video rect
        // (and the metal layer with it) extends past the window bounds.
        host.layer?.masksToBounds = true
        host.metalLayer = r.metalLayer
        host.layer?.addSublayer(r.metalLayer)
        self.viewerHost = host

        // Accessibility stand-in: decoded frames render into a CAMetalLayer,
        // which is not a view, so without this the window reads as empty to
        // VoiceOver. Never participates in hit-testing.
        let videoA11y = ViewerVideoAccessibilityView(frame: hostFrame)
        host.addSubview(videoA11y)
        host.accessibilitySubview = videoA11y
        self.viewerVideoAccessibilityView = videoA11y
        refreshViewerVideoAccessibilityLabel()
        // Mirror video-size changes onto the host, and (unless the user has
        // resized manually) snap the window to the content's pixel dims for
        // 1:1 rendering. The View menu's presets reset that opt-out.
        r.onVideoSizeChanged = { [weak self, weak host, weak win] size in
            // A resolution change also resets the content zoom — that
            // lives in `AspectFitHostView.videoSize.didSet` so it holds
            // for every producer of the property.
            host?.videoSize = size
            guard let self, let win else { return }
            MainActor.assumeIsolated {
                // Belt-and-braces fallback: HELLO_ACK normally cleared the
                // pre-admission title before media arrived.
                self.isAwaitingAdmission = false
                // Scripted E2E harness greps for this marker; fires once.
                if !self.didLogFirstViewerFrame, size.width > 0, size.height > 0 {
                    self.didLogFirstViewerFrame = true
                    self.logger.log(
                        "E2E_MARKER firstFrame width=\(Int(size.width)) height=\(Int(size.height))")
                }
                // Auto-snap only when neither the user nor a restored
                // saved frame has already decided the window's size.
                guard !self.userResizedViewer, !self.viewerRestoredSavedFrame else { return }
                self.programmaticSnap(win, toVideoPixelSize: size)
            }
        }
        if r.videoSize != .zero {
            host.videoSize = r.videoSize
            if !userResizedViewer && !viewerRestoredSavedFrame {
                programmaticSnap(win, toVideoPixelSize: r.videoSize)
            }
        }

        // Annotation overlay above the Metal layer. onOp forwards to the
        // active client's back-channel; the closure looks up `self.client`
        // each time, so the wiring survives reconnects without rebuilding
        // the overlay.
        let overlayModel = AnnotationCanvasModel()
        overlayModel.currentColor = Annotation.RGBA.paletteColor(
            forIdentity: TailscaleScreenShareClient.localIdentity())
        // Through the outbox, never a Task per op: an `.undo` that overtakes
        // its `.add` is dropped by the sharer as an unknown id, leaving the
        // stroke on their screen — and on every other viewer's, since the
        // sharer relays it — with nothing left that can remove it.
        let annotationOutbox = OrderedOutbox<AnnotationOp> { [weak self] op in
            await self?.client?.sendAnnotationOp(op)
        }
        self.viewerAnnotationOutbox = annotationOutbox
        overlayModel.onOp = { op in
            annotationOutbox.submit(op)
        }
        // Esc lands on the annotation canvas (it's the first responder).
        // Dismissing the cheat-sheet wins while it's visible; otherwise
        // Esc cancels the in-progress drag, as the sheet documents.
        overlayModel.onEscape = { [weak self] in
            guard let self else { return }
            if let shortcuts = self.viewerShortcutsHost, shortcuts.model.isVisible {
                shortcuts.model.isVisible = false
                return
            }
            self.viewerOverlay?.model.cancelDrag()
        }
        let overlay = AnnotationOverlayHostView(model: overlayModel)
        overlay.frame = host.bounds
        host.contentSubview = overlay
        host.addSubview(overlay)
        // Plug this canvas into the toolbar + the SwiftUI Commands menu.
        // ViewerCommands holds the model weakly; the menu's Tools
        // checkmarks and Undo/Clear enabling read it through
        // `ViewerCommands.shared`, so forward the model's changes into
        // this object's publisher — that re-evaluation is what keeps a
        // `Commands`-declared menu current (there is no AppKit
        // validation pass to lean on anymore).
        ViewerCommands.shared.activeOverlay = overlayModel
        overlayModel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.viewerOverlay = overlay

        // Remote-control input-capture layer, above the annotation overlay.
        // Hidden until this viewer holds a grant.
        let controlInput = RemoteControlInputView(frame: host.bounds)
        // Through the outbox, never a Task per event: a `mouseUp` that
        // overtakes its `mouseDown` strands a button on the sharer's Mac.
        let inputOutbox = OrderedOutbox<InputEvent> { [weak self] event in
            await self?.client?.sendInputEvent(event)
        }
        self.viewerInputOutbox = inputOutbox
        controlInput.onEvent = { event in
            inputOutbox.submit(event)
        }
        // The release chord releases control instead of forwarding to the
        // sharer, mirroring the File-menu item. Seeded here, re-pushed on remap.
        controlInput.releaseChord = revokeHotkeyChord
        controlInput.onReleaseChord = { [weak self] in
            self?.stopViewerControl()
        }
        host.addSubview(controlInput)
        host.inputCaptureSubview = controlInput
        self.viewerControlInput = controlInput

        // Keep the toolbar's tool segment in sync with the canvas model
        // so keyboard shortcuts (`1`–`6`, `⌘1`–`⌘6`) reflect on the
        // toolbar instead of only updating it on click.
        toolbar.bind(canvasModel: overlayModel)

        // Diagnostics overlay, above the annotation layer so its readout
        // isn't obscured by mid-stream strokes. Hidden by default.
        let statsHost = ViewerStatsOverlayHost(model: r.statsModel)
        host.addSubview(statsHost.view)
        statsHost.layout(in: host)
        self.viewerStatsHost = statsHost
        ViewerCommands.shared.statsModel = r.statsModel
        // Degraded-connection badge on the toolbar's stats button — the
        // overlay above may be hidden, the toolbar never is.
        toolbar.bind(statsModel: r.statsModel)

        // Non-modal notice banner (decode fallback, stall) pinned
        // top-center below the toolbar. Above the stats HUD so a notice is
        // never buried under it.
        let bannerHost = ViewerNoticeBannerHost()
        host.addSubview(bannerHost.view)
        bannerHost.layout(in: host)
        self.viewerNoticeBannerHost = bannerHost

        // "Session ended" pane over the last frame (reason + Reconnect /
        // Close). Above annotations, stats and the banner; beneath the
        // shortcuts cheat-sheet, which is user-initiated and dismissible.
        let endedHost = ViewerSessionEndedOverlayHost()
        endedHost.model.onReconnect = { [weak self] in self?.reconnectViewerSession() }
        endedHost.model.onClose = { [weak self] in self?.dismissViewerWindow() }
        host.addSubview(endedHost.view)
        endedHost.layout(in: host)
        self.viewerSessionEndedHost = endedHost

        // Shortcut cheat-sheet overlay. Added late so it draws above the
        // stats overlay and its tap-to-dismiss backdrop wins on hit-test.
        let shortcutsHost = ViewerShortcutsOverlayHost()
        host.addSubview(shortcutsHost.view)
        shortcutsHost.layout(in: host)
        self.viewerShortcutsHost = shortcutsHost
        syncShortcutChordDisplays()

        // "Waiting for sharer to accept" placard. Constraint-centered so
        // long translations grow it instead of truncating. Added last so
        // it draws above strokes/stats but beneath the (dismissible)
        // shortcuts cheat-sheet.
        let placard = makeWaitingPlacard()
        placard.isHidden = !viewerAwaitingApproval
        host.addSubview(placard)
        NSLayoutConstraint.activate([
            placard.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            placard.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            placard.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -40)
        ])
        self.viewerWaitingPlacard = placard
        ViewerCommands.shared.shortcutsModel = shortcutsHost.model

        win.contentView = host
        win.makeFirstResponder(overlay)

        // Center on the hub window's screen, else the one holding the
        // mouse. A restored frame keeps its own position.
        if !viewerRestoredSavedFrame {
            let hubScreen = NSApp.windows.first {
                $0.isVisible && $0.identifier?.rawValue.hasPrefix(TailscreenApp.mainWindowID) == true
            }?.screen
            let mouseScreen = NSScreen.screens.first {
                NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
            }
            if let screenFrame = (hubScreen ?? mouseScreen ?? NSScreen.main)?.visibleFrame {
                win.setFrameOrigin(
                    NSPoint(
                        x: screenFrame.midX - win.frame.width / 2,
                        y: screenFrame.midY - win.frame.height / 2
                    ))
            }
        }

        r.start(in: host)

        self.viewerWindow = win
        self.viewerRenderer = r
        return r
    }

    /// View → Actual Size / 50% / 200%. Resets the manual-resize opt-out
    /// (the user is explicitly asking for a fresh snap) and resizes to
    /// `videoSize × factor` clamped to the current screen.
    @MainActor
    func setViewerZoom(_ factor: CGFloat) {
        // The presets also mean "give me a predictable view" — drop any
        // content zoom/pan before the decoded-frame guard so ⌘0 and the
        // presets clear a stray zoom even before the first frame lands.
        viewerHost?.zoomState = ViewerZoomState()
        guard let win = viewerWindow, let r = viewerRenderer,
            r.videoSize.width > 0, r.videoSize.height > 0
        else { return }
        userResizedViewer = false
        // The presets are an explicit "snap me" — a restored saved frame
        // stops vetoing the auto-snap from here on.
        viewerRestoredSavedFrame = false
        let target = CGSize(
            width: r.videoSize.width * factor,
            height: r.videoSize.height * factor)
        programmaticSnap(win, toVideoPixelSize: target)
    }

    /// View → Zoom In / Zoom Out (⌥⌘+/⌥⌘-). Steps the continuous content
    /// zoom, anchored at the viewport center — unlike the window-sizing
    /// presets, this magnifies a region of the video within the window.
    @MainActor
    func zoomViewerContent(by delta: CGFloat) {
        viewerHost?.zoomContent(by: delta)
    }

    /// Wraps `snapViewerWindow` with the suppress-flag dance so the
    /// synchronous `windowDidResize` it triggers doesn't get charged to
    /// the user-resize counter.
    @MainActor
    private func programmaticSnap(_ win: NSWindow, toVideoPixelSize px: CGSize) {
        suppressViewerResizeTracking = true
        Self.snapViewerWindow(win, toVideoPixelSize: px)
        suppressViewerResizeTracking = false
    }

    /// Resize the viewer window so the captured video lands 1:1 — sizes to
    /// (video-pixels ÷ backingScale) plus the toolbar inset, clamped to the
    /// screen's `visibleFrame`.
    @MainActor
    private static func snapViewerWindow(_ win: NSWindow, toVideoPixelSize px: CGSize) {
        guard px.width > 0, px.height > 0 else { return }
        guard let cv = win.contentView else { return }
        let scale = win.backingScaleFactor > 0 ? win.backingScaleFactor : 2.0

        // Toolbar/titlebar inset: how much taller the contentView is than
        // its usable layout rect. Zero with no toolbar.
        let usable = win.contentLayoutRect
        let toolbarInset = max(0, cv.bounds.height - usable.height)

        let desiredVideoPt = NSSize(width: px.width / scale, height: px.height / scale)
        let desiredContent = NSSize(
            width: desiredVideoPt.width,
            height: desiredVideoPt.height + toolbarInset)

        // Clamp to `visibleFrame`; preserve aspect via the smaller scale
        // factor on each axis.
        let screen = win.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.size ?? desiredContent
        let widthScale = min(1.0, visible.width / desiredContent.width)
        let heightScale = min(1.0, visible.height / desiredContent.height)
        let fit = min(widthScale, heightScale)
        let bounded = NSSize(
            width: max(160, desiredContent.width * fit),
            height: max(120, desiredContent.height * fit))

        // No-op at the target size already — avoids thrash during a
        // sharer-side live resize drag.
        let current = cv.bounds.size
        if abs(current.width - bounded.width) < 1, abs(current.height - bounded.height) < 1 {
            return
        }
        win.setContentSize(bounded)
    }

    func connectToPeer(_ peer: TailscreenPeer) async {
        await connect(to: peer.tailscaleIP, displayName: peer.displayName)
    }

    func disconnect() async {
        await disconnectCurrentViewer(invalidatePendingConnects: true)
    }

    private func disconnectCurrentViewer(invalidatePendingConnects: Bool) async {
        if invalidatePendingConnects {
            viewerConnectRequestID &+= 1
        }

        // Invalidate presentation and ownership before the first suspension:
        // a superseding connect can then await transport cleanup without the
        // old connect task or a queued notification changing current state.
        let disconnectingClient = client
        client = nil
        viewerPresentation.dismiss()
        connectionState = .idle
        connectedHostname = nil
        isAwaitingAdmission = false
        syncViewerPresentationEffects()
        micCapture?.stop()
        micCapture = nil
        voiceChannel = nil
        isMicOn = false
        dismissViewerNotice()
        sharerSupportsRemoteControl = false
        sharerSupportsAnnotations = true
        sharerSupportsOpenLink = false
        // `viewerPresentation.dismiss()` above deliberately retained the
        // target: Reconnect redials the most recent session.
        if viewerControlState != .none {
            exitViewerControl()
        }
        viewerRenderer?.clearPendingBuffer()
        // The window survives disconnect; drop the content zoom so the next
        // session doesn't inherit a magnified view of a gone screen.
        viewerHost?.zoomState = ViewerZoomState()
        viewerWindow?.orderOut(nil)
        AppDiagnostics.viewVisible(Self.viewerWindowSurface, false)
        userResizedViewer = false
        didLogFirstViewerFrame = false
        refreshViewerWindowTitle()
        // Suspend only after every AppState-owned value is settled. A new
        // connect may start while transport shutdown finishes, and this
        // function must not resume by clearing any of that replacement state.
        await disconnectingClient?.disconnect()
    }

    /// The session ended without the user asking — sharer stop, timeout,
    /// connection loss, or a deny/kick. `disconnect()`'s teardown half,
    /// minus everything that hides the window or clears the last frame:
    /// the window stays up showing the frozen frame under an explicit
    /// "session ended" pane (reason + Reconnect / Close).
    func endViewerSession(reason: ViewerSessionEnding, sessionID: ViewerSessionID) async {
        guard viewerPresentation.end(reason, for: sessionID) else { return }
        // As in local disconnect, settle AppState before suspending so a
        // Reconnect click cannot be cleared when old transport cleanup resumes.
        let endingClient = client
        client = nil
        micCapture?.stop()
        micCapture = nil
        voiceChannel = nil
        isMicOn = false
        connectionState = .idle
        connectedHostname = nil
        isAwaitingAdmission = false
        sharerSupportsRemoteControl = false
        sharerSupportsAnnotations = true
        sharerSupportsOpenLink = false
        if viewerControlState != .none {
            exitViewerControl()
        }
        dismissViewerNotice()
        syncViewerPresentationEffects()
        postViewerAccessibilityAnnouncement(sessionEndedPresentation(reason).message)
        // Deliberately NOT clearPendingBuffer/orderOut/zoom resets —
        // `dismissViewerWindow` owns those.
        didLogFirstViewerFrame = false
        await endingClient?.disconnect()
    }

    /// Ended-pane Close, ⌘W on the ended state, and the close button
    /// outside `.viewing`: a plain close of the process-lifetime viewer
    /// window (orderOut, never an AppKit close/release).
    func dismissViewerWindow() {
        viewerPresentation.dismiss()
        syncViewerPresentationEffects()
        dismissViewerNotice()
        viewerRenderer?.clearPendingBuffer()
        viewerHost?.zoomState = ViewerZoomState()
        viewerWindow?.orderOut(nil)
        AppDiagnostics.viewVisible(Self.viewerWindowSurface, false)
        userResizedViewer = false
        didLogFirstViewerFrame = false
        refreshViewerWindowTitle()
    }

    /// Account boundaries are stronger than closing an ended-session pane:
    /// the retained reconnect target must not survive into the next profile.
    private func forgetViewerForAccountTeardown() {
        viewerConnectRequestID &+= 1
        dismissViewerWindow()
        isAwaitingAdmission = false
        viewerPresentation.forget()
        syncViewerPresentationEffects()
    }

    /// Redial the current / most recent peer. Serves both the ended pane's
    /// Reconnect button and the stall banner's — from a live (stalled)
    /// session it disconnects first.
    func reconnectViewerSession() {
        guard let target = viewerPresentation.lifecycle.target else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.connectionState == .viewing {
                await self.disconnect()
            }
            // A guest session redials by token — `host` is empty.
            await self.connect(
                to: target.host, displayName: target.displayName,
                guestToken: target.guestToken)
        }
    }

    /// Map the client's wire-side close reason onto the presentation enum,
    /// through the shared `resolve` all three platforms use. `wasAdmitted:
    /// true` because `.deniedOrKicked` never rides this notification on
    /// macOS — the deny path goes through `onDeniedBySharer` instead.
    nonisolated static func sessionEnding(for reason: ViewerCloseReason) -> ViewerSessionEnding {
        ViewerSessionEndReason.resolve(reason, wasAdmitted: true)
    }

    /// Localized title + message for the ended pane (and the VoiceOver
    /// announcement). The deny-flavored wordings reuse the alert copy so
    /// the two surfaces can't tell the same story differently.
    private func sessionEndedPresentation(_ reason: ViewerSessionEnding) -> ViewerSessionEndedModel.EndedState {
        // `target` is set at every `connect()` entry; the fallback is defensive.
        let name = viewerPresentation.lifecycle.target?.displayName ?? L("peer")
        switch reason {
        case .sharerStopped:
            return .init(
                title: L("Session Ended"),
                message: L("\(name) stopped sharing their screen."))
        case .timedOut:
            return .init(
                title: L("Session Ended"),
                message: L("The connection to \(name) went quiet and timed out."))
        case .connectionLost:
            return .init(
                title: L("Session Ended"),
                message: L("The connection to \(name) was lost."))
        case .disconnectedBySharer:
            return .init(
                title: L("Disconnected by Sharer"),
                message: L("The sharer disconnected you from their screen share."))
        case .declined:
            return .init(
                title: L("Connection Declined"),
                message: L("The sharer declined your request to view their screen."))
        }
    }

    /// Single source for the viewer window's title, so the pre-admission,
    /// viewing, controlling, and ended states can't disagree.
    private func refreshViewerWindowTitle() {
        guard let win = viewerWindow else { return }
        if viewerSessionIsOver {
            // The pane's own title, not a fixed string. `viewerSessionIsOver`
            // covers BOTH terminal phases, so hard-coding "Session Ended"
            // here put it over the "Connection Failed" pane — reintroducing,
            // in the title bar, exactly the claim that a session which never
            // opened had ended. One derivation, so the two cannot disagree.
            win.title = viewerTerminalPresentation()?.title ?? L("Session Ended")
            return
        }
        guard let name = viewerPresentation.lifecycle.target?.displayName ?? connectedHostname else {
            win.title = "Tailscreen"
            return
        }
        if connectionState == .connecting || isAwaitingAdmission {
            win.title = L("Connecting to \(name)…")
        } else if viewerControlState == .controlling {
            // Reflect the active grant in the title too — the orange
            // border and toolbar item carry it, but the title survives
            // Mission Control and the Window menu.
            win.title = L("Viewing \(name) — controlling")
        } else if connectionState == .viewing {
            win.title = L("Viewing \(name)")
        } else {
            win.title = "Tailscreen"
        }
    }

    /// Keep the video surface's VoiceOver label naming the current peer.
    private func refreshViewerVideoAccessibilityLabel() {
        let name = connectedHostname ?? viewerPresentation.lifecycle.target?.displayName
        let label = name.map { L("Shared screen from \($0)") } ?? L("Shared screen")
        viewerVideoAccessibilityView?.setAccessibilityLabel(label)
    }

    /// Show a non-modal notice at the top of the viewer window. Transient
    /// notices auto-dismiss after a few seconds; persistent ones stay
    /// until dismissed or their action runs. Falls back to the alert
    /// surface if there is somehow no viewer window to pin a banner to.
    private func showViewerNotice(
        message: String, persistent: Bool,
        actionTitle: String? = nil, action: (@MainActor () -> Void)? = nil
    ) {
        guard let bannerHost = viewerNoticeBannerHost, viewerWindow?.isVisible == true else {
            showAlertMessage(title: L("Connection Problem"), message: message)
            return
        }
        viewerNoticeDismissTask?.cancel()
        viewerNoticeDismissTask = nil
        let notice = ViewerNotice(
            message: message, isPersistent: persistent,
            actionTitle: actionTitle, action: action)
        bannerHost.model.notice = notice
        // The banner is visual only — say it too.
        postViewerAccessibilityAnnouncement(message)
        guard !persistent else { return }
        let id = notice.id
        viewerNoticeDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self else { return }
            // Only dismiss the notice we posted — a newer one owns the slot.
            if self.viewerNoticeBannerHost?.model.notice?.id == id {
                self.viewerNoticeBannerHost?.model.notice = nil
            }
        }
    }

    private func dismissViewerNotice() {
        viewerNoticeDismissTask?.cancel()
        viewerNoticeDismissTask = nil
        viewerNoticeBannerHost?.model.notice = nil
    }

    /// Speak `message` through VoiceOver (high priority). Used for state
    /// changes with no focused control to carry them — control
    /// grant/revoke, session end, banner notices.
    private func postViewerAccessibilityAnnouncement(_ message: String) {
        let element: Any
        if let win = viewerWindow {
            element = win
        } else {
            element = NSApp as Any
        }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ])
    }

    /// ⌘? while sharing (no viewer window): the cheat-sheet in its own
    /// centered panel. Lazily built, kept for the process lifetime.
    func toggleShortcutsPanel() {
        let host = shortcutsPanelHost ?? ViewerShortcutsPanelHost()
        shortcutsPanelHost = host
        syncShortcutChordDisplays()
        host.toggle()
    }

    /// Push the current mic/revoke display chords into every cheat-sheet
    /// model, so the sheet prints what Settings → Keyboard Shortcuts
    /// actually stores. Called when a sheet host is (re)created and from
    /// both chord `didSet`s.
    func syncShortcutChordDisplays() {
        for model in [viewerShortcutsHost?.model, shortcutsPanelHost?.model] {
            model?.micChord = micShortcutDisplay
            model?.controlChord = revokeShortcutDisplay
        }
    }

    /// True when launched with `--ui-preview`: the hub renders a seeded,
    /// deterministic peer list — no networking — so CI can screenshot the
    /// chrome. Same flag/fake tailnet as GTK/Windows, so screenshots read as
    /// one product.
    static let isUIPreview = CommandLine.arguments.contains("--ui-preview")

    /// Extra preview states, additive on top of `--ui-preview`, spelled the
    /// same as the GTK app's. Each is an *element* match, so passing only
    /// `--ui-preview-sharing` alone seeds nothing.
    static let isUIPreviewRequest = CommandLine.arguments.contains("--ui-preview-request")
    static let isUIPreviewSharing = CommandLine.arguments.contains("--ui-preview-sharing")
    static let isUIPreviewVideo = CommandLine.arguments.contains("--ui-preview-video")

    /// The one preview state that is *not* signed in — the welcome pane
    /// seeds no profile/peers, but still rides `--ui-preview` to suppress
    /// the session restore (which would sign the pane away mid-screenshot).
    static let isUIPreviewWelcome = CommandLine.arguments.contains("--ui-preview-welcome")

    /// The seeded preview state: tagged and untagged, online and offline,
    /// one peer sharing and one relayed, so a single screenshot exercises
    /// every axis. Verbatim data, deliberately not localized.
    private func seedUIPreview() {
        if Self.isUIPreviewWelcome {
            // Seeded even though it defaults on: the runner's own defaults
            // might say otherwise.
            linkSharingEnabled = true
            scheduleUIPreviewWindowCapture()
            return
        }
        tailscaleAuth.userProfile = TailscaleUserProfile(
            displayName: "Robert", loginName: "robert@example.com",
            profilePicURL: nil, tailnetName: "example.com")
        tailscaleAuth.isAuthenticated = true
        availablePeers = [
            TailscreenPeer(
                id: "1", hostname: "robert-macbook",
                dnsName: "robert-macbook.example.ts.net",
                tailscaleIP: "100.64.0.12", isOnline: true,
                curAddr: "192.168.1.24:41641",
                tailscaleIPs: ["100.64.0.12", "fd7a:115c:a1e0::c"]),
            TailscreenPeer(
                id: "2", hostname: "studio-imac",
                dnsName: "studio-imac.example.ts.net",
                tailscaleIP: "100.64.0.31", isOnline: true,
                tags: ["tag:studio"], relay: "sto",
                tailscaleIPs: ["100.64.0.31"]),
            TailscreenPeer(
                id: "3", hostname: "living-room-tv",
                dnsName: "living-room-tv.example.ts.net",
                tailscaleIP: "100.64.0.44", isOnline: false,
                tags: ["tag:media"],
                tailscaleIPs: ["100.64.0.44"])
        ]
        peerShareInfo = [
            "1": TailscreenMetadata(
                shareName: "robert's Screen", hostname: "robert-macbook",
                screenResolution: .init(width: 1920, height: 1080),
                isSharing: true, timestamp: Date(), videoCodec: .hevc)
        ]
        peerLatencyMs = ["1": 12, "2": 38]
        hasCompletedInitialDiscovery = true

        if Self.isUIPreviewRequest { seedUIPreviewShareRequest() }
        if Self.isUIPreviewSharing { seedUIPreviewSharing() }

        scheduleUIPreviewWindowCapture()
    }

    /// The part of preview bring-up that has to wait for SwiftUI: the
    /// windows belong to its scene machinery, not yet built at init time.
    private func scheduleUIPreviewWindowCapture() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self = self else { return }
            if Self.isUIPreviewVideo { self.seedUIPreviewVideo() }
            // Keep looking rather than giving up once: on a COLD first
            // launch (Gatekeeper, LaunchServices) the window isn't there yet
            // at +2s. 60s outlasts the screenshot job's own wait, which
            // nudges this process with `reopen` until a window exists.
            for _ in 0..<120 {
                if self.writeUIPreviewWindowID() { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// `--ui-preview-request`: one peer asking this machine to share, which
    /// is the banner both the hub and the menubar popover render.
    private func seedUIPreviewShareRequest() {
        pendingShareRequests = [
            PendingShareRequest(
                fromHostname: "studio-imac", receivedAtNs: 1,
                connectionID: nil, sourceKey: "100.64.0.31")
        ]
    }

    /// `--ui-preview-sharing`: mid-share with one viewer connected and that
    /// same viewer asking for control — a single shot carries the roster
    /// row, the grant prompt and the consequence line together. Thumbnail
    /// and resolution stated rather than read off `NSScreen`, so the shot
    /// looks the same on every runner.
    private func seedUIPreviewSharing() {
        sharingState = .sharing
        currentViewers = [
            ViewerInfo(
                id: "100.64.0.31:52104", tailscaleIP: "100.64.0.31",
                hostname: "tailscreen-studio-imac", connectedAt: Date())
        ]
        controlRequests = [
            ControlRequestInfo(
                id: UUID(), viewerIP: "100.64.0.31",
                hostname: "tailscreen-studio-imac", arrivedAt: Date())
        ]
        previewImage = Self.makeUIPreviewThumbnail(width: 1920, height: 1080)
        // Only `screenResolution` reaches the card; the rest is what a real
        // `updateMetadata` would have filled in, under a name none of the
        // seeded peers uses — this machine is the sharer here.
        metadataService.currentMetadata = TailscreenMetadata(
            shareName: "robert-mbp's Screen",
            hostname: "robert-mbp",
            screenResolution: .init(width: 1920, height: 1080),
            isSharing: true, timestamp: Date(), videoCodec: .hevc)
    }

    /// The `--ui-preview-video` stand-in frame as an `NSImage`, since the
    /// sharing card's thumbnail takes an `NSImage`, not a pixel buffer.
    private static func makeUIPreviewThumbnail(width: Int, height: Int) -> NSImage? {
        guard let buffer = makeUIPreviewFrame(width: width, height: height) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// `--ui-preview-video`: the viewer window — chrome, toolbar, overlay
    /// over a stand-in frame. `ensureViewer()` builds the graph; the seed is:
    /// make it, feed it a frame, draw on it, front it.
    private func seedUIPreviewVideo() {
        let renderer = ensureViewer()
        connectionState = .viewing
        connectedHostname = "robert-macbook"
        sharerSupportsAnnotations = true
        refreshViewerWindowTitle()

        // Nothing snaps this window here (no real stream), so state the size
        // explicitly: 1280x720 fits the 1920x1080 runner display, centered.
        if let window = viewerWindow {
            window.setContentSize(NSSize(width: 1280, height: 720))
            window.center()
        }

        // Front it before the frame: the renderer's display link only runs
        // against a layer that is actually on screen.
        viewerWindow?.orderFrontRegardless()
        viewerWindow?.makeKeyAndOrderFront(nil)

        if let frame = Self.makeUIPreviewFrame(width: 1920, height: 1080) {
            renderer.setPixelBuffer(
                frame, receiveUptimeNs: DispatchTime.now().uptimeNanoseconds)
        }

        // Raise the stats HUD with a plausible steady-state session: a still
        // image measures as 0 fps with no codec, which would look like a
        // dead session, and the sparkline wants a history of varying samples.
        renderer.suppressStatsPublishing = true
        var stats = ViewerStats.empty
        stats.latencyMs = 18
        stats.fps = 60
        stats.droppedPct = 0
        stats.bitrateBps = 4_100_000
        stats.codec = .hevc
        stats.framesPresented = 3600
        renderer.statsModel.update(stats)
        for index in 0..<ViewerStatsModel.historyCapacity {
            let wobble = Double((index * 7) % 5)
            renderer.statsModel.appendHistory(
                HistorySample(
                    latencyMs: 16 + wobble,
                    bitrateBps: 3_900_000 + wobble * 60_000,
                    droppedPct: 0))
        }
        renderer.statsModel.isVisible = true

        // One stroke per tool so every shape's geometry is in the frame.
        // `.click` is absent: it's ephemeral and this model sweeps it on a
        // real timer that a screenshot cannot outrun.
        func seed(_ tool: AnnotationTool, _ points: [CGPoint], _ colorIndex: Int) {
            viewerOverlay?.model.apply(
                remoteOp: .add(
                    Annotation(
                        id: UUID(), tool: tool, points: points,
                        color: Annotation.RGBA.palette[colorIndex], width: 4)))
        }
        // Placed ON things in the frame below (an oval round a block, an
        // arrow at it, a pen underline, a rectangle round terminal output)
        // rather than spread evenly, which read as a test pattern. Stays
        // clear of the stats HUD (left ~19%, down to mid-height).
        seed(.oval, [CGPoint(x: 0.218, y: 0.200), CGPoint(x: 0.600, y: 0.318)], 4)
        seed(.arrow, [CGPoint(x: 0.790, y: 0.430), CGPoint(x: 0.615, y: 0.318)], 2)
        seed(.line, [CGPoint(x: 0.250, y: 0.438), CGPoint(x: 0.670, y: 0.438)], 1)
        seed(.pen, [CGPoint(x: 0.232, y: 0.530), CGPoint(x: 0.430, y: 0.548), CGPoint(x: 0.635, y: 0.526)], 0)
        seed(.rectangle, [CGPoint(x: 0.095, y: 0.730), CGPoint(x: 0.520, y: 0.766)], 3)
    }

    /// A 16:9 stand-in for decoded video: a dark editor over a terminal,
    /// drawn as bars rather than letterforms (real-looking fake code invites
    /// the reader to squint at it). BGRA to match the Metal renderer's
    /// path. Left 19% down to mid-height stays empty for the stats HUD.
    private static func makeUIPreviewFrame(width: Int, height: Int) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                attrs as CFDictionary, &out) == kCVReturnSuccess,
            let buffer = out
        else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        guard
            let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        // Flip to y-down to match the annotation space above.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let frameWidth = Double(width)
        let frameHeight = Double(height)
        func box(
            _ x: Double, _ y: Double, _ boxWidth: Double, _ boxHeight: Double,
            _ rgb: UInt32, _ alpha: Double = 1, rounded: Bool = false
        ) {
            let rect = CGRect(
                x: x * frameWidth, y: y * frameHeight,
                width: boxWidth * frameWidth, height: boxHeight * frameHeight)
            context.setFillColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: CGFloat(alpha))
            if rounded {
                context.addPath(
                    CGPath(
                        roundedRect: rect, cornerWidth: rect.height / 2,
                        cornerHeight: rect.height / 2, transform: nil))
                context.fillPath()
            } else {
                context.fill(rect)
            }
        }

        let keyword: UInt32 = 0xA8_79F0
        let ident: UInt32 = 0xB8_C0D4
        let string: UInt32 = 0x6B_D08A
        let type: UInt32 = 0x58_C4D4
        let number: UInt32 = 0xE0_A35C
        let comment: UInt32 = 0x4D_5568

        box(0, 0, 1, 1, 0x14_161E)
        box(0.18, 0.02, 0.79, 0.055, 0x1C_1F2A)
        box(0.19, 0.025, 0.115, 0.047, 0x2E_3345, rounded: true)
        box(0.205, 0.042, 0.060, 0.011, ident, 0.75, rounded: true)
        box(0.320, 0.025, 0.090, 0.047, 0x1A_1D26, rounded: true)
        box(0.334, 0.042, 0.048, 0.011, ident, 0.30, rounded: true)
        box(0.425, 0.025, 0.075, 0.047, 0x1A_1D26, rounded: true)
        box(0.437, 0.042, 0.040, 0.011, ident, 0.30, rounded: true)

        // (indent, [(segment width, colour)]) -- laid out left to right with a
        // fixed gap, so the shapes read as words without being any.
        let code: [(Double, [(Double, UInt32)])] = [
            (0.000, [(0.260, comment)]),
            (0.000, [(0.075, keyword), (0.190, ident), (0.045, ident), (0.115, type)]),
            (0.028, [(0.055, keyword), (0.210, ident), (0.080, number)]),
            (0.028, [(0.110, ident), (0.040, ident), (0.235, string)]),
            (0.056, [(0.065, keyword), (0.145, type), (0.040, number), (0.100, ident)]),
            (0.056, [(0.175, ident), (0.120, string), (0.065, ident)]),
            (0.028, [(0.030, ident)]),
            (0.000, [(0.215, comment)]),
            (0.000, [(0.080, keyword), (0.195, ident), (0.045, ident), (0.135, type)]),
            (0.028, [(0.145, ident), (0.045, ident), (0.120, type), (0.070, number)]),
            (0.056, [(0.070, keyword), (0.250, string)]),
            (0.056, [(0.170, ident), (0.060, number), (0.095, ident)]),
            (0.028, [(0.030, ident)]),
            (0.000, [(0.095, keyword), (0.225, ident), (0.055, ident)])
        ]
        for (index, line) in code.enumerated() {
            let y = 0.105 + Double(index) * 0.036
            box(0.202, y + 0.004, 0.010, 0.011, comment, 0.7, rounded: true)
            var x = 0.228 + line.0
            for segment in line.1 {
                box(x, y, segment.0, 0.017, segment.1, 0.85, rounded: true)
                x += segment.0 + 0.009
            }
        }

        // Minimap: the same lines again, scaled down and faint.
        for (index, line) in code.enumerated() {
            let y = 0.11 + Double(index) * 0.0135
            var x = 0.905 + line.0 * 0.18
            for segment in line.1 {
                box(x, y, segment.0 * 0.18, 0.006, segment.1, 0.35)
                x += (segment.0 + 0.009) * 0.18
            }
        }

        // Terminal, split off the bottom. Below the HUD, so it may use the
        // full width the editor above it cannot.
        box(0.06, 0.645, 0.89, 0.300, 0x0D_0F15)
        box(0.06, 0.645, 0.89, 0.035, 0x17_1A23)
        box(0.072, 0.656, 0.055, 0.013, ident, 0.45, rounded: true)
        let terminal: [(Double, [(Double, UInt32)])] = [
            (0.00, [(0.014, string), (0.135, ident), (0.090, number)]),
            (0.02, [(0.290, ident)]),
            (0.02, [(0.205, comment)]),
            (0.00, [(0.014, string), (0.175, ident), (0.060, type)]),
            (0.02, [(0.115, type), (0.240, ident)]),
            (0.02, [(0.160, ident), (0.070, number)])
        ]
        for (index, line) in terminal.enumerated() {
            let y = 0.700 + Double(index) * 0.036
            var x = 0.082 + line.0
            for segment in line.1 {
                box(x, y, segment.0, 0.016, segment.1, 0.8, rounded: true)
                x += segment.0 + 0.010
            }
        }
        return buffer
    }

    /// Name the window CI should crop its capture to (`screencapture -l`).
    /// Silent no-op without the flag. An argument, not an env var, because
    /// the screenshot job launches via `open`, which forwards `--args` but
    /// not the caller's environment.
    /// Returns true once it has written (or has nothing to write).
    @discardableResult
    private func writeUIPreviewWindowID() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--ui-preview-window-file") else { return true }
        let next = args.index(after: flag)
        guard next < args.endIndex else { return true }
        let path = args[next]
        guard !path.isEmpty else { return true }
        // Leave a note of everything on screen beside the id file, so a
        // silent non-match is debuggable later.
        let windows = NSApp.windows
        let dump = windows.map {
            [
                "n=\($0.windowNumber)", "class=\(type(of: $0))",
                "visible=\($0.isVisible)", "main=\($0.canBecomeMain)",
                "titled=\($0.styleMask.contains(.titled))",
                "frame=\(NSStringFromRect($0.frame))", "title=\($0.title)"
            ].joined(separator: " ")
        }.joined(separator: "\n")
        try? dump.write(toFile: path + ".windows", atomically: true, encoding: .utf8)

        // In video mode the subject is the viewer window. Otherwise take the
        // biggest thing on screen: the hub is the only large window this app
        // raises, and the MenuBarExtra's backing panels are small.
        let subject: NSWindow?
        if Self.isUIPreviewVideo {
            subject = viewerWindow
        } else {
            let candidates = windows.filter {
                $0.isVisible && $0.frame.width > 200 && $0.frame.height > 200
            }
            subject = candidates.max {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }
        }
        guard let subject = subject else { return false }
        do {
            try String(subject.windowNumber).write(
                toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    func discoverPeers() async {
        // UI-preview mode renders the seeded list: there is no node, and the
        // unauthenticated-discovery alert would land on the screenshot.
        if Self.isUIPreview { return }

        // Coalesce concurrent calls: the popover re-ids its tree on open
        // (`MenuBarView.viewID`), which fires the devices section's
        // onAppear twice in quick succession — one pass is enough.
        if isDiscovering { return }

        // Need an active Tailscale node to discover peers
        // Try to get it from either server or client
        guard let node = server?.node ?? client?.node ?? self.node else {
            presentError(.discoveryUnauthenticated())
            hasCompletedInitialDiscovery = true
            return
        }

        // Reuse the long-lived discovery (and its IPN watcher) across
        // popover opens — a fresh one per refresh stacked up watchers that
        // all wrote `availablePeers`, reading as flicker. Rebind if the
        // node's identity changed (sign-out tears it down).
        if let discovery = peerDiscovery, peerDiscoveryNode === node {
            isDiscovering = true
            logger.log("Discovery: reseeding…")
            do {
                try await discovery.startDiscovery(node: node)
                setAvailablePeers(discovery.availablePeers)
                logger.log("Discovery: reseeded with \(self.availablePeers.count) peer(s)")
                // Re-kick monitoring in case the initial fire-and-forget
                // attempt failed (idempotent — no-ops when already live).
                Task { @MainActor in
                    try? await discovery.startRealTimeMonitoring(node: node)
                }
                // Sweep share statuses off the fresh roster. Fire-and-forget
                // so N metadata dials never delay the "done" spinner flip.
                Task { @MainActor [weak self] in await self?.refreshPeerShareStatus() }
            } catch {
                logger.log("Discovery: reseed failed with \(error)")
                presentError(.discoveryFailed(error))
            }
            isDiscovering = false
            settleInitialDiscoveryAnswer()
            return
        }

        peerDiscovery?.stopRealTimeMonitoring()
        let discovery = TailscalePeerDiscovery()
        self.peerDiscovery = discovery
        self.peerDiscoveryNode = node

        isDiscovering = true
        logger.log("Discovery: starting…")
        do {
            try await discovery.startDiscovery(node: node)
            setAvailablePeers(discovery.availablePeers)
            logger.log("Discovery: returned with \(self.availablePeers.count) peer(s)")

            // Sweep share statuses off the fresh roster. Fire-and-forget
            // so N metadata dials never delay the "done" spinner flip.
            Task { @MainActor [weak self] in await self?.refreshPeerShareStatus() }

            // Fire-and-forget so it never blocks the "done" signal. The
            // first attempt usually races tsnet bring-up, so retry with
            // backoff until it sticks.
            Task { @MainActor [weak self] in
                for attempt in 0..<5 {
                    guard let self, self.peerDiscovery === discovery else { return }
                    do {
                        try await discovery.startRealTimeMonitoring(node: node)
                        return
                    } catch {
                        self.logger.log(
                            "Discovery: monitoring start failed (attempt \(attempt + 1)): \(error)")
                        try? await Task.sleep(for: .seconds(1 << attempt))
                    }
                }
            }

            // Observe peer changes. Ends when the discovery object (and
            // its publisher) is torn down on rebind/sign-out.
            Task { @MainActor [weak self, weak discovery] in
                guard let stream = discovery?.$availablePeers.values else { return }
                for await peers in stream {
                    guard let self, let discovery, self.peerDiscovery === discovery else { return }
                    self.setAvailablePeers(peers)
                }
            }

            // Empty list is already reflected inline in the Browse sheet —
            // no popup needed.
        } catch {
            logger.log("Discovery: failed with \(error)")
            presentError(.discoveryFailed(error))
        }
        isDiscovering = false
        settleInitialDiscoveryAnswer()
    }

    /// Mark the initial discovery "answered" — immediately if peers were
    /// found, or after a short grace period when empty. An empty *first*
    /// pass often means "not synced yet", not "no Tailscreen devices"; the
    /// grace keeps the loading skeleton up for the IPN watcher's first
    /// netmap.
    private func settleInitialDiscoveryAnswer() {
        guard !hasCompletedInitialDiscovery else { return }
        if !availablePeers.isEmpty {
            hasCompletedInitialDiscovery = true
            return
        }
        let discovery = peerDiscovery
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            // A sign-out tears the discovery down; a stale timer must not
            // re-set the flag.
            guard let self, self.peerDiscovery === discovery else { return }
            self.hasCompletedInitialDiscovery = true
        }
    }

    /// Assign `availablePeers` only when the contents actually changed —
    /// redundant writes fire `objectWillChange` and re-render the popover
    /// for no visible reason. The devices section animates real changes
    /// via `.animation(value:)` on its container.
    private func setAvailablePeers(_ peers: [TailscreenPeer]) {
        // Any non-empty answer settles the initial-discovery question,
        // regardless of which path delivered it (seed or IPN watcher).
        if !peers.isEmpty { hasCompletedInitialDiscovery = true }
        guard peers != availablePeers else { return }
        availablePeers = peers
    }

    /// Query each online Tailscreen peer's TCP/7447 listener for its share
    /// status, and cache the answers for the sharing-status filter + peer
    /// rows. Deliberately lazy: runs off `discoverPeers()` and when the
    /// "only sharing" filter turns on. A peer with no answer has its entry
    /// removed so the filter treats it as unknown, never stale.
    func refreshPeerShareStatus() async {
        if shareStatusRefreshInFlight { return }
        guard let node = server?.node ?? client?.node ?? self.node else { return }
        shareStatusRefreshInFlight = true
        defer { shareStatusRefreshInFlight = false }

        let targets = availablePeers.filter { $0.isOnline && !$0.tailscaleIP.isEmpty }
        await withTaskGroup(of: (String, TailscreenMetadata?, Int).self) { group in
            for peer in targets {
                let ip = peer.tailscaleIP
                let id = peer.id
                group.addTask {
                    let start = ContinuousClock.now
                    let metadata = await TailscreenMetadataClient.fetchMetadata(fromIP: ip, via: node)
                    let elapsedMs = Int((ContinuousClock.now - start) / .milliseconds(1))
                    return (id, metadata, elapsedMs)
                }
            }
            for await (id, metadata, elapsedMs) in group {
                if let metadata {
                    peerShareInfo[id] = metadata
                    peerLatencyMs[id] = elapsedMs
                } else {
                    peerShareInfo.removeValue(forKey: id)
                    peerLatencyMs.removeValue(forKey: id)
                }
            }
        }

        // Prune entries for peers that left the roster entirely so a
        // removed node can't pin a stale "sharing" row forever.
        let known = Set(availablePeers.map(\.id))
        peerShareInfo = peerShareInfo.filter { known.contains($0.key) }
        peerLatencyMs = peerLatencyMs.filter { known.contains($0.key) }
    }

    /// Single-peer variant of `refreshPeerShareStatus`, fired when the peer-
    /// detail pane expands. Same rule: no answer removes the entry.
    func refreshShareStatus(for peer: TailscreenPeer) async {
        guard peer.isOnline, !peer.tailscaleIP.isEmpty else { return }
        guard let node = server?.node ?? client?.node ?? self.node else { return }
        let start = ContinuousClock.now
        let metadata = await TailscreenMetadataClient.fetchMetadata(
            fromIP: peer.tailscaleIP, via: node)
        let elapsedMs = Int((ContinuousClock.now - start) / .milliseconds(1))
        if let metadata {
            peerShareInfo[peer.id] = metadata
            peerLatencyMs[peer.id] = elapsedMs
        } else {
            peerShareInfo.removeValue(forKey: peer.id)
            peerLatencyMs.removeValue(forKey: peer.id)
        }
    }

    /// Initialize Tailscale and trigger login flow
    func initializeTailscaleAndLogin(silent: Bool = true) async {
        await login(silent: silent)
    }

    /// Bring the persistent tsnet node up at launch with browser-open
    /// suppressed, and check whether the on-disk state already
    /// authenticates us. If not (stale/empty state), the suppressed
    /// BrowseToURL is dropped silently.
    private func attemptSessionRestore() async {
        // Skip when the state directory is empty — a first launch has
        // nothing to restore, and bringing the node up would just emit a
        // BrowseToURL we're going to drop.
        let statePath = profileStore.activeProfile.statePath(
            appSupport: Self.appSupportDirectory(),
            instanceSuffix: TailscreenInstance.stateSuffix)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: statePath)) ?? []
        guard !contents.isEmpty else {
            logger.log("No saved Tailscale state at \(statePath); skipping silent restore")
            return
        }

        // `interactiveLoginRequested` defaults to false, so any BrowseToURL
        // emitted during this `up()` is dropped. If stale, `up()` blocks in
        // the background until the user clicks Sign In.
        do {
            let node = try await getOrCreateNode()
            await tailscaleAuth.checkAuthStatus(node: node)
            if tailscaleAuth.isAuthenticated {
                noteProfileIdentityFromAuth()
                logger.log("Restored signed-in Tailscale session")
            } else {
                logger.log("No valid saved session; awaiting explicit sign-in")
            }
        } catch {
            logger.log("Silent restore skipped: \(error)")
        }
    }

    func login(silent: Bool = false) async {
        // Prevent multiple concurrent login attempts
        guard !isLoggingIn else {
            logger.log("Login already in progress, skipping...")
            return
        }
        isLoggingIn = true
        // A new attempt is not the old attempt's failure; cleared here so
        // the reason goes the moment the retry starts.
        nodeFailure = nil
        // Allow the IPN BrowseToURL handler to open a tab — the user
        // explicitly asked to sign in.
        interactiveLoginRequested = true
        defer {
            isLoggingIn = false
            interactiveLoginRequested = false
        }

        do {
            logger.log("Starting login flow...")
            // Get or create the Tailscale node
            let node = try await getOrCreateNode()

            logger.log("Node created, calling tailscaleAuth.login...")
            // Run the login flow
            try await tailscaleAuth.login(node: node)

            logger.log("Login completed, checking auth status...")
            // Update auth status after login
            await tailscaleAuth.checkAuthStatus(node: node)

            // Label the active profile with the identity that just signed
            // in, so the account menu can name it while it's inactive.
            noteProfileIdentityFromAuth()

            // Login success is visible via the menu's user profile section;
            // a popup just interrupts the flow the user was already in.
            _ = silent
        } catch {
            logger.log("Login error: \(error)")
            // Both, not redundant: the alert fires once, this is what the
            // welcome pane reads afterwards. Same key as the alert's message.
            nodeFailure = L("Failed to log in: \(error.localizedDescription)")
            presentError(.loginFailed(error))
        }
    }

    private func getOrCreateNode() async throws -> TailscaleNode {
        // If the node exists AND is running, return it. "Running" is read
        // from the backend itself, not assumed from existence.
        if let node = self.node {
            switch nodeBringUpState {
            case .upInFlight:
                // A concurrent caller while `up()` is still blocking
                // (interactive login). Hand back the same node rather than
                // racing a second bring-up.
                return node
            case .up:
                let state = try? await withTimeout(seconds: 3) {
                    try await LocalAPIClient(localNode: node, logger: nil)
                        .backendStatus().BackendState
                }
                // "Starting" is tolerated: a live backend can pass through
                // it transiently, and tearing it down for that would churn
                // a healthy node. Everything else — Stopped, NeedsLogin, an
                // unreachable backend — is a node that cannot serve, so
                // rebuild. The on-disk state survives, so a still-valid
                // login comes back without a browser prompt.
                if state == "Running" || state == "Starting" {
                    return node
                }
                logger.log(
                    "getOrCreateNode: cached node reports \(state ?? "unreachable") — recreating")
            case .notUp:
                // `up()` threw after the node was stored: dead on arrival.
                logger.log("getOrCreateNode: cached node never came up — recreating")
            }
            // Tear down the dead node and everything hanging off it (the
            // control listener, the auth watcher, discovery) so the fresh
            // node below re-wires all of it instead of half of it.
            await teardownNodeKeepingLogin()
        }

        // One tsnet node per process, used for sign-in *and* for the
        // screen-share Listener / Client. An earlier two-node design
        // (separate "-auth" node + per-feature ephemeral nodes) made every
        // share + every connect pop a second / third browser login,
        // because each tsnet node = a distinct machine in the tailnet.
        // The state dir is the ACTIVE PROFILE's — identity lives entirely
        // in tsnet's on-disk state, so a profile is just a directory.
        let statePath = profileStore.activeProfile.statePath(
            appSupport: Self.appSupportDirectory(),
            instanceSuffix: TailscreenInstance.stateSuffix)

        // Create directory if needed
        try? FileManager.default.createDirectory(
            atPath: statePath, withIntermediateDirectories: true)

        // Persist the node in the tailnet across launches so the user only
        // signs in once per Mac. `ephemeral: true` would garbage-collect
        // the device server-side as soon as the app quits, forcing a
        // browser login every relaunch — fine for CI but painful in daily
        // use.
        let baseHostname = Host.current().localizedName ?? "mac"
        let spec = TsnetNodeFactory.Spec(
            hostName:
                "\(TailscreenInstance.serverHostnamePrefix)\(baseHostname)\(TailscreenInstance.hostnameSuffix)",
            ephemeral: false,
            statePath: statePath,
            authKey: TailscreenInstance.authKey,
            controlURL: TailscreenInstance.controlURLOverride ?? kDefaultControlURL)

        let node = try TsnetNodeFactory.makeNode(spec: spec, logger: SimpleLogger())
        self.node = node
        nodeBringUpState = .upInFlight

        // Subscribe to the IPN bus *before* calling `up()`: tsnet emits the
        // login URL as a BrowseToURL notify, and if nothing's listening when
        // it fires, `up()` waits forever with the user never seeing the link.
        if authIPNWatcher == nil {
            authIPNWatcher = await startBrowseURLWatcher(node: node)
        }

        // tsnet's up() has no internal timeout. With an auth key there's no
        // human in the loop, so bound it and surface an error on a hang;
        // the interactive path (no key) stays unbounded since it legitimately
        // blocks until the user finishes the browser login.
        do {
            try await TsnetNodeFactory.up(node, spec: spec, timeout: .boundedWhenAuthKeyed(seconds: 60))
        } catch {
            // Leave the node stored (matching the long-standing behaviour)
            // but marked never-came-up, so the next call rebuilds instead of
            // handing the dead node back.
            nodeBringUpState = .notUp
            throw error
        }
        nodeBringUpState = .up

        // Idempotent; has to live across share start/stop so request-to-share
        // messages reach us even when we're not currently sharing.
        try await ensureControlListener(node: node)

        return node
    }

    /// Start (and keep) the long-lived TCP/7447 control listener. Awaited so
    /// a bind failure still fails node bring-up.
    private func ensureControlListener(node: TailscaleNode) async throws {
        guard try await askToShare.ensureListenerStarted(node: node) else { return }
        logger.log("Control listener bound on TCP/\(NetworkConfig.tailscreenPort)")
    }

    /// Post and withdraw request-to-share notices to match the live banner
    /// rows. Identity is `PendingShareRequest.sourceKey` (source IP, never
    /// the wire-claimed hostname), same key the banner list coalesces on, so
    /// a retry replaces one row rather than minting a second. Called from
    /// the coordinator's `onRequestsChanged`, on both arrival and answer.
    private func refreshShareRequestNotices() {
        let candidates = pendingShareRequests.map {
            NoticeCandidate(identity: $0.sourceKey, label: $0.fromHostname)
        }
        let answered = SharerNoticeDecision.noticesToWithdraw(
            candidates: candidates, alreadyNotified: notifiedShareRequestKeys)
        let decision = SharerNoticeDecision.noticesToPost(
            kind: .requestToShare, candidates: candidates,
            alreadyNotified: notifiedShareRequestKeys)
        notifiedShareRequestKeys = decision.notified
        SharerNoticeCenter.shared.withdraw(kind: .requestToShare, identities: Array(answered))
        post(decision.post)
    }

    /// Answer an incoming request-to-share banner. The accept/decline
    /// response rides the TCP connection the request arrived on
    /// (best-effort); the row and notice come down via `onRequestsChanged`.
    func respondToShareRequest(_ request: PendingShareRequest, accepted: Bool) {
        askToShare.answer(id: request.id, accept: accepted)
    }

    /// Spin up an IPN-bus watcher that opens the browser-login URL tsnet
    /// emits during interactive sign-in.
    private func startBrowseURLWatcher(node: TailscaleNode) async -> TailscaleIPNWatcher? {
        let watcher = TailscaleIPNWatcher()
        watcher.onBrowseToURL = { [weak self] url in
            // Hop to the main actor — NSWorkspace must be touched there,
            // and the IPN consumer fires from a background actor.
            Task { @MainActor in
                guard let self else { return }
                guard self.interactiveLoginRequested else {
                    // Silent restore in progress: don't pop an unrequested
                    // sign-in tab. Clicking "Sign in" flips the flag.
                    self.logger.log("Suppressing BrowseToURL during silent restore")
                    return
                }
                self.logger.log("Opening login URL in browser: \(url)")
                NSWorkspace.shared.open(url)
            }
        }
        do {
            try await watcher.startWatching(node: node)
            return watcher
        } catch {
            logger.log("Browse-URL watcher failed to start: \(error)")
            return nil
        }
    }

    func signOut() async {
        do {
            try await tailscaleAuth.signOut()

            // Stop sharing if active
            if sharingState == .sharing {
                await stopSharing(reason: "signOut")
            }

            // Disconnect viewing AND in-flight sessions. Closing the node
            // under `.connecting` leaves its eventual callback free to
            // resurrect viewer state after the account is gone.
            if connectionState != .idle {
                await disconnect()
            }
            forgetViewerForAccountTeardown()

            // Reset Tailscale state
            await server?.stop()
            server = nil
            await askToShare.stopListener()
            try? await node?.close()
            node = nil
            authIPNWatcher?.stopWatching()
            authIPNWatcher = nil
            peerDiscovery?.stopRealTimeMonitoring()
            peerDiscovery = nil
            peerDiscoveryNode = nil
            availablePeers = []
            peerShareInfo = [:]
            hasCompletedInitialDiscovery = false
            nodeFailure = nil

        } catch {
            presentError(.signOutFailed(error))
        }
    }

    // MARK: - Node bring-up phase

    /// Where this hub's tailnet node is, in the vocabulary all three hubs
    /// share (`NodeBringUpPhase`, TailscreenProtocol).
    ///
    /// A **projection**, not a stored slot: the truth lives in
    /// `TailscaleAuth` (portable, shared not owned) plus the discovery
    /// flags. A stored phase beside those would be one more value that could
    /// disagree with `isAuthenticated`.
    ///
    /// Does NOT drive which pane the window shows — `MainWindowView` still
    /// branches on `isSwitchingProfile`/`isAuthenticated`, since this app
    /// renders `startingNode` and an account switch differently from the
    /// other hubs. Those are presentation choices layered on the phase.
    var nodePhase: NodeBringUpPhase {
        Self.nodeBringUpPhase(
            isAuthenticated: tailscaleAuth.isAuthenticated,
            isSigningIn: isLoggingIn || tailscaleAuth.isLoading,
            failure: nodeFailure,
            isDiscovering: isDiscovering,
            hasCompletedInitialDiscovery: hasCompletedInitialDiscovery)
    }

    /// The pure mapping behind `nodePhase`, extracted so the precedence is
    /// pinned by a test rather than inferred.
    ///
    /// **Authenticated wins first.** The obvious order (in-flight before
    /// settled) would let a window where `isLoading` is still set but
    /// `isAuthenticated` already flipped report `startingNode` for someone
    /// already looking at their screens list.
    ///
    /// Among signed-out cases, a RUNNING sign-in outranks a failure —
    /// `login()` clears `nodeFailure` before starting, so this is belt and
    /// braces.
    ///
    /// **In-flight means BOTH flags.** `isLoggingIn` is set before
    /// `getOrCreateNode()`; `TailscaleAuth.isLoading` only once the node
    /// exists. Reading the second alone would report `signedOut` through
    /// the whole node-creation window, offering a Sign-in button that
    /// `login()`'s own re-entrancy guard then swallows.
    nonisolated static func nodeBringUpPhase(
        isAuthenticated: Bool,
        isSigningIn: Bool,
        failure: String?,
        isDiscovering: Bool,
        hasCompletedInitialDiscovery: Bool
    ) -> NodeBringUpPhase {
        if isAuthenticated {
            // An empty list before the first discovery pass is "no answer
            // yet", never "no devices".
            return isDiscovering || !hasCompletedInitialDiscovery ? .discovering : .ready
        }
        if isSigningIn { return .startingNode }
        if let failure { return .failed(failure) }
        return .signedOut
    }

    // MARK: - Account profiles

    /// Application Support root. FileManager almost always returns it
    /// under `.userDomainMask`; fall back to the conventional
    /// home-relative path rather than force-unwrap so a missing-URL edge
    /// case (sandboxing quirk, unusual environment) stays recoverable.
    nonisolated static func appSupportDirectory() -> URL {
        if let url = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            return url
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
    }

    /// Copy the signed-in identity onto the active profile record so the
    /// account menu can label profiles while they're inactive.
    private func noteProfileIdentityFromAuth() {
        guard tailscaleAuth.isAuthenticated, let profile = tailscaleAuth.userProfile else { return }
        profileStore.updateActiveIdentity(
            displayName: profile.displayName, loginName: profile.loginName,
            tailnetName: profile.tailnetName, profilePicURL: profile.profilePicURL ?? "")
    }

    /// Tear down the live node and everything hanging off it WITHOUT logging
    /// out — the on-disk tsnet state stays valid, so switching back later
    /// restores silently. `signOut()`'s teardown half minus the sign-out.
    private func teardownNodeKeepingLogin() async {
        await server?.stop()
        server = nil
        await askToShare.stopListener()
        try? await node?.close()
        node = nil
        authIPNWatcher?.stopWatching()
        authIPNWatcher = nil
        peerDiscovery?.stopRealTimeMonitoring()
        peerDiscovery = nil
        peerDiscoveryNode = nil
        availablePeers = []
        peerShareInfo = [:]
        hasCompletedInitialDiscovery = false
        tailscaleAuth.isAuthenticated = false
        tailscaleAuth.userProfile = nil
        // The reason belonged to the profile being left; carrying it across
        // would open the next account's welcome pane on the last one's
        // failure.
        nodeFailure = nil
    }

    /// True while a session is active enough that yanking the node out
    /// from under it on a menu click would be worse than asking the user
    /// to finish first.
    private var isBusyForProfileSwitch: Bool {
        !Self.canSwitchProfile(sharing: sharingState, connection: connectionState)
    }

    /// Pure gate: switching accounts closes the tsnet node, so it's only
    /// allowed while nothing is riding it. A share that FAILED to start
    /// reads through `isLive`, not `.idle` — spelled the other way, one
    /// failed start would lock account switching for the rest of the run.
    nonisolated static func canSwitchProfile(
        sharing: SharingState, connection: ConnectionState
    ) -> Bool {
        !sharing.isLive && connection == .idle
    }

    /// Switch the active account profile: one node at a time, other
    /// profiles stay logged in on disk. Refuses mid-session; otherwise
    /// closes the current node and brings the selected profile up.
    func switchProfile(to id: UUID) async {
        guard id != profileStore.activeProfileID else { return }
        guard !isBusyForProfileSwitch else {
            presentNotice(
                title: L("Finish Your Session First"),
                message: L("Stop sharing or disconnect before switching accounts."))
            return
        }
        isSwitchingProfile = true
        defer { isSwitchingProfile = false }
        // An ended viewer pane is compatible with the idle gate, but its
        // reconnect target belongs to the profile we are leaving.
        forgetViewerForAccountTeardown()
        await teardownNodeKeepingLogin()
        profileStore.setActive(id)
        await attemptSessionRestore()
    }

    /// "Add Account…": create a fresh profile (its own tsnet state dir),
    /// switch to it, and go straight into the interactive login flow.
    func addAccountAndSignIn() async {
        guard !isBusyForProfileSwitch else {
            presentNotice(
                title: L("Finish Your Session First"),
                message: L("Stop sharing or disconnect before switching accounts."))
            return
        }
        let profile = profileStore.addProfile()
        // Drop any ended-session target at the actual account boundary, not
        // in node teardown, which is also used for same-account recovery.
        forgetViewerForAccountTeardown()
        await teardownNodeKeepingLogin()
        profileStore.setActive(profile.id)
        await login(silent: false)
    }

    /// Confirm and remove a non-active profile, deleting its on-disk node
    /// state. Only directories under `profiles/` are ever deleted, never the
    /// legacy shared root.
    func confirmRemoveProfile(_ profile: TailscreenProfile) {
        let alert = NSAlert()
        alert.messageText = L("Remove this account?")
        alert.informativeText = L(
            "Removes its sign-in state from this Mac. The device may remain listed in the tailnet admin console until it expires."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let removed = profileStore.remove(profile.id) else { return }
        if removed.stateDirectory.hasPrefix("profiles/") {
            let stateURL = URL(
                fileURLWithPath: removed.statePath(
                    appSupport: Self.appSupportDirectory(),
                    instanceSuffix: TailscreenInstance.stateSuffix))
            // Remove the whole per-profile folder (profiles/<uuid>), which
            // holds the suffixed state dir(s) of every local instance.
            try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent())
        }
    }

    /// `TAILSCREEN_AUTOSTART_SHARE=1` handler. Waits for `attemptSessionRestore`
    /// to settle the auth state (up to ~30 s), then drops into the normal
    /// share entry point. Relies on `TAILSCREEN_AUTOSHARE_DISPLAY=1` being
    /// set so the picker-helper short-circuits to a synthetic main-display
    /// selection instead of presenting UI.
    private func runAutoStartShare() async {
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            if tailscaleAuth.isAuthenticated { break }
        }
        guard tailscaleAuth.isAuthenticated else {
            logger.log("TAILSCREEN_AUTOSTART_SHARE: auth never settled; giving up")
            return
        }
        logger.log("TAILSCREEN_AUTOSTART_SHARE=1 → presentNativePicker()")
        await presentNativePicker()
    }

    /// `TAILSCREEN_AUTOCONNECT_TO=<prefix>` handler. Waits for auth, kicks
    /// off discovery once (which also installs the real-time IPN-bus monitor),
    /// then polls `availablePeers` for a hostname-prefix match. Netmap
    /// propagation can take a moment after the sharer registers; we give it
    /// up to 30 seconds.
    private func runAutoConnect(prefix: String) async {
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            if tailscaleAuth.isAuthenticated { break }
        }
        guard tailscaleAuth.isAuthenticated else {
            logger.log("TAILSCREEN_AUTOCONNECT_TO: auth never settled; giving up")
            return
        }
        await discoverPeers()
        for attempt in 0..<30 {
            // Matched against BOTH spellings: the rows now render without the
            // `tailscreen-` marker, so a prefix copied off the screen ("wisp")
            // has to work as well as the raw hostname the harnesses pass.
            let match = availablePeers.first {
                $0.hostname.hasPrefix(prefix) || $0.displayName.hasPrefix(prefix)
            }
            if let peer = match {
                logger.log(
                    "TAILSCREEN_AUTOCONNECT_TO=\(prefix) → connecting to \(peer.hostname) @ \(peer.tailscaleIP)"
                )
                await connectToPeer(peer)
                return
            }
            logger.log("TAILSCREEN_AUTOCONNECT_TO=\(prefix): peer not found (attempt \(attempt + 1))")
            try? await Task.sleep(for: .seconds(1))
        }
        logger.log("TAILSCREEN_AUTOCONNECT_TO=\(prefix): gave up; peer never appeared")
    }

    /// Send a request-to-share to `peer` and surface the round-trip outcome.
    /// The await can run for up to two minutes (the peer's banner may sit
    /// unanswered for a while); the calling Task just parks — no UI blocks.
    func requestToShare(from peer: TailscreenPeer) async {
        let hostname = Host.current().localizedName ?? "Unknown"
        do {
            let node = try await getOrCreateNode()
            let outcome = try await metadataService.sendRequestToShareAwaitingResponse(
                toIP: peer.tailscaleIP,
                port: NetworkConfig.tailscreenPort,
                from: hostname,
                via: node
            )
            switch outcome {
            case .accepted:
                showAlertMessage(
                    title: L("Request Accepted"),
                    message: L("\(peer.displayName) accepted your request and is choosing what to share.")
                )
            case .declined:
                showAlertMessage(
                    title: L("Request Declined"),
                    message: L("\(peer.displayName) declined your request to share their screen.")
                )
            case .noAnswer:
                showAlertMessage(
                    title: L("No Response"),
                    message: L(
                        "\(peer.displayName) hasn't responded to your request. They may be away or running an older Tailscreen."
                    )
                )
            }
        } catch {
            presentError(.requestToShareFailed(peer: peer.displayName, underlying: error))
        }
    }

    /// Open (or re-focus) the preferences window: a real titled `NSWindow`
    /// hosting `SettingsView`, kept for the process lifetime. Resizable
    /// above a floor since a fixed frame fights large system text sizes;
    /// `contentMinSize` is the AppKit-side belt to SwiftUI's own minimum.
    func presentSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(appState: self))
            let win = NSWindow(contentViewController: hosting)
            win.title = L("Tailscreen Settings")
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.setContentSize(NSSize(width: 480, height: 640))
            win.contentMinSize = NSSize(width: 440, height: 480)
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        // The OS owns the login-item truth (flippable in System Settings
        // behind our back); re-read it on every open.
        refreshLaunchAtLoginStatus()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Launch at login

    /// `SMAppService` registers the *bundle*, so a dev build running as a
    /// bare executable has nothing registrable — the Settings toggle
    /// disables itself instead.
    let launchAtLoginAvailable = Bundle.main.bundleURL.pathExtension == "app"

    /// Mirror of `SMAppService.mainApp.status == .enabled`. Refreshed on
    /// Settings open and after every toggle — the OS owns the truth, so
    /// this is `private(set)` observed state, never a stored preference.
    @Published private(set) var launchAtLoginEnabled = false

    /// True when registration parked in `.requiresApproval`: macOS holds
    /// the login item until the user approves it under System Settings →
    /// General → Login Items. The pane shows a caption pointing there.
    @Published private(set) var launchAtLoginRequiresApproval = false

    /// Re-read the login-item status from the OS. Cheap; called from
    /// `presentSettings` and after `setLaunchAtLogin`.
    func refreshLaunchAtLoginStatus() {
        guard launchAtLoginAvailable else { return }
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled
        launchAtLoginRequiresApproval = status == .requiresApproval
    }

    /// Register/unregister the app as a login item; the published state is
    /// re-read from `SMAppService` afterwards, reflecting what the OS did.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard launchAtLoginAvailable else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showAlertMessage(
                title: L("Couldn't Update Login Item"),
                message: L("macOS refused to change Launch at login: \(error.localizedDescription)"))
        }
        refreshLaunchAtLoginStatus()
    }

    /// Open (or re-focus) the docked main window via the stashed SwiftUI
    /// `openWindow` action; the identifier-prefix fallback covers the gap
    /// where the scene's window exists but no view has stashed it yet.
    func presentMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let openMainWindowAction {
            openMainWindowAction()
        } else if let win = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(TailscreenApp.mainWindowID) == true
        }) {
            win.makeKeyAndOrderFront(nil)
        }
    }

    /// Raise the persistent viewer window. Re-fronts only — nil until a
    /// first session — never creates one here.
    func focusViewerWindow() {
        guard let viewerWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        viewerWindow.orderFrontRegardless()
        viewerWindow.makeKeyAndOrderFront(nil)
    }

    /// Surface an error as an `NSAlert`. AppKit directly, not a SwiftUI
    /// `.alert`: `MenuBarExtra(.window)` dismisses its popover on any click
    /// outside its bounds, including an alert's own buttons, so SwiftUI
    /// button handlers would never run. "Copy Details" re-presents the alert.
    func presentError(_ error: AppError) {
        logger.log("AppError[\(error.code)] \(error.title) — \(error.message)")
        // Every alert-shaped failure funnels through here, so one call
        // records them all. The message isn't recorded (prose varies with
        // interpolated detail); the stable code is what matters.
        AppDiagnostics.fault(code: error.code, title: error.title)

        NSApp.activate(ignoringOtherApps: true)

        while true {
            let alert = NSAlert()
            alert.messageText = error.title
            alert.informativeText = L("\(error.message)\n\nError code: \(error.code)")
            alert.alertStyle = .warning

            if let action = error.action {
                alert.addButton(withTitle: action.title)
            }
            alert.addButton(withTitle: L("Copy Details"))
            alert.addButton(withTitle: L("OK"))

            let response = alert.runModal()
            let chosen = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let hasAction = error.action != nil

            if hasAction && chosen == 0 {
                error.action?.handler()
                return
            }
            let copyIndex = hasAction ? 1 : 0
            if chosen == copyIndex {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(error.copyableDetails(), forType: .string)
                continue
            }
            return
        }
    }

    /// Legacy free-form alert: wraps strings in `AppError.legacy(...)` so
    /// the richer surface still gets a code + Copy Details.
    private func showAlertMessage(title: String, message: String) {
        presentError(.legacy(title: title, message: message))
    }

    /// A soft, non-error informational notice — for *expected* events (e.g.
    /// the shared window was closed) that aren't failures.
    func presentNotice(title: String, message: String) {
        logger.log("Notice: \(title) — \(message)")
        AppDiagnostics.recorder?.record(.noticeShown, fields: ["title": .string(title)])
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    // MARK: - Sharer notices

    /// Whether a capture is running — the sound gate for every notice: a
    /// ding during a share is played by the notification daemon, which the
    /// "exclude our own audio" flag doesn't cover, so every viewer hears it.
    private var isCapturing: Bool { sharingState.isLive }

    /// Deliver a batch of notices — the single place `SharerNoticeCenter` is
    /// touched, so the sound gate can't be forgotten.
    private func post(_ notices: [SharerNotice]) {
        for notice in notices {
            SharerNoticeCenter.shared.post(notice, isCapturing: isCapturing)
        }
    }

    /// Project the connected-viewer roster onto notice candidates. Keyed by
    /// the server's `"ip:port"` id, so a drop-and-rejoin on a fresh
    /// ephemeral port is announced again — the opposite of the
    /// control-request choice below.
    nonisolated static func noticeCandidates(_ viewers: [ViewerInfo]) -> [NoticeCandidate] {
        viewers.map { NoticeCandidate(identity: $0.id, label: $0.displayName) }
    }

    /// Project the approval gate onto notice candidates — same key/reasoning
    /// as the roster.
    nonisolated static func noticeCandidates(_ pending: [PendingViewerInfo]) -> [NoticeCandidate] {
        pending.map { NoticeCandidate(identity: $0.id, label: $0.displayName) }
    }

    /// Project live control requests onto notice candidates, keyed by viewer
    /// **IP**, not the TCP `connectionID`: every reconnect mints a fresh
    /// connection UUID, so a connection-keyed notice would spam on
    /// drop-and-redial.
    nonisolated static func noticeCandidates(_ requests: [ControlRequestInfo]) -> [NoticeCandidate] {
        requests.map { NoticeCandidate(identity: $0.viewerIP, label: $0.displayName) }
    }

    /// Project link offers onto notice candidates, keyed by offer id: each
    /// offer is its own decision, and the server already bounds how many
    /// one viewer can hold.
    nonisolated static func noticeCandidates(_ offers: [LinkOfferInfo]) -> [NoticeCandidate] {
        offers.map { NoticeCandidate(identity: $0.id.uuidString, label: $0.displayName) }
    }

    /// Diff the new viewer roster to fire a per-join and per-leave
    /// notification exactly once per `id`. Notifications are best-effort: dev
    /// builds without a bundle ID won't be authorized by macOS to display
    /// banners, but the in-app roster still works.
    private func handleViewersChanged(_ viewers: [ViewerInfo]) {
        let newIDs = Set(viewers.map { $0.id })
        // Departures are read from the OUTGOING roster since `viewers` no
        // longer has them: only announced arrivals get a departure, and
        // nothing posts while the share is tearing down (else one banner
        // per viewer at the moment the sharer already decided to stop).
        let departed: [SharerNotice] =
            isStoppingShare
            ? []
            : currentViewers
                .filter { !newIDs.contains($0.id) && notifiedViewerIDs.contains($0.id) }
                .map {
                    SharerNotice(
                        kind: .viewerLeft, identity: $0.id,
                        label: $0.displayName)
                }
        currentViewers = viewers
        // While a link is live, keep the tunnel-IP → node-key map fresh so
        // guest rows can show key fingerprints and evictions can resolve.
        if shareLinkToken != nil, viewers.contains(where: \.isGuest) {
            Task { @MainActor [weak self] in await self?.refreshGuestPeers() }
        }
        // Coalesced to end of turn — see `scheduleNoteRoster()`. Re-emitted
        // on any roster change, including a StableNodeID resolving, which is
        // what drains a queued Deny & Block.
        scheduleNoteRoster()
        // The shared decision prunes departed IDs (so a reconnect is
        // announced again) and posts only unannounced arrivals.
        let decision = SharerNoticeDecision.noticesToPost(
            kind: .viewerJoined,
            candidates: Self.noticeCandidates(viewers),
            alreadyNotified: notifiedViewerIDs)
        notifiedViewerIDs = decision.notified
        post(departed)
        post(decision.post)
    }

    /// Sync the published pending list and fire a "wants to view"
    /// notification for newly-arrived pending viewers, regardless of
    /// whether the popover is open.
    private func handlePendingViewersChanged(_ pending: [PendingViewerInfo]) {
        pendingViewers = pending
        // Pending guests already hold a live tunnel, so fingerprints are
        // resolvable now.
        if shareLinkToken != nil, pending.contains(where: \.isGuest) {
            Task { @MainActor [weak self] in await self?.refreshGuestPeers() }
        }
        scheduleNoteRoster()
        let candidates = Self.noticeCandidates(pending)
        let answered = SharerNoticeDecision.noticesToWithdraw(
            candidates: candidates, alreadyNotified: notifiedPendingViewerIDs)
        let decision = SharerNoticeDecision.noticesToPost(
            kind: .viewerPending, candidates: candidates,
            alreadyNotified: notifiedPendingViewerIDs)
        notifiedPendingViewerIDs = decision.notified
        // Whoever left the gate takes their banner with them, or an
        // Accept/Deny left over for somebody already watching reads as a
        // broken button.
        SharerNoticeCenter.shared.withdraw(kind: .viewerPending, identities: Array(answered))
        post(decision.post)
    }

    // MARK: - Remote control (sharer side)

    /// Sync the published control-request list and fire a "wants control"
    /// notification, whether or not the popover is open. One notification
    /// per viewer IP per pending episode; the residual reconnect-loop
    /// exposure is accepted, with "Allow control requests" as the hard stop.
    private func handleControlRequestsChanged(_ requests: [ControlRequestInfo]) {
        controlRequests = requests
        // A queued Accessibility-grant intent dies with its request:
        // however the request left the list — denied, released, viewer
        // disconnected, share stopped — auto-granting later would grant
        // something the sharer is no longer looking at.
        if let intentID = pendingAccessibilityGrantRequestID,
            !requests.contains(where: { $0.id == intentID })
        {
            clearAccessibilityGrantIntent()
        }
        let candidates = Self.noticeCandidates(requests)
        let answered = SharerNoticeDecision.noticesToWithdraw(
            candidates: candidates, alreadyNotified: notifiedControlRequestIPs)
        let decision = SharerNoticeDecision.noticesToPost(
            kind: .controlRequested, candidates: candidates,
            alreadyNotified: notifiedControlRequestIPs)
        notifiedControlRequestIPs = decision.notified
        SharerNoticeCenter.shared.withdraw(kind: .controlRequested, identities: Array(answered))
        post(decision.post)
    }

    // MARK: - Link offers (sharer side)

    /// Sync the published offer list; a banner announces each new offer and
    /// is withdrawn once it's opened, dismissed or gone. The banner has no
    /// buttons — the whole URL is only ever judged in-app.
    private func handleLinkOffersChanged(_ offers: [LinkOfferInfo]) {
        linkOffers = offers
        let candidates = Self.noticeCandidates(offers)
        let answered = SharerNoticeDecision.noticesToWithdraw(
            candidates: candidates, alreadyNotified: notifiedLinkOfferIDs)
        let decision = SharerNoticeDecision.noticesToPost(
            kind: .linkOffered, candidates: candidates,
            alreadyNotified: notifiedLinkOfferIDs)
        notifiedLinkOfferIDs = decision.notified
        SharerNoticeCenter.shared.withdraw(kind: .linkOffered, identities: Array(answered))
        post(decision.post)
    }

    /// The sharer clicked Open: the one path by which a viewer's link
    /// reaches the browser.
    func openLinkOffer(_ id: UUID) {
        guard let offer = server?.takeLinkOffer(id: id) else { return }
        guard let url = OpenLinkEntry.openableURL(offer.url) else {
            logger.log("Link offer from \(offer.displayName) isn't openable — dropped")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func dismissLinkOffer(_ id: UUID) {
        server?.dismissLinkOffer(id: id)
    }

    /// The control request the sharer explicitly clicked Grant on while the
    /// app lacked the Accessibility permission. In-memory only, so a
    /// relaunch can't resurrect a stale intent. While set, the row shows
    /// "Waiting for Accessibility permission…" and
    /// `accessibilityGrantRecheckTimer` watches for it landing.
    @Published private(set) var pendingAccessibilityGrantRequestID: UUID?

    /// 1s poll scoped to a queued grant intent. A poll, not an
    /// app-activation observer, since a TCC toggle takes effect with no
    /// edge this process can observe.
    private var accessibilityGrantRecheckTimer: Timer?

    /// Grant remote control to the requesting viewer. If the app lacks
    /// Accessibility the server refuses (fires an alert + settings
    /// deep-link) but the click is remembered as an intent, so the grant
    /// completes automatically once the permission lands.
    func grantRemoteControl(_ connectionID: UUID) {
        // The newest explicit click wins: a grant aimed at one request
        // supersedes an intent queued for another — control goes to exactly
        // one viewer, and it must be the one the sharer chose last.
        if pendingAccessibilityGrantRequestID != connectionID {
            clearAccessibilityGrantIntent()
        }
        guard server?.grantControl(toConnectionID: connectionID) == true else {
            // The only refusal a re-click could cure is missing Accessibility
            // permission — queue the intent for
            // exactly that case, and only while the request is still
            // pending (an intent for a vanished request has nothing to
            // complete).
            if !AXIsProcessTrusted(),
                controlRequests.contains(where: { $0.id == connectionID })
            {
                pendingAccessibilityGrantRequestID = connectionID
                startAccessibilityGrantRecheck()
            }
            return
        }
        clearAccessibilityGrantIntent()
    }

    /// Deny a pending control request without granting. Also drops a queued
    /// Accessibility-grant intent for it — a denied request must never
    /// auto-grant later.
    func denyRemoteControl(_ connectionID: UUID) {
        if pendingAccessibilityGrantRequestID == connectionID {
            clearAccessibilityGrantIntent()
        }
        server?.declineControlRequest(connectionID: connectionID)
    }

    /// Start the recheck poll behind a queued grant intent. Idempotent.
    private func startAccessibilityGrantRecheck() {
        guard accessibilityGrantRecheckTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recheckAccessibilityGrantIntent()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityGrantRecheckTimer = timer
    }

    /// One poll tick: complete the queued grant if the Accessibility
    /// permission has landed and the request is still pending. Also drops
    /// an intent whose request vanished by a path that bypasses
    /// `handleControlRequestsChanged` (`stopSharing` clears
    /// `controlRequests` directly), so a stale intent self-clears within a
    /// tick instead of polling forever.
    private func recheckAccessibilityGrantIntent() {
        guard let intentID = pendingAccessibilityGrantRequestID else {
            clearAccessibilityGrantIntent()  // stray timer with no intent
            return
        }
        guard controlRequests.contains(where: { $0.id == intentID }) else {
            clearAccessibilityGrantIntent()
            return
        }
        guard AXIsProcessTrusted() else { return }
        logger.log("Accessibility permission landed — completing the queued control grant")
        clearAccessibilityGrantIntent()
        if server?.grantControl(toConnectionID: intentID) != true {
            logger.log("Queued control grant no longer applicable — dropped")
        }
    }

    /// Drop the queued grant intent (if any) and stop its poll.
    private func clearAccessibilityGrantIntent() {
        if pendingAccessibilityGrantRequestID != nil {
            pendingAccessibilityGrantRequestID = nil
        }
        accessibilityGrantRecheckTimer?.invalidate()
        accessibilityGrantRecheckTimer = nil
    }

    /// Revoke the live grant (menu item, SharingCard Stop button, or panic
    /// hotkey). Safe when nobody holds control.
    func revokeRemoteControl(reason: String = "sharer revoked") {
        server?.revokeControl(reason: reason)
    }

    /// Register/unregister the panic-revoke hotkey to track the live grant,
    /// so Tailscreen only claims the chord while a viewer can actually
    /// control this Mac. Keeps `id: 2`, distinct from the mic hotkey's `id: 1`.
    private func syncRevokeControlHotkey(grantActive: Bool) {
        if grantActive {
            guard revokeControlHotkey == nil else { return }
            revokeControlHotkey = GlobalHotkey(
                keyCode: revokeHotkeyChord.keyCode,
                modifiers: revokeHotkeyChord.modifiers,
                id: 2
            ) { [weak self] in
                self?.revokeRemoteControl(reason: "panic hotkey")
            }
            // The real registration supersedes whatever the last probe
            // reported.
            revokeHotkeyRegistered = revokeControlHotkey?.isRegistered ?? false
        } else {
            revokeControlHotkey = nil  // deinit unregisters
        }
    }

    /// Alert + deep-link when a grant is refused for want of Accessibility
    /// permission. The refused grant is queued by `grantRemoteControl`, so
    /// the copy promises auto-completion rather than a second click.
    private func presentAccessibilityRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = L("Accessibility Permission Needed")
        alert.informativeText = L(
            "To let a viewer control your Mac, allow Tailscreen under System Settings → Privacy & Security → Accessibility. Tailscreen will grant control automatically once the permission is enabled."
        )
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Remote control (viewer side)

    /// Viewer clicks "Request Control" — ask the sharer and flip to the
    /// requested state (the toolbar/menu reflect it). No-op unless viewing.
    func requestRemoteControl() {
        guard connectionState == .viewing, let client else { return }
        viewerControlState = .requested
        Task { await client.requestControl() }
    }

    /// The "Open Link on Sharer…" sheet, while up. Attached to the viewer
    /// window so it goes wherever the session goes.
    private var openLinkSheet: NSWindow?

    /// Viewer clicks "Open Link on Sharer…" (popover or viewer toolbar).
    /// Pre-fills from the pasteboard only when that already holds a link
    /// the sharer would accept.
    func presentOpenLinkSheet() {
        guard connectionState == .viewing, sharerSupportsOpenLink, let viewerWindow else { return }
        focusViewerWindow()
        guard openLinkSheet == nil else { return }
        let prefill = OpenLinkEntry.prefill(
            fromPasteboard: NSPasteboard.general.string(forType: .string))
        let hosting = NSHostingController(
            rootView: OpenLinkSheet(
                initialURL: prefill,
                onSend: { [weak self] url in self?.sendOpenLink(url) },
                onCancel: { [weak self] in self?.dismissOpenLinkSheet() }))
        // Grows the sheet when the inline error line appears.
        hosting.sizingOptions = [.preferredContentSize]
        let sheet = NSWindow(contentViewController: hosting)
        openLinkSheet = sheet
        viewerWindow.beginSheet(sheet, completionHandler: nil)
    }

    private func dismissOpenLinkSheet() {
        guard let sheet = openLinkSheet else { return }
        openLinkSheet = nil
        sheet.sheetParent?.endSheet(sheet)
    }

    /// `url` already passed `OpenLinkEntry.sendable`. The confirmation
    /// reports only whether it reached the wire; the sharer's Open or
    /// Dismiss is deliberately never reported back.
    private func sendOpenLink(_ url: String) {
        dismissOpenLinkSheet()
        guard connectionState == .viewing, let client else { return }
        Task { @MainActor [weak self] in
            let sent = await client.sendOpenLink(url)
            guard let self, self.client === client, self.connectionState == .viewing else { return }
            self.showViewerNotice(
                message: sent
                    ? L("Link sent. The sharer decides whether to open it.")
                    : L("The link couldn't be sent. Try again."),
                persistent: false)
        }
    }

    /// Viewer leaves control mode and tells the sharer to release via
    /// `.controlReleased`, so the sharer's banner + gate clear in step.
    /// Covers both `.requested` and `.controlling`.
    func stopViewerControl() {
        guard viewerControlState != .none else { return }
        viewerControlState = .none
        setViewerControlCapturing(false)
        viewerHost?.showsControlBorder = false
        refreshViewerWindowTitle()
        Task { [weak self] in await self?.client?.releaseControl() }
    }

    /// Enter control mode after the sharer grants (`onControlGranted`).
    /// Lights the orange content-rect border, reflects the grant in the
    /// window title, and announces it — the state change has no focused
    /// control of its own for VoiceOver to speak.
    private func enterViewerControl() {
        viewerControlState = .controlling
        setViewerControlCapturing(true)
        viewerHost?.showsControlBorder = true
        refreshViewerWindowTitle()
        postViewerAccessibilityAnnouncement(
            L(
                "Remote control granted — your input now controls the shared Mac. Use Stop Controlling in the toolbar to release."
            ))
    }

    /// Leave control mode after the sharer revokes (`onControlRevoked`) or on
    /// disconnect. Announces only when control was actually held —
    /// cancelling a pending request isn't "control ended".
    private func exitViewerControl() {
        let wasControlling = viewerControlState == .controlling
        viewerControlState = .none
        setViewerControlCapturing(false)
        viewerHost?.showsControlBorder = false
        refreshViewerWindowTitle()
        if wasControlling {
            postViewerAccessibilityAnnouncement(L("Remote Control Ended"))
        }
    }

    /// Show/hide the input-capture layer and force the annotation overlay
    /// passive while controlling (the two are mutually exclusive).
    private func setViewerControlCapturing(_ capturing: Bool) {
        viewerControlInput?.setCapturing(capturing)
        // While controlling, pointer/keys drive input, not drawing.
        viewerOverlay?.model.isInputEnabled = !capturing
    }

    // MARK: - Answering a notification

    /// Act on a notification button press. **Every case resolves the
    /// identity against the live list first**: a banner can outlive the
    /// thing it's about, so "the row is gone" is a no-op, not an error —
    /// else an Accept could land on a different machine reusing that
    /// address. Routed into the *same* methods the in-app buttons call, so
    /// a banner decision can't diverge from a window one.
    func handleNoticeAction(kind: SharerNoticeKind, identity: String, action: NoticeAction) {
        switch kind {
        case .viewerPending:
            guard pendingViewers.contains(where: { $0.id == identity }) else {
                logger.log("Notification \(action.rawValue) for \(identity): no longer at the gate")
                return
            }
            if action == .approve {
                approvePendingViewer(identity)
            } else {
                denyPendingViewer(identity)
            }
        case .controlRequested:
            handleControlNoticeAction(viewerIP: identity, action: action)
        case .requestToShare:
            let live = pendingShareRequests.first { $0.sourceKey == identity }
            guard let request = live else {
                logger.log("Notification \(action.rawValue) for \(identity): request already gone")
                return
            }
            respondToShareRequest(request, accepted: action == .approve)
        case .viewerJoined, .viewerLeft, .linkOffered:
            // No buttons, nothing to have pressed. A link offer is an ask,
            // but one answered only in-app, where the whole URL shows.
            break
        }
    }

    /// The control-request half doesn't map 1:1: the notice is keyed by
    /// viewer IP but a grant is keyed by TCP connection. Denying applies to
    /// every request behind that address (the banner named a machine, not a
    /// socket); granting with more than one match opens the list instead of
    /// picking arbitrarily.
    private func handleControlNoticeAction(viewerIP: String, action: NoticeAction) {
        let matches = controlRequests.filter { $0.viewerIP == viewerIP }
        guard !matches.isEmpty else {
            logger.log("Notification \(action.rawValue) for \(viewerIP): request already gone")
            return
        }
        guard action == .approve else {
            for request in matches { denyRemoteControl(request.id) }
            return
        }
        guard matches.count == 1, let request = matches.first else {
            logger.log("Grant from notification is ambiguous (\(matches.count) live requests from \(viewerIP))")
            presentNoticeSurface(kind: .controlRequested)
            return
        }
        grantRemoteControl(request.id)
    }

    /// The banner body was clicked rather than one of its buttons — not an
    /// answer, so just open the hub, which renders every decision surface
    /// and can be opened programmatically (unlike the popover).
    func presentNoticeSurface(kind: SharerNoticeKind) {
        logger.log("Notification body clicked (\(kind.rawValue)) — opening the hub")
        presentMainWindow()
    }

    /// Admit a pending viewer — hands off to the live server which
    /// emits the deferred HELLO_ACK and forces a keyframe.
    func approvePendingViewer(_ id: String) {
        AppDiagnostics.action(.actionViewerApprove, ["addr": .string(id)])
        server?.approveViewer(addr: id)
    }

    /// Reject a pending viewer — server sends HELLO_DENY + SERVER_BYE so
    /// the viewer tears their session down immediately.
    func denyPendingViewer(_ id: String) {
        AppDiagnostics.action(.actionViewerDeny, ["addr": .string(id)])
        server?.denyViewer(addr: id)
    }

    /// One-time disconnect of a *connected* viewer. Nothing is remembered:
    /// the peer goes back through the normal admission gate on reconnect.
    /// For the persistent variant, use "Deny & Block" on the pending row.
    func disconnectConnectedViewer(_ id: String) {
        AppDiagnostics.action(.actionViewerKick, ["addr": .string(id)])
        server?.disconnectViewer(addr: id)
    }

    /// "Always Allow": remember the peer as allowed, then admit them now. If
    /// the StableNodeID hasn't resolved yet, queue the intent to persist on
    /// resolve; the peer is admitted one-time meanwhile.
    func approvePendingViewerAlways(_ id: String) {
        AppDiagnostics.action(
            .actionViewerApprove, ["addr": .string(id), "remembered": .bool(true)])
        if !persistPendingViewerPolicy(id, policy: .allow) {
            policyIntents.queue(id: id, policy: .allow)
            logger.log("Queued 'always allow' for \(id): StableNodeID unresolved — persist on resolve")
        }
        server?.approveViewer(addr: id)
    }

    /// "Deny & Block": remember the peer as denied, then deny them now. If
    /// the StableNodeID hasn't resolved yet, queue the intent and leave the
    /// peer parked so the block persists on resolve, rather than degrading
    /// to a one-time deny the peer could re-HELLO past.
    func denyPendingViewerAndBlock(_ id: String) {
        AppDiagnostics.action(.actionViewerBlock, ["addr": .string(id)])
        if persistPendingViewerPolicy(id, policy: .deny) {
            server?.denyViewer(addr: id)
        } else {
            policyIntents.queue(id: id, policy: .deny)
            logger.log("Queued 'deny & block' for \(id): StableNodeID unresolved — parked until resolve")
        }
    }

    /// Keep the remembered-viewers list readable across machine renames.
    /// No-ops when nothing changed.
    private func refreshRememberedDisplayNames(stableIDHostnamePairs: [(String?, String?)]) {
        for (stableID, hostname) in stableIDHostnamePairs {
            guard let stableID, let hostname else { continue }
            viewerAccessPolicies.refreshDisplayName(
                stableID: stableID,
                displayName: TailscreenInstance.displayName(fromHostname: hostname))
        }
    }

    /// Both rosters as the shared queue's identity rows. Both, never one at a
    /// time: a peer moves between them on Accept, and a snapshot of only one
    /// would prune the other's queued intents as "gone".
    private func rosterIdentities() -> [ViewerRosterDecision.RosterIdentity] {
        var rows = currentViewers.map {
            ViewerRosterDecision.RosterIdentity(
                id: $0.id, stableID: $0.stableID,
                displayName: $0.displayName)
        }
        rows.append(
            contentsOf: pendingViewers.map {
                ViewerRosterDecision.RosterIdentity(
                    id: $0.id, stableID: $0.stableID,
                    displayName: $0.displayName)
            })
        return rows
    }

    /// Queue a roster note for the end of the current main-actor turn, at
    /// most one per turn. `Accept` fires `onPendingViewersChanged` and
    /// `onViewersChanged` on separate `Task { @MainActor }` hops, so for one
    /// turn the row is in NEITHER list; coalescing to end of turn lets both
    /// land first, so the note sees a settled pair.
    private func scheduleNoteRoster() {
        guard !rosterNoteScheduled else { return }
        rosterNoteScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.rosterNoteScheduled = false
            self.noteRoster()
        }
    }

    /// Persist any queued intent whose StableNodeID has resolved, refresh
    /// remembered display names, and forget intents whose row has gone.
    /// Persisting pushes the policy to the live server.
    private func noteRoster() {
        let rows = rosterIdentities()
        for applied in policyIntents.drain(snapshot: rows) {
            viewerAccessPolicies.upsert(
                stableID: applied.stableID, displayName: applied.displayName,
                policy: applied.policy)
            logger.log(
                "Applied queued \(applied.policy) intent for \(applied.id) → \(applied.stableID)")
        }
        // Fed raw HOSTNAMES, not `RosterIdentity.displayName` (whose
        // fallback would rewrite a remembered name to a bare IP while a
        // netmap lookup is outstanding).
        var names: [(String?, String?)] = currentViewers.map { ($0.stableID, $0.hostname) }
        names.append(contentsOf: pendingViewers.map { ($0.stableID, $0.hostname) })
        refreshRememberedDisplayNames(stableIDHostnamePairs: names)
        policyIntents.prune(presentIDs: Set(rows.map(\.id)))
    }

    /// Persist a policy under the pending viewer's resolved StableNodeID.
    /// Returns false (nothing persisted) when the row is gone or its
    /// StableNodeID hasn't resolved — the caller then queues the intent.
    private func persistPendingViewerPolicy(_ id: String, policy: PeerPolicy) -> Bool {
        guard let viewer = pendingViewers.first(where: { $0.id == id }) else { return false }
        guard let stableID = viewer.stableID else { return false }
        viewerAccessPolicies.upsert(
            stableID: stableID,
            displayName: viewer.displayName,
            policy: policy
        )
        return true
    }

    /// Retitle the placard, and its VoiceOver group label with it — a stale
    /// label would announce "waiting for the sharer" over a window still
    /// dialling.
    @MainActor
    private func setViewerPlacardText(_ text: String) {
        guard viewerPlacardLabel?.stringValue != text else { return }
        viewerPlacardLabel?.stringValue = text
        viewerWaitingPlacard?.setAccessibilityLabel(text)
    }

    private func makeWaitingPlacard() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        // Seeded with the approval wording; `setViewerPlacardText` replaces
        // it per phase, so the seed is never what anybody reads.
        let waitingText = L("Waiting for the sharer to accept your connection…")
        let label = NSTextField(wrappingLabelWithString: waitingText)
        viewerPlacardLabel = label
        label.alignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 320

        // Cancel = the same full disconnect ⌘W performs.
        let cancelTarget = ClosureActionTarget { [weak self] in
            Task { @MainActor [weak self] in await self?.disconnect() }
        }
        viewerPlacardCancelTarget = cancelTarget
        let cancel = NSButton(
            title: L("Cancel"),
            target: cancelTarget,
            action: #selector(ClosureActionTarget.invoke(_:)))
        cancel.bezelStyle = .rounded

        let row = NSStackView(views: [spinner, label])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        let stack = NSStackView(views: [row, cancel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -16)
        ])

        // Grouped for VoiceOver with the waiting text as the group label;
        // the label and the Cancel button stay individually reachable
        // inside it.
        effect.setAccessibilityElement(true)
        effect.setAccessibilityRole(.group)
        effect.setAccessibilityLabel(waitingText)
        return effect
    }
}

/// Persistence for Settings → Color capture opt-ins. Plain `UserDefaults` so
/// stored-property initializers can read it without `@AppStorage`.
/// Tri-state: a never-touched install seeds from the pre-Settings env-var
/// escape hatches; once the user flips a toggle, the stored choice wins.
enum ColorCaptureDefaults {
    static let tenBitKey = "enable10BitCapture"
    static let hdrKey = "enableHDRCapture"
    /// Env names are owned by `CaptureHelperMain.captureColorInfo` (the
    /// helper-side reader) — keep the literals in sync with it.
    static let tenBitEnvKey = "TAILSCREEN_ENABLE_10BIT"
    static let hdrEnvKey = "TAILSCREEN_ENABLE_HDR"

    static func load10Bit(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        load(key: tenBitKey, envKey: tenBitEnvKey, defaults: defaults, environment: environment)
    }

    static func loadHDR(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        load(key: hdrKey, envKey: hdrEnvKey, defaults: defaults, environment: environment)
    }

    static func save10Bit(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: tenBitKey)
    }

    static func saveHDR(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: hdrKey)
    }

    private static func load(
        key: String, envKey: String, defaults: UserDefaults, environment: [String: String]
    ) -> Bool {
        if let stored = defaults.object(forKey: key) as? Bool { return stored }
        return environment[envKey] == "1"
    }
}

/// Persistence for Settings → Link Sharing. Defaults **on** — inert until a
/// share flips "Share via Link" on; the off switch is for "no tokens ever
/// leave this machine", not a safety default (approval is mandatory for
/// every guest regardless).
enum LinkSharingDefaults {
    static let enabledKey = "linkSharingEnabled"
    static let relayURLKey = "linkShareRelayURL"

    static func loadEnabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: enabledKey) as? Bool) ?? true
    }

    static func saveEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: enabledKey)
    }

    static func loadRelayURL(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: relayURLKey) ?? ""
    }

    static func saveRelayURL(_ value: String, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: relayURLKey)
    }
}

/// NSObject trampoline so AppKit target/action controls can call a
/// closure — AppState is not an NSObject and can't be a target itself.
@MainActor
private final class ClosureActionTarget: NSObject {
    private let handler: () -> Void
    init(handler: @escaping () -> Void) {
        self.handler = handler
    }
    @objc func invoke(_ sender: Any?) {
        handler()
    }
}

/// Invisible view representing the video surface to accessibility — decoded
/// frames render into a `CAMetalLayer`, not a view, so VoiceOver sees
/// nothing without this. Never hit-tests, so clicks still land on the canvas.
private final class ViewerVideoAccessibilityView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L("Shared screen"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// Simple logger for LocalAPIClient
private struct SimpleLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[LocalAPI] \(message)")
    }
}

/// AppState's own log channel, matching the per-file TSLogger pattern.
private struct AppLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[AppState] \(message)")
    }
}

/// NSWindowDelegate stand-in for the persistent viewer window. Returns
/// `false` from `windowShouldClose` so AppKit never proceeds with the
/// release cascade that crashed in earlier bisects; routes the close button
/// to AppState.disconnect, which orderOuts without releasing.
private final class ViewerWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    /// AppState distinguishes user vs programmatic resizes via a suppress
    /// flag; this delegate stays dumb.
    private let onUserResize: () -> Void
    init(onClose: @escaping () -> Void, onUserResize: @escaping () -> Void) {
        self.onClose = onClose
        self.onUserResize = onUserResize
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        return false
    }
    func windowDidResize(_ notification: Notification) {
        onUserResize()
    }
}

/// Container for the viewer window's video + annotation overlay. Lays
/// both out at the aspect-fit rect of the source video inside the host
/// bounds — optionally magnified/panned by `zoomState` — so a click on
/// the overlay maps 1:1 to a pixel on the sharer's captured screen no
/// matter how the user resizes the window or zooms the content.
private final class AspectFitHostView: NSView {
    weak var metalLayer: CAMetalLayer?
    weak var contentSubview: NSView?
    /// Remote-control input-capture layer, framed congruently with the video
    /// rect so normalizing within its bounds yields `[0, 1]` video coordinates.
    weak var inputCaptureSubview: NSView?
    /// The video surface's accessibility stand-in, framed to the video
    /// rect so VoiceOver's cursor outlines what the eye sees.
    weak var accessibilitySubview: NSView?

    /// While this viewer holds a remote-control grant, draw a visible
    /// orange outline around the video content rect. The toolbar item,
    /// window title and VoiceOver carry the same state, so color is never
    /// the only signal.
    var showsControlBorder: Bool = false {
        didSet {
            guard showsControlBorder != oldValue else { return }
            if showsControlBorder {
                let border = controlBorderLayer ?? makeControlBorderLayer()
                border.isHidden = false
            } else {
                controlBorderLayer?.isHidden = true
            }
            needsLayout = true
        }
    }
    private var controlBorderLayer: CALayer?

    private func makeControlBorderLayer() -> CALayer {
        let border = CALayer()
        border.borderWidth = 4
        border.borderColor = NSColor.systemOrange.cgColor
        // Above the sibling subview layers so the ring stays visible over
        // strokes; its interior is empty, so it obscures nothing.
        border.zPosition = 100
        layer?.addSublayer(border)
        controlBorderLayer = border
        return border
    }

    var videoSize: CGSize = .zero {
        didSet {
            guard videoSize != oldValue else { return }
            // A resolution change invalidates the content zoom's pan space.
            zoomState = ViewerZoomState()
            needsLayout = true
        }
    }

    /// Continuous content zoom/pan on top of the aspect-fit rect. Geometry
    /// lives in `ViewerZoomMath`; laying out the metal layer and the
    /// overlay from the same rect keeps strokes pixel-correct at any zoom.
    var zoomState = ViewerZoomState() {
        didSet {
            guard zoomState != oldValue else { return }
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let rect = ViewerZoomMath.videoRect(fit: aspectFitRect(), state: zoomState)
        // Disable the implicit animation so the layer snaps to the new rect
        // in lockstep with the overlay subview.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer?.frame = rect
        controlBorderLayer?.frame = rect
        CATransaction.commit()
        contentSubview?.frame = rect
        inputCaptureSubview?.frame = rect
        accessibilitySubview?.frame = rect
    }

    // MARK: - Content zoom gestures
    //
    // Events land on the annotation overlay first (it's the subview under
    // the cursor) but bubble up the responder chain to this host — the
    // overlay doesn't override any of these.

    /// Keeps the zoomed rect under Core Animation's per-axis texture limit
    /// at this window's backing scale.
    private func effectiveMaxScale(fit: CGRect) -> CGFloat {
        ViewerZoomMath.effectiveMaxScale(fit: fit, backingScale: window?.backingScaleFactor ?? 2)
    }

    /// Pinch zoom, anchored under the cursor.
    override func magnify(with event: NSEvent) {
        let fit = aspectFitRect()
        let anchor = convert(event.locationInWindow, from: nil)
        zoomState = ViewerZoomMath.zoomed(
            state: zoomState, by: 1 + event.magnification, anchor: anchor, fit: fit,
            maxScale: effectiveMaxScale(fit: fit))
    }

    /// Two-finger double-tap: toggle fit ↔ 2× at the tap point.
    override func smartMagnify(with event: NSEvent) {
        let fit = aspectFitRect()
        let anchor = convert(event.locationInWindow, from: nil)
        zoomState = ViewerZoomMath.smartMagnifyToggled(
            state: zoomState, anchor: anchor, fit: fit,
            maxScale: effectiveMaxScale(fit: fit))
    }

    /// ⌥-scroll zooms at the cursor; plain scroll pans while zoomed in.
    /// At fit (scale 1) an unmodified scroll falls through to the
    /// responder chain — nothing scrolls there today, so behavior at fit
    /// is unchanged.
    override func scrollWheel(with event: NSEvent) {
        // Non-precise devices (classic mouse wheels) report deltas in
        // line units, not points — scale up so one wheel notch moves or
        // zooms a useful amount.
        let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
        if event.modifierFlags.contains(.option) {
            let fit = aspectFitRect()
            let anchor = convert(event.locationInWindow, from: nil)
            // Normalize so scrolling up always zooms in regardless of
            // natural-scrolling preference. ~100pt doubles the zoom.
            let dy = event.scrollingDeltaY * unit
            let zoomDelta = event.isDirectionInvertedFromDevice ? -dy : dy
            let delta = CGFloat(pow(2.0, Double(zoomDelta) / 100.0))
            zoomState = ViewerZoomMath.zoomed(
                state: zoomState, by: delta, anchor: anchor, fit: fit,
                maxScale: effectiveMaxScale(fit: fit))
            return
        }
        if zoomState.isZoomedIn {
            let fit = aspectFitRect()
            // scrollingDelta is flipped (y-down); this view isn't, so
            // negate Y. Panning follows natural-scrolling (it's dragging
            // content), unlike the ⌥-zoom above.
            zoomState = ViewerZoomMath.panned(
                state: zoomState,
                by: CGSize(
                    width: event.scrollingDeltaX * unit,
                    height: -event.scrollingDeltaY * unit),
                fit: fit)
            return
        }
        super.scrollWheel(with: event)
    }

    /// Center-anchored continuous zoom step for the View-menu items
    /// (⌥⌘+ / ⌥⌘-), which have no cursor position to anchor at.
    func zoomContent(by delta: CGFloat) {
        let fit = aspectFitRect()
        zoomState = ViewerZoomMath.zoomed(
            state: zoomState, by: delta, anchor: CGPoint(x: fit.midX, y: fit.midY), fit: fit,
            maxScale: effectiveMaxScale(fit: fit))
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Toolbar height changes move `contentLayoutRect` without resizing
        // the view, so bounds-driven layout misses them.
        if let window = self.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleContentLayoutChanged),
                name: NSWindow.didChangeBackingPropertiesNotification,
                object: window)
        }
        needsLayout = true
    }

    @objc private func handleContentLayoutChanged(_ note: Notification) {
        needsLayout = true
    }

    /// Effective drawing area — `bounds` minus the unified-toolbar inset.
    /// A bounds-based aspect-fit would place equal letterboxes top and
    /// bottom, one hiding behind the opaque toolbar; `contentLayoutRect`
    /// excludes it.
    private func usableRect() -> CGRect {
        guard let window = self.window else { return bounds }
        let rect = window.contentLayoutRect
        return rect.isEmpty ? bounds : rect.intersection(bounds)
    }

    /// The shared `ViewerPointerMapping.fitRect` does the letterboxing (same
    /// arithmetic as the GTK/WinUI viewers); this supplies the
    /// toolbar-excluded pane and re-bases onto its origin.
    private func aspectFitRect() -> CGRect {
        let usable = usableRect()
        guard videoSize.width > 0, videoSize.height > 0,
            usable.width > 0, usable.height > 0
        else {
            return usable
        }
        return ViewerPointerMapping.fitRect(
            paneSize: (width: Double(usable.width), height: Double(usable.height)),
            videoSize: (width: Int(videoSize.width), height: Int(videoSize.height))
        ).offsetBy(dx: usable.minX, dy: usable.minY)
    }
}
