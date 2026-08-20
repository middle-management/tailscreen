import AppKit
import ApplicationServices
import Combine
import CoreAudio
import CoreGraphics
import CoreVideo
import Foundation
import Observation
import QuartzCore
import ScreenCaptureKit
import ServiceManagement
import SwiftUI
import TailscaleKit
import TailscreenViewer

/// Sharing-side lifecycle. `idle` → `starting` (user clicked a
/// display, SCStream coming up, retry loop running) → `active`
/// (first preview frame landed, viewers can join) → `idle`. Replaces
/// the older `isSharing` / `isStartingShare` bool pair so we can't
/// end up in inconsistent in-between states.
enum SharingState: Equatable {
    case idle
    case starting
    case active
}

/// Viewer-side lifecycle. `idle` → `connecting` (user clicked a
/// peer, tsnet dial + HELLO in flight) → `viewing` (decoder up,
/// frames rendering) → `idle`. Mirror of `SharingState` so the
/// popover can show "Connecting…" instead of silently sitting on
/// the device picker while the network handshake completes.
enum ConnectionState: Equatable {
    case idle
    case connecting
    case viewing
}

/// Why the last viewer session ended, presented in-window (reason text +
/// Reconnect/Close over the last frame) instead of the window silently
/// vanishing. The first three arrive on `.tailscreenViewerPeerClosed`
/// (the shared `ViewerCloseReason`); the deny-flavored two come from
/// `onDeniedBySharer`, which keeps its explicit alert but now also lands
/// the window in this state.
///
/// The shared `ViewerSessionEndReason` (TailscreenProtocol), which is where
/// this list moved once the GTK app's `ViewerUIState`, the hub chrome's
/// `HubSessionEndReason` and this enum turned out to be three hand-kept copies
/// of the same five endings. The name stays because every call site in this
/// app reads as `ViewerSessionEnding`.
typealias ViewerSessionEnding = ViewerSessionEndReason

@MainActor
class AppState: ObservableObject {
    @Published var sharingState: SharingState = .idle
    @Published var connectionState: ConnectionState = .idle
    /// True while a mid-share "Change Source…" flow is in flight (picker
    /// up, or the retargeted helper respawning). The SharingCard disables
    /// its Change Source button on this so a second picker can't be
    /// spawned while the first is still on screen.
    @Published var isChangingSource = false
    @Published var connectedHostname: String?
    @Published var statusMessage = ""
    /// Whether the sharer's drawing overlay panel is currently visible and
    /// accepting input. The panel itself is only created while sharing.
    @Published var isSharerOverlayVisible = false
    @Published var isMicOn = false

    /// Whether the current share is sending system/computer audio to viewers.
    /// Live latch, flipped by `toggleSystemAudio()`; reset on `stopSharing`.
    @Published var isSystemAudioOn = false

    /// User preference: turn system audio on automatically when a share
    /// starts. Persisted under `shareSystemAudio` (defaults off). SwiftUI binds
    /// the Settings toggle to this; the setter persists on every change.
    @Published var shareSystemAudioByDefault: Bool = SystemAudioDefaults.load() {
        didSet { SystemAudioDefaults.save(shareSystemAudioByDefault) }
    }

    /// Audio devices available on the system. Refreshed every time
    /// the popover opens (and before any picker rendering) — calling
    /// `AudioDevices.all()` is cheap.
    @Published var availableInputDevices: [AudioDevice] = []
    @Published var availableOutputDevices: [AudioDevice] = []

    /// User-selected device IDs. `nil` = follow system default. Set
    /// via `selectInputDevice(_:)` / `selectOutputDevice(_:)`, which
    /// also push the change down into the live `MicCapture` engine.
    @Published var selectedInputDeviceID: AudioDeviceID?
    @Published var selectedOutputDeviceID: AudioDeviceID?

    private var voiceChannel: VoiceChannel?
    private var micCapture: MicCapture?
    private var micHotkey: GlobalHotkey?

    /// Cross-instance advisory lock. Held while we're actively
    /// sharing so other Tailscreen instances on this Mac can grey
    /// out their Share button rather than try and fail.
    private let shareLock = ShareLock()

    /// Mirrors `ShareLock.isHeldByAnyone()` minus our own hold.
    /// Polled on a 2 s timer; SwiftUI binds the Share button's
    /// disabled state to it.
    @Published var anotherInstanceSharing: Bool = false
    private var shareLockProbeTimer: Timer?

    /// Snapshot of viewers currently connected to our screen-share server.
    /// Empty when not sharing or when nobody has joined yet. Populated from
    /// `TailscaleScreenShareServer.onViewersChanged`; the SharingCard reads
    /// this to render "N watching: …" with friendly hostnames.
    @Published var currentViewers: [ViewerInfo] = []

    /// Snapshot of viewers waiting for the sharer's Accept / Deny decision.
    /// Only populated when `requireViewerApproval` is on; the SharingCard
    /// renders Accept / Deny rows directly from this. Mirrors the server's
    /// `onPendingViewersChanged` callback. Cleared on `stopSharing`.
    @Published var pendingViewers: [PendingViewerInfo] = []

    /// Viewers (sharer side) asking for remote control, awaiting Grant / Deny.
    /// Mirrors the server's `onControlRequestsChanged`. Cleared on stopSharing.
    @Published var controlRequests: [ControlRequestInfo] = []

    /// The viewer (sharer side) that currently holds remote control, or nil.
    /// Mirrors the server's `onControlGrantChanged`; drives the "X is
    /// controlling your Mac" banner + Stop button. Cleared on stopSharing.
    @Published var controlGrantee: ControlGrantInfo?

    /// Viewer-side remote-control mode. `.requested` between clicking Request
    /// Control and the sharer's answer; `.controlling` once granted (input
    /// capture live). Reset on disconnect.
    @Published var viewerControlState: ViewerControlState = .none

    /// Whether the *current* sharer advertised remote-control support
    /// (`ScreenShareCaps.remoteControl` in its HELLO_ACK). The viewer's
    /// "Request Control" affordance is hidden when false, so the user never
    /// clicks a button against a sharer that can't inject input. False until
    /// the HELLO_ACK arrives and on disconnect.
    @Published var sharerSupportsRemoteControl = false

    /// Whether the current sharer advertised annotation support
    /// (`ScreenShareCaps.annotations`). The viewer's annotation toolbar is
    /// disabled when false so it doesn't draw local-only strokes at a sharer
    /// that can't render/relay them. Defaults *true* (unlike remote control)
    /// so the mac→mac common case shows tools immediately with no
    /// disable-flash; a non-supporting sharer's HELLO_ACK corrects it. Reset
    /// to true on disconnect.
    @Published var sharerSupportsAnnotations = true {
        didSet {
            guard oldValue != sharerSupportsAnnotations else { return }
            viewerToolbar?.setAnnotationsEnabled(sharerSupportsAnnotations)
        }
    }

    /// Second global hotkey (⌃⌥. by default) — a panic revoke of the live
    /// remote-control grant. Grant-scoped: created when a grant appears and
    /// destroyed when it clears (see `syncRevokeControlHotkey`), so idle
    /// sessions and pure viewers don't swallow ⌃⌥. system-wide. Keeps hotkey
    /// `id: 2` so it coexists with the mic toggle (see `GlobalHotkey`).
    private var revokeControlHotkey: GlobalHotkey?

    /// User preference: whether viewers may ask for remote control at all.
    /// Persisted via `RemoteControlDefaults` (defaults on); synced to the
    /// live server so the toggle takes effect mid-share — when off, the
    /// server declines `.controlRequest`s immediately with `.controlRevoked`.
    @Published var allowControlRequests: Bool = RemoteControlDefaults.load() {
        didSet {
            RemoteControlDefaults.save(allowControlRequests)
            server?.setAllowControlRequests(allowControlRequests)
        }
    }

    /// Viewer IPs whose *currently pending* control request already fired an
    /// OS notification. Keyed by IP (not TCP connectionID) so parallel
    /// connections and refreshes of a still-pending request collapse to one
    /// notification — the source IP is the same non-spoofable anchor the
    /// admission gate trusts. IPs are pruned when their request leaves the
    /// pending snapshot (deny/grant/release/disconnect), so a genuine
    /// re-request notifies again; the prune itself lives in
    /// `SharerNoticeDecision.noticesToPost`, and the key choice is documented
    /// on `noticeCandidates(_: [ControlRequestInfo])`. Cleared on
    /// `stopSharing`.
    private var notifiedControlRequestIPs: Set<String> = []

    /// Highest grant-change generation applied so far (see the server's
    /// `onControlGrantChanged` doc). Reset when a new server is wired up and
    /// on `stopSharing`.
    private var lastControlGrantGeneration: UInt64 = 0

    /// True when a grant-change notification carries a generation older than
    /// one already applied — the MainActor hop can reorder deliveries, and a
    /// stale nil snapshot applied last would unregister the ⌃⌥. panic hotkey
    /// while a grant is live. Equal generations are NOT stale: two racing
    /// notifies can legitimately observe the same (generation, snapshot)
    /// pair, and re-applying it is idempotent. Pure, for
    /// `RemoteControlPolicyTests`.
    nonisolated static func isStaleGrantNotification(generation: UInt64, lastApplied: UInt64) -> Bool {
        generation < lastApplied
    }

    /// True only when we *know* macOS will not display our notifications —
    /// the user explicitly denied them. Never true for "not asked yet", which
    /// would be crying wolf.
    ///
    /// Deliberately one-directional: `false` does **not** mean notifications
    /// will arrive. A Focus can filter us, Time Sensitive can be revoked, and
    /// the alert style can be None, none of which is visible to the app. So the
    /// UI built on this only ever renders a warning, and never reassures.
    @Published private(set) var notificationsDenied = false

    /// User preference: park new viewers in a pending state and require
    /// explicit Accept/Deny before they see video. Persisted to
    /// UserDefaults under `requireViewerApproval`. Defaults **on** for
    /// installs that never touched the toggle (tri-state migration in
    /// `ViewerApprovalPreference.load`, the portable preference all three
    /// apps share); an explicit opt-out sticks, and
    /// `TAILSCREEN_OPEN_DOOR=1` forces it off for the scripted harnesses.
    /// SwiftUI views bind to this via `appState.requireViewerApproval`;
    /// the setter syncs the live server too so the toggle takes effect
    /// mid-share.
    @Published var requireViewerApproval: Bool = ViewerApprovalPreference.load() {
        didSet {
            ViewerApprovalPreference.save(requireViewerApproval)
            server?.setRequireApproval(requireViewerApproval)
        }
    }

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

    /// User preference: opt the capture helper into 10-bit HEVC capture.
    /// A spawn-time env knob (`TAILSCREEN_ENABLE_10BIT`) exactly like the
    /// quality settings: pushed into `HelperScreenCapture.colorEnvironment`
    /// so every helper spawn — share start, crash restart, Change Source —
    /// picks it up, which means a mid-share flip applies on the next spawn
    /// rather than instantly. The Settings caption says so; no new restart
    /// machinery for a toggle this rare.
    @Published var enable10BitCapture: Bool = ColorCaptureDefaults.load10Bit() {
        didSet {
            guard enable10BitCapture != oldValue else { return }
            ColorCaptureDefaults.save10Bit(enable10BitCapture)
            pushColorCaptureEnvironment()
        }
    }

    /// Same knob for HDR (`TAILSCREEN_ENABLE_HDR`, BT.2020 PQ — implies
    /// 10-bit in the helper). The helper additionally gates it on the
    /// captured display actually having EDR headroom, so the toggle is an
    /// opt-in, not a promise.
    @Published var enableHDRCapture: Bool = ColorCaptureDefaults.loadHDR() {
        didSet {
            guard enableHDRCapture != oldValue else { return }
            ColorCaptureDefaults.saveHDR(enableHDRCapture)
            pushColorCaptureEnvironment()
        }
    }

    /// Project the two color toggles into the helper-spawn environment
    /// overlay. Explicit "0"s (not removal) so the Settings choice also
    /// overrides a launch-time `TAILSCREEN_ENABLE_10BIT=1` once the user
    /// has expressed one — the same value `ColorCaptureDefaults.load*`
    /// seeded from in the first place.
    private func pushColorCaptureEnvironment() {
        // Snapshot on the MainActor first — `withLock`'s closure is
        // @Sendable, so it may not read actor-isolated properties.
        let overlay = [
            ColorCaptureDefaults.tenBitEnvKey: enable10BitCapture ? "1" : "0",
            ColorCaptureDefaults.hdrEnvKey: enableHDRCapture ? "1" : "0"
        ]
        HelperScreenCapture.colorEnvironment.withLock { $0 = overlay }
    }

    // MARK: - Global hotkey chords

    /// User-configurable chord for the global mic toggle (⌃⌥M unless
    /// remapped). Persisted via `HotkeyChordStore`; the setter re-creates
    /// the live Carbon registration and reinstalls the menu bar so the
    /// File → Microphone key equivalent tracks the change.
    @Published var micHotkeyChord: HotkeyChord = HotkeyChordStore.loadMic() {
        didSet {
            guard micHotkeyChord != oldValue else { return }
            HotkeyChordStore.saveMic(micHotkeyChord)
            registerMicHotkey()
            // The File-menu key equivalent updates by itself: the menu is
            // SwiftUI Commands reading this @Published chord.
            syncShortcutChordDisplays()
            viewerToolbar?.refreshMicChordDisplay()
        }
    }

    /// User-configurable chord for the panic revoke (⌃⌥. unless remapped).
    /// The real registration is grant-scoped (`syncRevokeControlHotkey`),
    /// so outside a grant the setter only *probes* the chord — a transient
    /// register-and-release — to keep `revokeHotkeyRegistered` honest.
    @Published var revokeHotkeyChord: HotkeyChord = HotkeyChordStore.loadRevoke() {
        didSet {
            guard revokeHotkeyChord != oldValue else { return }
            HotkeyChordStore.saveRevoke(revokeHotkeyChord)
            if revokeControlHotkey != nil {
                // A grant is live: swap the registration in place. Tear the
                // old instance down first — its deinit unregisters — so the
                // (signature, id: 2) pair is free before the replacement
                // claims it.
                revokeControlHotkey = nil
                syncRevokeControlHotkey(grantActive: true)
            } else {
                revokeHotkeyRegistered = GlobalHotkey.probeAvailability(
                    keyCode: revokeHotkeyChord.keyCode,
                    modifiers: revokeHotkeyChord.modifiers)
            }
            // The viewer-side twins of the chord: the capture layer's
            // intercept and the cheat sheet's printed rows. (The two
            // File-menu key equivalents update by themselves — SwiftUI
            // Commands read this @Published chord.)
            viewerControlInput?.releaseChord = revokeHotkeyChord
            syncShortcutChordDisplays()
        }
    }

    /// Whether the last (re)registration of each global hotkey actually
    /// took. `RegisterEventHotKey` refuses a chord another app already owns
    /// and the refusal is only a return code — the user would otherwise
    /// press the key forever while nothing happens. Settings → Keyboard
    /// Shortcuts shows an inline warning while one of these is false. The
    /// revoke flag is updated both by the availability probe (chord change,
    /// launch) and by the real grant-scoped registration.
    @Published private(set) var micHotkeyRegistered = true
    @Published private(set) var revokeHotkeyRegistered = true

    /// "⌃⌥M"-style display strings for the two chords, nil when the stored
    /// chord names a key outside the display vocabulary — consumers (menu
    /// bar, tooltips, cheat sheet) hide the chord rather than misprint it.
    var micShortcutDisplay: String? { micHotkeyChord.displayString }
    var revokeShortcutDisplay: String? { revokeHotkeyChord.displayString }

    /// (Re)register the global mic-toggle hotkey from `micHotkeyChord`.
    /// Tears any prior registration down first — `GlobalHotkey.deinit`
    /// unregisters, and the (signature, id: 1) pair must be free before a
    /// replacement instance can claim it.
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
    /// `scheduleCloakRepush`). MainActor, like everything else on AppState.
    private var cloakSyncTask: Task<Void, Never>?
    private var cloakRepushForce = false

    /// Viewer IDs we've already fired a "joined" notification for this
    /// session. Keyed by the server's internal `"ip:port"` ID so a viewer
    /// who briefly drops and rejoins (different ephemeral port) gets a
    /// fresh ping, but hostname-resolution updates to the same viewer
    /// don't double-fire. Cleared on `stopSharing`.
    ///
    /// One of four notified-sets, all now carried through the same
    /// `SharerNoticeDecision.noticesToPost` rather than through four
    /// hand-written diffs. Only the *key* differs per set, and each choice is
    /// documented where the projection is made (`noticeCandidates`).
    private var notifiedViewerIDs: Set<String> = []

    /// Pending-viewer IDs already announced, same `"ip:port"` key and same
    /// forget-on-leave rule as `notifiedViewerIDs`. Previously this path
    /// diffed the incoming snapshot against the published `pendingViewers`
    /// array instead of keeping a set — which happened to behave the same and
    /// was the third hand-rolled copy of one decision. Cleared on
    /// `stopSharing`.
    private var notifiedPendingViewerIDs: Set<String> = []

    /// Request-to-share source keys already announced. Keyed by the same
    /// spoof-resistant `PendingShareRequest.sourceKey` the banner list
    /// coalesces on, so a peer retrying while its first ask is still on screen
    /// replaces one row and mints no second banner. Not cleared on
    /// `stopSharing`: these arrive while the machine is *idle* and have
    /// nothing to do with a share's lifetime — they prune themselves when the
    /// request is answered.
    private var notifiedShareRequestKeys: Set<String> = []

    /// The whole ask-to-share flow — the long-lived idempotent-per-node
    /// control listener, the coalesced/bounded inbox, and the answer
    /// sequencing (reply on the arrival connection; accept ⇒ pre-approve,
    /// then start) — written once in `TailscreenSharer` and shared with the
    /// GTK engine and the Windows app. Wired in `init`; what stays here is
    /// this host's: the `@Published` mirror, the notification reconcile, the
    /// metadata handler riding the same listener, and the picker flow accept
    /// drops into.
    private let askToShare = SharerAskToShareCoordinator()

    /// The coordinator's inbox, mirrored for the banner rows, the Dock badge
    /// and the notification-press router.
    @Published private(set) var pendingShareRequests: [PendingShareRequest] = []

    /// Requester IPs the sharer accepted (via request-to-share) but hasn't
    /// pushed to a live server yet — applied to `server.preApproveViewer`
    /// once the share starts. Cleared on `stopSharing`.
    private var pendingPreApprovedIPs: Set<String> = []

    /// "Always Allow" / "Deny & Block" intents recorded before the peer's
    /// StableNodeID resolved, keyed by the roster row's `ip:port` id.
    /// Applied (persisted under the resolved StableNodeID) the moment a
    /// roster snapshot carries that id's stableID — so the user's decision
    /// sticks instead of silently degrading to one-time.
    ///
    /// The **shared** queue (`ViewerRosterDecision.PendingIntents`, the same
    /// one `SharerAccessCoordinator` holds for the GTK and WinUI hosts) rather
    /// than the dictionary this used to be. Two behaviours came with it, and
    /// the second is the reason for the swap: last-write-wins, so a Deny &
    /// Block after an Always Allow means the second one; and `prune`, which
    /// forgets an intent whose row has gone — without it a Deny & Block on a
    /// peer that disconnects before resolving lands on *the next connection
    /// from that address*, which behind one NAT is a different machine.
    private var policyIntents = ViewerRosterDecision.PendingIntents()

    /// Set while a roster note is queued behind the current main-actor turn.
    /// See `scheduleNoteRoster()`.
    private var rosterNoteScheduled = false

    private var server: TailscaleScreenShareServer?
    private var client: TailscaleScreenShareClient?
    private var node: TailscaleNode?
    /// Where `node`'s bring-up got to, tracked so `getOrCreateNode` can tell
    /// a node whose `up()` is still blocking (a concurrent caller during the
    /// interactive browser login — hand it back) from one whose `up()` threw
    /// after the node was stored (dead — rebuild) and from one that reached
    /// Running and may have died since (ask the backend).
    private enum NodeBringUpState { case notUp, upInFlight, up }
    private var nodeBringUpState: NodeBringUpState = .notUp
    private var tailscaleIPs: [String] = []
    private var sharerOverlay: SharerOverlayWindow?
    /// Border drawn around the captured region for the whole share. Unlike
    /// `sharerOverlay` this is NOT lazy — its entire job is to be present
    /// whenever a capture is running, including the ordinary share where
    /// nobody ever draws anything.
    private var captureOutline: CaptureOutlineWindow?
    /// Decoded picker selection backing the current share. Captured in
    /// `startSharing(filterData:)` and consumed by `ensureSharerOverlay`
    /// so the overlay panel can scope itself to the shared window/app
    /// (rather than always covering the full display, which scaled
    /// viewer-drawn annotations into the wrong space when the user
    /// picked one window / one app in the native picker).
    private var currentSelection: PickerSelection?

    // Persistent viewer window + renderer. Owned for the process lifetime so
    // disconnect never closes/releases an NSWindow + CAMetalLayer chain (the
    // dealloc of those types autoreleases pooled IOSurfaces into the same
    // main-queue pool a Swift Task is about to pop, producing a SIGSEGV in
    // objc_release on every disconnect variant we tried). On disconnect we
    // orderOut the window and clear the renderer's pending frame; on connect
    // we reuse the existing instances.
    @Published var viewerWindow: NSWindow?
    /// Preferences window, lazily created on first ⌘, and kept for the
    /// process lifetime so reopening is instant and edits stay put.
    private var settingsWindow: NSWindow?
    /// Opens (or re-focuses) the docked main window scene. Stashed by the
    /// SwiftUI layer (`MainWindowView` / `MenuBarView` onAppear) because
    /// the `openWindow` environment action is only reachable from view
    /// context, while the callers here are AppKit menu items and popover
    /// rows. `@MainActor` on the function type because the stashed closure
    /// calls SwiftUI's MainActor-isolated `OpenWindowAction`. See
    /// `presentMainWindow()`.
    var openMainWindowAction: (@MainActor () -> Void)?
    private var viewerRenderer: MetalViewerRenderer?
    private var viewerOverlay: AnnotationOverlayHostView?
    /// Input-capture layer above the annotation overlay, active only while
    /// this viewer holds a remote-control grant. Framed to the video rect by
    /// `AspectFitHostView.layout`.
    private var viewerControlInput: RemoteControlInputView?
    /// The viewer window's aspect-fit host — the view that owns the
    /// continuous content zoom/pan state. Weak: the window's contentView
    /// holds it for the process lifetime. Used to reset the zoom on
    /// preset selection / video-size change / disconnect, and to route
    /// the View-menu Zoom In / Zoom Out steps.
    private weak var viewerHost: AspectFitHostView?
    /// Hosts the stats overlay subview pinned to the top-left of the
    /// viewer's content view. Held strongly so the visibility-toggle
    /// Combine subscription it owns lives for the lifetime of the
    /// viewer window.
    private var viewerStatsHost: ViewerStatsOverlayHost?
    /// Hosts the keyboard-shortcut cheat-sheet overlay. Toggled by the
    /// toolbar's "?" button and Help → Keyboard Shortcuts (⇧⌘/).
    private var viewerShortcutsHost: ViewerShortcutsOverlayHost?
    /// "Waiting for sharer to accept your connection" placard shown in the
    /// viewer window between HELLO_PENDING and the first decoded frame.
    /// Hidden by default; toggled by `viewerAwaitingApproval`.
    private var viewerWaitingPlacard: NSView?

    /// Set by `onDeniedBySharer` when a HELLO_DENY arrives — including while
    /// `connect()` is still `.connecting`. Read once by `connect()` after
    /// `client.connect()` returns so a deny that raced the connect doesn't
    /// get re-promoted to `.viewing`. Reset at the top of `connect()`.
    private var viewerWasDenied = false

    /// True between the sharer reporting HELLO_PENDING and the viewer
    /// receiving its first decoded frame. Drives the placard overlaid on
    /// the viewer window. Reset on connect/disconnect.
    @Published var viewerAwaitingApproval: Bool = false {
        didSet {
            guard viewerAwaitingApproval != oldValue else { return }
            viewerWaitingPlacard?.isHidden = !viewerAwaitingApproval
        }
    }

    /// True from `connect()` until the sharer's HELLO_ACK admits us (the
    /// SSRC assignment is the admission signal; the first decoded frame
    /// clears it too, belt-and-braces). `connect()` returns after HELLO —
    /// *before* admission — so `.viewing` alone would let the window title
    /// claim "Viewing" while the sharer hasn't let us in yet. Drives the
    /// "Connecting to <host>…" title; the approval placard stays on the
    /// separate HELLO_PENDING signal (`viewerAwaitingApproval`).
    @Published var isAwaitingAdmission: Bool = false {
        didSet {
            guard isAwaitingAdmission != oldValue else { return }
            refreshViewerWindowTitle()
        }
    }

    /// Non-nil while the viewer window shows the in-window "session ended"
    /// state. Set by `endViewerSession(reason:)`; cleared by
    /// reconnect / dismiss / a fresh `connect()`. Published so the other
    /// surfaces (menubar popover, hub) can reflect it if they choose.
    @Published private(set) var viewerSessionEnding: ViewerSessionEnding? {
        didSet {
            guard viewerSessionEnding != oldValue else { return }
            viewerSessionEndedHost?.model.state = viewerSessionEnding.map {
                sessionEndedPresentation($0)
            }
            refreshViewerWindowTitle()
        }
    }

    /// Peer of the current / most recent viewer session, kept so the ended
    /// pane's Reconnect (and the stall banner's) can redial without the
    /// user re-finding the row. `host` is what `connect(to:)` dialed (IP or
    /// name); `displayName` is what titles and messages show.
    private var lastViewerPeer: (host: String, displayName: String)?

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

    /// Fetched share status per peer (`TailscreenPeer.id` →
    /// `.metadataResponse` payload). Peers with no entry are
    /// status-unknown: never fetched, offline, no answer, or a legacy
    /// build. Refreshed by `refreshPeerShareStatus()`; entries for peers
    /// that answered nothing are removed rather than left stale.
    @Published private(set) var peerShareInfo: [String: TailscreenMetadata] = [:]
    /// Rough per-peer round-trip estimate in milliseconds, measured over
    /// the metadata TCP fetch (dial + request + response on the live
    /// Tailscale path — direct or DERP alike). An estimate, not a ping:
    /// includes TCP setup and service time, so read it as a quality
    /// indicator. Same lifecycle as `peerShareInfo`: recorded on answers,
    /// removed on no-answer, pruned with the roster.
    @Published private(set) var peerLatencyMs: [String: Int] = [:]
    private var shareStatusRefreshInFlight = false

    /// The peers the main window's Screens list renders: the raw
    /// list projected through `peerFilter` (pure decision, covered by
    /// `PeerListFilterTests` in the protocol package).
    var filteredPeers: [TailscreenPeer] {
        peerFilter.narrow(availablePeers, shareInfo: peerShareInfo)
    }

    /// Tags offered by the filter menu: the union of every discovered
    /// peer's tags plus any currently-selected tags — a selected tag whose
    /// peers left the tailnet must stay listed so it can be unselected.
    /// Shared with both other hubs, which did not have that second half.
    var knownPeerTags: [String] {
        peerFilter.knownTags(in: availablePeers)
    }
    /// True once any discovery pass has finished (successfully or not).
    /// The menubar devices section shows its loading skeleton until this
    /// flips — an empty `availablePeers` before the first pass means "no
    /// answer yet", not "no devices". Reset on sign-out with the rest of
    /// the discovery state.
    @Published var hasCompletedInitialDiscovery = false
    private var peerDiscovery: TailscalePeerDiscovery?
    /// The node the current `peerDiscovery` (and its IPN watcher) is bound
    /// to. There's one tsnet node per process, but sign-out replaces it —
    /// identity mismatch tells `discoverPeers` to rebuild the watcher
    /// instead of reusing one bound to a closed node.
    private weak var peerDiscoveryNode: TailscaleNode?

    // IPN-bus watcher dedicated to surfacing the interactive-login URL.
    // tsnet's `node.up()` blocks until login completes, so the only way to
    // unblock it on a fresh device is to listen on the IPN bus and open
    // the BrowseToURL it emits in the user's browser.
    private var authIPNWatcher: TailscaleIPNWatcher?

    // Live thumbnail of the shared screen for the menu preview
    @Published var previewImage: NSImage?

    // One-shot continuation used by `startSharing` to hold the `isSharing`
    // flip until the first preview frame has landed, so SharingCard never
    // renders its black "Capturing…" placeholder. Resumed from
    // `srv.onPreviewImage`, by `waitForFirstPreview`'s timeout, or by
    // `stopSharing` if the user bails out mid-wait.
    private var pendingFirstPreview: CheckedContinuation<Void, Never>?

    // Authentication
    var tailscaleAuth = TailscaleAuth()

    // Metadata and requests
    @Published var metadataService = TailscreenMetadataService()

    private var isLoggingIn = false

    // Gates whether the IPN-bus BrowseToURL handler actually opens a
    // browser tab. False during silent session restore at launch (so a
    // stale state file can't pop an unsolicited sign-in tab); flipped to
    // true when the user explicitly initiates `login()`.
    private var interactiveLoginRequested = false

    // `[AppState]`-prefixed log sink. Same per-file `TSLogger` pattern
    // used by the screen-share + tsnet wrappers — keeps log lines in a
    // single channel we can later route to a file or os.Logger.
    private let logger = AppLogger()

    // NotificationCenter observer tokens added in `init`. Kept so
    // `deinit` can remove them — otherwise the closures (and the `self`
    // they retain weakly) outlive the AppState and keep firing on a
    // dead instance. AppState is process-lifetime today, but the leak
    // would surface immediately if anything ever re-creates one.
    // `nonisolated(unsafe)` because `deinit` of an `@MainActor` class
    // is itself `nonisolated`; only `init` and `deinit` ever mutate
    // this, both with exclusive access to the instance.
    nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []

    // NSWorkspace's notification center + the launch-observer token
    // registered on it (the Cloaked Apps "cloaked app launched mid-share"
    // trigger). Kept separate from `notificationObservers` because those
    // tokens belong to `NotificationCenter.default` — removing a token
    // from the wrong center silently leaks it. Same `nonisolated(unsafe)`
    // rationale as above: only `init`/`deinit` mutate these, and `deinit`
    // must reach the center without touching `NSWorkspace.shared` off the
    // main actor.
    nonisolated(unsafe) private var workspaceNotificationCenter: NotificationCenter = .default
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []

    /// True once the user has manually resized the viewer window
    /// (windowDidResize fired while `suppressViewerResizeTracking` was
    /// false). When set, auto-snap on incoming video-size changes is
    /// skipped so the sharer's live resize drag doesn't tug the window
    /// out from under the user. Reset on disconnect and on any
    /// `setViewerZoom` call.
    private var userResizedViewer: Bool = false
    /// Set around programmatic `setContentSize` calls so the synchronous
    /// `windowDidResize` callback they trigger doesn't get mistaken for
    /// a user resize.
    private var suppressViewerResizeTracking: Bool = false

    /// One-shot guard so the `E2E_MARKER firstFrame ...` log line emitted
    /// from `onVideoSizeChanged` only fires once per viewer session. The
    /// scripted harness greps for this marker; firing on every size change
    /// would still work, but the single-shot keeps the log clean.
    private var didLogFirstViewerFrame: Bool = false

    init() {
        // Observe changes in tailscaleAuth and propagate them
        tailscaleAuth.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // Same forwarding for the profile registry, so the header's
        // account menu re-renders on add/switch/remove/identity updates.
        profileStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // Browser-opening is host-app policy: TailscaleAuth is portable
        // (TailscreenTransport) and never touches NSWorkspace itself.
        tailscaleAuth.onOpenAuthURL = { NSWorkspace.shared.open($0) }

        // `@Published var metadataService` only fires when the *reference*
        // changes, not when its inner `@Published` properties (notably
        // `currentMetadata`) mutate. Mirror its `objectWillChange` through
        // ours so anything reading the live metadata repaints with it.
        metadataService.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // The ask-to-share flow: the listener lifecycle, the inbox and the
        // answer sequencing are the shared coordinator's; these closures are
        // the parts that are this host's.
        askToShare.onRequestReceived = { [weak self] hostname in
            self?.logger.log("Incoming request-to-share from \(hostname)")
        }
        askToShare.onRequestsChanged = { [weak self] requests in
            guard let self else { return }
            self.pendingShareRequests = requests
            // On every change — arrival AND answer — because both edit the
            // list, and the notice for a request answered in the app has to
            // come down with it.
            self.refreshShareRequestNotices()
        }
        askToShare.onPreApproveViewer = { [weak self] sourceKey in
            guard let self else { return }
            // The sharer just consented to this named peer, so pre-approve
            // its imminent HELLO — otherwise it would park behind the
            // approval gate for a second, redundant consent. Apply to a live
            // server now and remember it for the server the picker is about
            // to spin up.
            self.pendingPreApprovedIPs.insert(sourceKey)
            self.server?.preApproveViewer(ip: sourceKey)
        }
        askToShare.onStartShare = { [weak self] in
            Task { await self?.presentNativePicker() }
        }
        askToShare.configureListener = { [weak self] listener in
            // Answer peer metadata queries (the sharing-status filter's fetch
            // half) on the same connection they arrived on. Exposes nothing
            // the tailnet can't already see (hostname is in the netmap) plus
            // the share state any admitted viewer would learn by connecting.
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

        // Push a fresh policy snapshot to the live server so "Always allow" /
        // "Deny & block" / removal take effect mid-share — but ONLY when the
        // policy-by-StableNodeID projection actually changes. A cosmetic
        // display-name refresh (fired on every viewer sighting) must not
        // trigger a full setAccessPolicies + pending/connected re-sweep.
        // `$entries` delivers the *new* array before the property write, so
        // the projection is computed from the payload, not the store.
        viewerAccessPolicies.$entries
            .map { ViewerAccessPolicyStore.policiesByStableID($0) }
            .removeDuplicates()
            .sink { [weak self] policies in
                self?.server?.setAccessPolicies(policies)
            }.store(in: &cancellables)

        // Mirror the Cloaked Apps store to the UI, and re-cloak a live share
        // when the list or the main toggle changes. The debounced
        // re-push reads the store at fire time — after the property write
        // has landed — so `$entries`'s deliver-before-write timing (which
        // the policy snapshot above has to dance around) doesn't matter.
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
        // helper: its SCContentFilter resolved applications at build time,
        // and an app that wasn't running never resolved into the exclusion
        // list. Watch for launches and force a re-push (helper respawn) so
        // the fresh filter picks it up. NSWorkspace notifications arrive on
        // its own center, not `NotificationCenter.default`.
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
                    guard self.sharingState == .active,
                        let selection = self.currentSelection,
                        selection.excludedBundleIDs.contains(bundleID)
                    else { return }
                    self.scheduleCloakRepush(force: true)
                }
            }
        )

        // Try to restore a previous session silently. If on-disk Tailscale
        // state is valid, `up()` returns quickly and the user is signed in
        // without clicking anything. If the state is stale or missing, the
        // BrowseToURL the IPN bus emits is suppressed (see
        // `interactiveLoginRequested`) so no browser tab pops unsolicited —
        // the user still sees the "Sign in with Tailscale" CTA.
        //
        // Not in UI-preview mode: the restore brings a real node up and its
        // auth check would overwrite the seeded signed-in state, flipping
        // the hub back to the Welcome pane mid-screenshot.
        if Self.isUIPreview {
            seedUIPreview()
        } else {
            Task { @MainActor [weak self] in
                await self?.attemptSessionRestore()
            }
        }

        // Scripted local E2E harness affordances. Both env vars are read
        // here (and only here) — production launches with neither set go
        // through the normal UI-driven flow unchanged. See CLAUDE.md
        // ("Local screen-share E2E") for the harness that uses these.
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
        // timeout, or a socket-error storm, told apart by the reason in
        // userInfo. Instead of the window silently vanishing, end in the
        // in-window "session ended" state (reason + Reconnect/Close over
        // the last frame).
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenViewerPeerClosed,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let reason =
                    (note.userInfo?[ViewerCloseReason.userInfoKey] as? String)
                    .flatMap(ViewerCloseReason.init(rawValue:)) ?? .connectionLost
                Task { @MainActor [weak self] in
                    guard let self = self, self.connectionState == .viewing else { return }
                    await self.endViewerSession(reason: Self.sessionEnding(for: reason))
                }
            }
        )

        // Viewer's decoder couldn't build a session for the stream's codec.
        // The client has already asked the sharer to fall back to H.264 and
        // recovery is imminent — a transient in-window banner, not a modal
        // alert parked over a stream that's about to fix itself.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenViewerDecodeFailed,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let codec = (note.userInfo?["codec"] as? String) ?? "this"
                Task { @MainActor [weak self] in
                    guard let self = self, self.connectionState == .viewing else { return }
                    self.showViewerNotice(
                        message: L(
                            "This Mac can't decode the \(codec) video stream. Asking the sharer to switch to H.264 — the picture should return in a moment."
                        ),
                        persistent: false)
                }
            }
        )

        // The decode-failure escalation ladder's last rung: frames are
        // arriving but decoding has been failing for several seconds despite
        // a keyframe request and a decoder-session rebuild. Persistent
        // banner with the recovery action attached, replacing the alert
        // that told the user to disconnect and reconnect by hand.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenViewerVideoStalled,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.connectionState == .viewing else { return }
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
                    } else if self.viewerSessionEnding != nil {
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

        // NOTE: the ⌃⌥. panic-revoke hotkey is deliberately NOT registered
        // here. It's grant-scoped — created when a remote-control grant
        // appears and destroyed when it clears (`syncRevokeControlHotkey`,
        // driven by `onControlGrantChanged`) — so an idle menubar session or
        // a pure viewer doesn't swallow ⌃⌥. system-wide for a handler that
        // would just no-op. Probe its chord once anyway so the Settings
        // pane can warn about a combo another app owns without waiting for
        // a grant to find out.
        revokeHotkeyRegistered = GlobalHotkey.probeAvailability(
            keyCode: revokeHotkeyChord.keyCode,
            modifiers: revokeHotkeyChord.modifiers)

        // Seed the helper-spawn environment overlay with the persisted
        // color-capture opt-ins (the didSet only fires on later changes).
        pushColorCaptureEnvironment()

        ViewerCommands.shared.appState = self

        // 2 s polling probe: any other Tailscreen instance on this
        // Mac currently holding the share lock? Drives the Share
        // button's disabled state in the popover.
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

        // SIGTERM / SIGINT trap (installed by `TailscreenEntry`) posts
        // this just before calling `NSApplication.terminate`. We can't
        // rely on `applicationWillTerminate` alone because it fires
        // asynchronously via the run loop; on a fast SIGTERM →
        // SIGKILL chain the helper child can still be running when
        // the main process vanishes, leaving replayd's per-PID
        // SCStream session orphaned and the green recording badge
        // stuck in Control Center. Sync-kill the helper here so it
        // dies *before* main does.
        NotificationCenter.default.addObserver(
            forName: .tailscreenWillTerminateBySignal,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.synchronouslyTerminateHelpers()
        }
    }

    /// Synchronous best-effort kill of any active capture-helper
    /// child. Called from the signal trap path before
    /// `NSApplication.terminate` so the helper gets `SIGTERM` from
    /// us deterministically; replayd then sees the helper die and
    /// releases the SCStream slot. Safe if no helper is active.
    nonisolated func synchronouslyTerminateHelpers() {
        // Run on a background queue with a short timeout — we're in
        // the signal-handler tail, can't block forever.
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
        // Remove every NotificationCenter observer we registered in
        // `init`. `removeObserver` is thread-safe, so it's safe to call
        // from deinit on any actor — no Task hop required (which would
        // be unsafe here per CLAUDE.md's "no Task { self } in deinit").
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
    /// `SCContentSharingPicker`. Once the user picks something, kicks
    /// off `startSharing(filterData:)`. User cancellation is silent —
    /// the menubar returns to idle without an alert. macOS drives the
    /// Screen Recording TCC prompt inside the picker-helper on first
    /// use; the parent process never preflights or requests permission.
    func presentNativePicker() async {
        guard let filterData = await runPickerOrAlert() else {
            // User cancelled (or the picker failed and was already alerted).
            return
        }
        await startSharing(filterData: filterData)
    }

    /// Spawn the `--picker-helper` subprocess and return the JSON
    /// `PickerSelection` bytes it produced. Returns nil on user cancel — and
    /// on spawn failure, after surfacing the localized alert — so the two
    /// picker entry points (`presentNativePicker()`, `changeShareSource()`)
    /// share one error surface and can't drift apart.
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

    /// Bake sharer-side settings into the picker's selection bytes before
    /// they're cached on the server / handed to the capture-helper:
    ///
    ///   * `captureAudio = true` so the helper configures its `.audio`
    ///     SCStream output (emission stays gated by the `setAudioEnabled`
    ///     latch, so this only makes the output exist);
    ///   * the Cloaked Apps exclusion list (`AppCloakStore`) so a display share
    ///     hides the cloaked apps' windows from viewers.
    ///
    /// Shared by `startSharing` and `changeShareSource` so the two share
    /// bring-up paths can't drift (Change Source used to ship the raw
    /// picker bytes, which silently dropped the audio output on retarget).
    /// Updates `currentSelection` on success; a decode/encode failure
    /// falls back to the original bytes untouched.
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

    /// Coalesce Cloaked Apps edits into one helper respawn (~500 ms cancel-and-
    /// replace, like the quality-ceiling debounce): every re-push restarts
    /// the capture-helper, so an un-debounced multi-add in Settings would
    /// burst restarts. `force` skips the no-change guard — used when a
    /// cloaked app *launches* mid-share: the exclusion list is byte-identical
    /// but the live filter was built before the app existed, so only a
    /// respawn actually cloaks it.
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
    /// the exclusion set actually changed (or `force`). Rides the same
    /// `server.changeSource` tracked-restart path as "Change Source…", so
    /// viewers recover via the fresh helper's in-band parameter sets; the
    /// sharer overlay and annotations are untouched because the shared
    /// surface itself is unchanged.
    private func applyCloakToActiveShare(force: Bool) async {
        guard sharingState == .active, let server, let selection = currentSelection else { return }
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
            // The old helper is already gone by the time changeSource
            // throws; mirror changeShareSource's failure handling so the
            // share doesn't linger frozen.
            logger.log("appCloak: live re-push failed (\(error)); tearing sharing down")
            await stopSharing(reason: "appCloak repush failed: \(error)")
            presentError(.sharingGeneric(error))
        }
    }

    /// Tailnet-visible hostname for this instance. Shared by `startSharing`
    /// (server bring-up + metadata) and `changeShareSource` (metadata
    /// refresh) so the strings can't drift apart.
    private static func localHostname() -> String {
        "\(Host.current().localizedName ?? "tailscreen-share")\(TailscreenInstance.hostnameSuffix)"
    }

    /// Share name published to peers via the metadata service. Deliberately
    /// not localized — it travels over the wire to viewers whose locale we
    /// don't know, matching `TailscreenMetadataService.updateMetadata`'s own
    /// default.
    private static func localShareName() -> String {
        "\(localHostname())'s Screen"
    }

    /// Mid-share "Change Source…": re-run the picker-helper and retarget
    /// the live server at the new selection *without* disconnecting
    /// viewers, dropping the tsnet listeners, or releasing the share lock
    /// (we already hold it — re-acquiring would trip the guard). Picker
    /// cancel or picker error leaves the current share untouched; a failed
    /// retarget tears the share down (the old helper is already gone by
    /// then, so there is nothing to keep sharing). A Stop Sharing that
    /// races the retarget is a quiet no-op here — the stop path owns
    /// teardown, and every success side effect is gated on a post-await
    /// re-validation of the share.
    ///
    /// Deliberately separate from `presentNativePicker()` — that path is
    /// the share *entry point* (takes the lock, builds the server); this
    /// one requires an already-active share.
    func changeShareSource() async {
        guard sharingState == .active, let server, !isChangingSource else { return }
        isChangingSource = true
        defer { isChangingSource = false }

        guard let filterData = await runPickerOrAlert() else {
            // User cancelled (or the picker failed and was already
            // alerted) — keep the current share running unchanged.
            return
        }
        // The user may have clicked Stop Sharing (or the helper may have
        // died past its crash budget and torn the share down) while the
        // picker was up. Identity-check the server so a stale selection
        // can't retarget a share that already ended or restarted.
        guard sharingState == .active, self.server === server else { return }

        currentSelection = try? JSONDecoder().decode(PickerSelection.self, from: filterData)
        let effectiveFilterData = applyingShareTransforms(to: filterData)
        let didRetarget: Bool
        do {
            didRetarget = try await server.changeSource(filterData: effectiveFilterData)
        } catch is CancellationError {
            // The restart task throws CancellationError when the share was
            // stopped while the retarget was in flight — a deliberate stop,
            // not a retarget failure. The stop path owns teardown; a second
            // stopSharing or an error alert here would fight it.
            logger.log("changeShareSource: share stopped mid-retarget — leaving teardown to the stop path")
            return
        } catch {
            logger.log("changeShareSource: retarget failed (\(error)); tearing sharing down")
            await stopSharing(reason: "changeSource failed: \(error)")
            presentError(.sharingGeneric(error))
            return
        }

        // Re-validate after the awaits: `changeSource` returns false when
        // the server was already stopping, and the share may have been torn
        // down (or even restarted with a fresh server) while the retarget
        // was in flight. Running the success side effects below against a
        // stopped share would re-advertise it via metadata and resurrect
        // overlay state the stop path just tore down — the phantom-share
        // bug. On a failed re-check the stop path owns teardown; just leave.
        guard didRetarget, sharingState == .active, self.server === server else {
            logger.log("changeShareSource: share ended mid-retarget — skipping success side effects")
            return
        }

        // Annotations were scoped to the old surface — a window-relative
        // stroke floating over an unrelated display share is noise. Clear
        // every viewer's canvas; the sharer's own canvas is cleared by the
        // overlay rebuild below.
        await server.broadcastAnnotation(.clearAll)

        // The overlay's mode is immutable, so it can't be retargeted —
        // rebuild it for the new selection, preserving the sharer's draw
        // toggle. When drawing is off, leave it nil: `ensureSharerOverlay`
        // lazily rebuilds on the next viewer op or Draw toggle.
        let wasDrawing = isSharerOverlayVisible
        sharerOverlay?.hide()
        sharerOverlay = nil
        if wasDrawing {
            ensureSharerOverlay().setInputEnabled(true)
        }
        // Same reason, same immutability: the outline's mode is fixed at
        // construction, so a mid-share source change has to rebuild it or it
        // would keep framing the region that is no longer being shared.
        showCaptureOutline()

        // Refresh the metadata served to peers (share name / resolution)
        // and drop the stale thumbnail — the fresh helper repopulates it
        // with its first preview frame. Viewers need no signaling: the new
        // helper's first AU is an IDR with in-band parameter sets, which
        // rides the existing decoder-reconfigure → onVideoSizeChanged path.
        metadataService.updateMetadata(isSharing: true, shareName: Self.localShareName())
        previewImage = nil
        logger.log("changeShareSource: retargeted capture (filter=\(filterData.count)B)")
    }

    /// Start a share against the `PickerSelection` produced by the
    /// picker subprocess. The JSON-encoded selection is cached on
    /// the server so a mid-stream helper crash can rebuild the same
    /// SCStream without re-presenting the picker.
    func startSharing(filterData: Data) async {
        // Take the cross-instance share lock first. If another local
        // Tailscreen instance is already capturing, replayd will
        // refuse our SCStream with -3805 anyway — bail with a clear
        // alert instead of letting the user watch the bring-up
        // dance through and fail.
        guard shareLock.tryAcquire() else {
            anotherInstanceSharing = true
            showAlertMessage(
                title: "Another Tailscreen Is Sharing",
                message:
                    "Another Tailscreen instance on this Mac is already capturing the screen. Stop sharing on the other instance, then try again."
            )
            return
        }
        // Re-read notification authorization at every share start. The one-shot
        // prompt is answered once, but the user can revoke it in System
        // Settings at any time afterwards — and with approval defaulting on,
        // a sharer whose approval banners will never appear is a sharer who
        // strands viewers without ever learning why. The answer arrives
        // asynchronously and lands on `notificationsDenied`, which the sharing
        // card watches.
        SharerNoticeCenter.shared.onAuthorizationChanged = { [weak self] state in
            self?.notificationsDenied = (state == .denied)
        }
        SharerNoticeCenter.shared.refreshAuthorization()
        // Decode the picker selection so the sharer overlay (built lazily
        // when the first annotation arrives or "Draw on Screen" is toggled)
        // can scope its panel to the shared window/app instead of the
        // whole display. A decode failure isn't fatal — we just fall
        // back to the legacy full-display overlay.
        currentSelection = try? JSONDecoder().decode(PickerSelection.self, from: filterData)
        // Bake the sharer-side settings (system-audio output, Cloaked Apps
        // exclusions) into the selection bytes the server caches.
        let effectiveFilterData = applyingShareTransforms(to: filterData)
        sharingState = .starting
        // Cleanup contract: any path out of this function (success,
        // failure, cancellation) leaves `sharingState` consistent.
        // Success sets `.active` below. Every failure / catch sets
        // `.idle` explicitly via `await stopSharing` or
        // `sharingState = .idle`. Defer here is the safety net for
        // any path we forgot.
        defer {
            if sharingState == .starting {
                sharingState = .idle
                shareLock.release()
                // Honour the same contract for the outline: a share that
                // never reached `.active` must not leave a border on screen
                // claiming one is running.
                captureOutline?.hide()
                captureOutline = nil
            }
        }
        do {
            // If Tailscale is already initialized, just start sharing
            // Otherwise, initialize it first
            if server == nil {
                let hostname = Self.localHostname()
                let srv = TailscaleScreenShareServer()
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
                        guard self.sharingState == .active || self.sharingState == .starting else { return }
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
                    // The portable server hands up the capture backend's
                    // encoded bytes; decoding to an `NSImage` is this host's
                    // job and happens here, at the point of display.
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

                // Viewer-originated annotations land directly on the sharer's
                // overlay panel. In display mode SCStream captures the panel
                // along with the rest of the display, so the drawings flow
                // out to every other viewer via the H.264 stream for free.
                // In window / application modes the panel sits above (not
                // inside) the captured surface, so for now those modes only
                // mirror viewer strokes back to the sharer — a server-side
                // annotation fan-out is needed to reach other viewers.
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

                lastControlGrantGeneration = 0  // fresh server, fresh counter
                srv.onControlGrantChanged = { [weak self] generation, grant in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // The Task hop can reorder deliveries; a stale nil
                        // snapshot landing after a fresh grant would strand
                        // the panic hotkey unregistered. Apply only
                        // monotonically newer generations.
                        guard
                            !Self.isStaleGrantNotification(
                                generation: generation,
                                lastApplied: self.lastControlGrantGeneration)
                        else { return }
                        self.lastControlGrantGeneration = generation
                        self.controlGrantee = grant
                        // Grant-scoped ⌃⌥. panic hotkey: register while a
                        // grant is live, unregister the moment it clears.
                        // Revoke/stop/disconnect all funnel through this
                        // callback, so no extra unregister sites are needed.
                        self.syncRevokeControlHotkey(grantActive: grant != nil)
                    }
                }

                srv.onControlAccessibilityRequired = { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.presentAccessibilityRequiredAlert()
                    }
                }

                // Sync the toggle state to the server before `start()` so a
                // viewer racing to HELLO during bring-up is caught. Same
                // for the remembered allow/deny snapshot.
                srv.setRequireApproval(requireViewerApproval)
                srv.setAccessPolicies(viewerAccessPolicies.policiesByStableID)
                // Same pattern for the control-request gate: latch before
                // start so a viewer racing to request control is caught.
                srv.setAllowControlRequests(allowControlRequests)
                // System audio: apply the persisted default before the helper
                // (re)spawns so the latch is in place when it comes up.
                isSystemAudioOn = shareSystemAudioByDefault
                srv.setShareSystemAudio(shareSystemAudioByDefault)
                // Carry over any request-to-share pre-approvals so an
                // accepted requester's HELLO auto-admits on this fresh server.
                //
                // CLEARED as they are replayed, which is what the GTK and WinUI
                // engines do. A pre-approval is a single-use invitation — the
                // server consumes the IP on the matching HELLO — so holding it
                // here past the handover means a later server built for the
                // same share (a re-target, a rebuild) re-invites a peer who has
                // already been through the gate once, letting them skip it
                // again on a share they were never asked about.
                for ip in pendingPreApprovedIPs {
                    srv.preApproveViewer(ip: ip)
                }
                pendingPreApprovedIPs.removeAll()

                // Sharer's audio SSRC is fixed at 0. Build the channel up
                // front so HELLO_ACK assignment for viewers can route
                // through, and inbound viewer audio can be decoded.
                // Start playback engine immediately so the sharer can hear
                // viewers without first toggling their own mic on.
                do {
                    let voice = try VoiceChannel(localSSRC: RTPHeader.sharerVoiceSSRC) { [weak srv] packet in
                        srv?.sendAudioRTP(packet)
                    }
                    self.voiceChannel = voice
                    srv.onAudioReceived = { [weak voice] packet in
                        voice?.receive(packet)
                    }
                    let cap = MicCapture(channel: voice)
                    try cap.startPlayback()
                    self.micCapture = cap
                } catch {
                    presentError(.voiceInitFailed(error))
                }

                do {
                    // Reuse the AppState-owned tsnet node so the screen
                    // share doesn't spin up a second machine that needs
                    // its own browser sign-in.
                    let sharedNode = try await getOrCreateNode()
                    try await srv.start(
                        hostname: hostname,
                        filterData: effectiveFilterData,
                        quality: qualitySettings,
                        existingNode: sharedNode,
                        controlListener: askToShare.controlListener
                    )
                } catch {
                    // Tear down anything `start` brought up before throwing —
                    // listeners, encoder, capture pipeline — so a future
                    // Start Sharing rebuilds from scratch.
                    await srv.stop()
                    server = nil
                    // `CancellationError` here means the user clicked Stop
                    // Sharing while we were mid-bring-up; suppress the
                    // failure alert because the cancellation was intentional.
                    if error is CancellationError {
                        return
                    }
                    if case ScreenCaptureError.startTimeout = error {
                        presentError(.screenCaptureStartTimeout())
                    } else if case ScreenCaptureError.bundleSlotPoisoned = error {
                        presentError(.screenCaptureBundlePoisoned())
                    } else if case ScreenCaptureError.noFramesDelivered = error {
                        presentError(.screenCaptureNoFrames())
                    } else {
                        presentError(.screenCaptureGeneric(error))
                    }
                    return
                }

                // Get the Tailscale IP addresses
                let ips = try await srv.getIPAddresses()
                tailscaleIPs = [ips.ip4, ips.ip6].compactMap { $0 }
            }

            // Update metadata
            metadataService.updateMetadata(isSharing: true, shareName: Self.localShareName())

            // Hold the UI on the picker until the first preview frame
            // arrives, so SharingCard skips its black "Capturing…"
            // placeholder and lands with the live thumbnail visible.
            await waitForFirstPreview(timeout: .milliseconds(500))

            // Raise the capture outline once capture is genuinely running.
            // Earlier would draw a boundary around a share that may still
            // fail to start, which is the same lie as an outline that lags.
            showCaptureOutline()

            sharingState = .active
        } catch {
            presentError(.sharingGeneric(error))
        }
    }

    /// Reentrancy guard for `stopSharing`. The give-up paths (receive-loop
    /// death, exhausted helper crash budget) can fire `onCaptureStopped`
    /// concurrently with a user-initiated Stop Sharing; both land on the
    /// MainActor but interleave across `stopSharing`'s await points, which
    /// double-ran `server.stop()` and `shareLock.release()`.
    private var isStoppingShare = false

    func stopSharing(reason: String = "<unknown>", caller: String = #function) async {
        if isStoppingShare {
            logger.log("stopSharing: already in progress — ignoring reentrant call by \(caller) (reason=\(reason))")
            return
        }
        isStoppingShare = true
        defer { isStoppingShare = false }
        logger.log("stopSharing: called by \(caller) (reason=\(reason))")
        // Unblock any startSharing still waiting on the first preview, so
        // a fast start→stop doesn't strand its continuation.
        if let cont = pendingFirstPreview {
            pendingFirstPreview = nil
            cont.resume()
        }

        await server?.stop()
        server = nil
        micCapture?.stop()
        micCapture = nil
        voiceChannel = nil
        isMicOn = false
        isSystemAudioOn = false
        previewImage = nil
        currentViewers = []
        pendingViewers = []
        controlRequests = []
        controlGrantee = nil
        revokeControlHotkey = nil
        lastControlGrantGeneration = 0
        // Take the actionable banners down with the share. Both asks are
        // answerable only by a running server, so once it is gone their
        // buttons can do nothing — and an Accept still sitting in Notification
        // Center after the sharer pressed Stop is the surface contradicting the
        // app. Withdrawn before the sets are cleared, since the sets are the
        // record of what was posted.
        SharerNoticeCenter.shared.withdraw(
            kind: .viewerPending, identities: Array(notifiedPendingViewerIDs))
        SharerNoticeCenter.shared.withdraw(
            kind: .controlRequested, identities: Array(notifiedControlRequestIPs))
        notifiedControlRequestIPs.removeAll()
        notifiedViewerIDs.removeAll()
        notifiedPendingViewerIDs.removeAll()
        pendingPreApprovedIPs.removeAll()
        // The rows are gone, and an intent that outlived the share it was made
        // during would apply to whoever connects to the NEXT one from the same
        // address — `SharerAccessCoordinator.reset()`'s reasoning, same queue.
        policyIntents = ViewerRosterDecision.PendingIntents()
        tailscaleIPs = []

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
        overlay.onOp = { [weak self] op in
            Task { [weak self] in
                await self?.server?.broadcastAnnotation(op)
            }
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

    /// True when the SCStream stopped because the user clicked the
    /// macOS Control Center "Stop" button. SCStream surfaces this as
    /// `SCStreamError.Code.userStopped`. Anything else (replayd XPC
    /// drop, transient SCK failures, nil) is treated as recoverable
    /// and triggers `restartCapture()`. Pulled out as a static so the
    /// decision logic is unit-testable without standing up a stream.
    nonisolated static func isUserInitiatedCaptureStop(_ error: Error?) -> Bool {
        guard let nsErr = error as NSError? else { return false }
        // The portable server raises its own domain (it can't depend on
        // ScreenCaptureKit); a real `SCStreamError` can still reach us from
        // elsewhere in the mac capture stack, so both count.
        if nsErr.domain == TailscaleScreenShareServer.userStoppedErrorDomain { return true }
        return nsErr.domain == SCStreamError.errorDomain
            && nsErr.code == SCStreamError.Code.userStopped.rawValue
    }

    /// What `onCaptureStopped` should do about a capture failure. The server
    /// runs its own crash-budget restarts internally, so every error it hands
    /// up is a give-up signal — but only *some* of them are recoverable with a
    /// fresh-budget retry. The terminal domains (dead receive loop; a helper
    /// exit the server classified non-retryable, e.g. the shared window
    /// closed) must tear the share down: retrying loops forever against a
    /// source that will never come back. Pure so the routing is unit-testable
    /// without a live stream.
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
        guard sharingState == .active else { return }
        let overlay = ensureSharerOverlay()
        isSharerOverlayVisible.toggle()
        overlay.setInputEnabled(isSharerOverlayVisible)
    }

    /// Toggle outbound microphone capture. The playback engine is started
    /// at session-start time, so listening always works; toggleMic only
    /// flips capture on/off (and lazily requests mic permission on first
    /// enable).
    /// Refresh `availableInputDevices` / `availableOutputDevices`.
    /// Call before any device-picker UI renders (e.g. when the
    /// popover opens). Cheap — a few HAL property reads.
    func refreshAudioDevices() {
        availableInputDevices = AudioDevices.inputs()
        availableOutputDevices = AudioDevices.outputs()
        // If the user's previous pick was unplugged, fall back to
        // the system default so the picker doesn't sit on a stale ID.
        if let id = selectedInputDeviceID, !availableInputDevices.contains(where: { $0.id == id }) {
            selectedInputDeviceID = nil
        }
        if let id = selectedOutputDeviceID, !availableOutputDevices.contains(where: { $0.id == id }) {
            selectedOutputDeviceID = nil
        }
    }

    func selectInputDevice(_ deviceID: AudioDeviceID?) {
        selectedInputDeviceID = deviceID
        guard let cap = micCapture else { return }
        Task { @MainActor in await cap.setInputDevice(deviceID) }
    }

    func selectOutputDevice(_ deviceID: AudioDeviceID?) {
        selectedOutputDeviceID = deviceID
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
            return
        }
        do {
            try await cap.enableCapture()
            voice.isMuted = false
            isMicOn = true
        } catch {
            presentError(.microphoneUnavailable(error))
            isMicOn = false
        }
    }

    /// Flip whether the current share sends system audio to viewers. Instant —
    /// the helper always has the audio output configured, so this just toggles
    /// the emission latch. No permission dance: Screen Recording TCC already
    /// covers SCK audio. No-op when not sharing.
    func toggleSystemAudio() {
        isSystemAudioOn.toggle()
        server?.setShareSystemAudio(isSystemAudioOn)
    }

    /// Connect to a sharer. `displayName` is what titles and messages call
    /// the peer (defaults to `host`, which may be a bare tailnet IP).
    func connect(to host: String, displayName: String? = nil) async {
        guard !host.isEmpty else { return }

        connectionState = .connecting
        defer {
            if connectionState == .connecting {
                connectionState = .idle
                isAwaitingAdmission = false
            }
        }
        viewerWasDenied = false
        viewerAwaitingApproval = false
        // A fresh connect owns the window again — drop any leftover
        // ended-state pane / notice banner from the previous session.
        viewerSessionEnding = nil
        dismissViewerNotice()
        lastViewerPeer = (host: host, displayName: displayName ?? host)
        isAwaitingAdmission = true
        let renderer = ensureViewer()
        refreshViewerWindowTitle()
        refreshViewerVideoAccessibilityLabel()
        // Belt-and-braces zoom reset at session entry: disconnect()
        // already resets, and `videoSize.didSet` resets on a resolution
        // change — but a new sharer streaming at the *same* resolution
        // fires neither, and must not inherit the previous session's zoom.
        viewerHost?.zoomState = ViewerZoomState()
        do {
            let c = TailscaleScreenShareClient(renderer: renderer)
            client = c

            // HELLO_PENDING means the sharer parked us behind the approval
            // gate. Surface the placard so the viewer doesn't sit on a
            // black window with no explanation; first decoded frame clears
            // it via `onVideoSizeChanged`.
            c.onAwaitingApproval = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.viewerAwaitingApproval = true
                }
            }

            // HELLO_DENY: the sharer clicked Deny (or has us blocked). Tear
            // the session down first, then explain — the alert is modal, so
            // running it before disconnect would leave a dead session on
            // screen behind it.
            c.onDeniedBySharer = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // Accept the deny in `.connecting` too: a synchronous
                    // HELLO_DENY (cached StableNodeID) can land while
                    // `connect()` is still mid-flight, and dropping it would
                    // strand a zombie session — the receive loop has already
                    // returned. The `viewerWasDenied` flag keeps `connect()`
                    // from re-promoting to `.viewing` after this teardown.
                    let state = self.connectionState
                    guard state == .viewing || state == .connecting else { return }
                    // Same wire byte covers two situations, told apart by
                    // where we were when it landed: still waiting on the
                    // approval placard means our request was declined;
                    // already watching (placard long gone) means the
                    // sharer kicked us mid-session. Snapshot before
                    // teardown resets `viewerAwaitingApproval`.
                    let wasWatching = state == .viewing && !self.viewerAwaitingApproval
                    self.viewerWasDenied = true
                    // When the window is already on screen, land it in the
                    // ended state so it doesn't vanish under the alert; a
                    // deny that raced `connect()` (window never shown)
                    // keeps the plain teardown.
                    if self.viewerWindow?.isVisible == true {
                        await self.endViewerSession(
                            reason: wasWatching ? .disconnectedBySharer : .declined)
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

            // Server fans out sharer-painted strokes (and other viewers'
            // strokes) over the annotation back-channel. Apply them to the
            // local overlay's model so window / application share modes
            // render annotations the same way display mode used to via
            // SCStream picking up the overlay panel.
            c.onAnnotationReceived = { [weak self] op in
                Task { @MainActor [weak self] in
                    self?.viewerOverlay?.model.apply(remoteOp: op)
                }
            }

            c.onRemoteControlSupportChanged = { [weak self] supported in
                Task { @MainActor [weak self] in
                    self?.sharerSupportsRemoteControl = supported
                }
            }

            c.onAnnotationSupportChanged = { [weak self] supported in
                Task { @MainActor [weak self] in
                    self?.sharerSupportsAnnotations = supported
                }
            }

            c.onControlGranted = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.connectionState == .viewing else { return }
                    // Only enter control if we're still actually asking for it.
                    // A viewer that clicked Request then Stop before the answer
                    // shouldn't be silently forced into capturing by a late
                    // grant — tell the sharer to release it instead.
                    guard self.viewerControlState == .requested else {
                        Task { [weak self] in await self?.client?.releaseControl() }
                        return
                    }
                    self.enterViewerControl()
                }
            }

            c.onControlRevoked = { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self else { return }
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

            // Install the audio callback BEFORE connecting. HELLO_ACK can
            // arrive on the receive loop the moment connect() returns (or
            // even slightly before, if the loop is scheduled fast); a
            // callback installed afterwards races and may miss the only
            // assignment the client ever surfaces.
            c.onAudioSSRCAssigned = { [weak self, weak c] ssrc in
                Task { @MainActor [weak self, weak c] in
                    guard let self = self, let c = c else { return }
                    // The SSRC assignment IS the admission signal — the
                    // pre-admission "Connecting to…" title ends here.
                    self.isAwaitingAdmission = false
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

            // Reuse the AppState-owned tsnet node so connecting doesn't
            // spin up a third machine + browser sign-in flow.
            let sharedNode = try await getOrCreateNode()
            try await c.connect(to: host, port: NetworkConfig.tailscreenPort, existingNode: sharedNode)

            // A HELLO_DENY that landed while we were still `.connecting` has
            // already torn the session down and alerted; don't re-promote it
            // to `.viewing` (which would resurrect a dead session).
            if viewerWasDenied { return }

            connectionState = .viewing
            connectedHostname = displayName ?? host
            refreshViewerWindowTitle()
            refreshViewerVideoAccessibilityLabel()
            NSApp.activate(ignoringOtherApps: true)
            viewerWindow?.orderFrontRegardless()
            viewerWindow?.makeKeyAndOrderFront(nil)
        } catch {
            presentError(.connectionFailed(host: host, underlying: error))
            client = nil
            isAwaitingAdmission = false
        }
    }

    /// Holds a strong ref to the window's delegate; NSWindow.delegate is
    /// weak. The delegate intercepts windowShouldClose so the close button
    /// disconnects via AppState rather than letting AppKit destroy the
    /// persistent NSWindow.
    private var viewerWindowDelegate: ViewerWindowDelegate?

    /// Strong ref to the viewer toolbar's NSToolbarDelegate. NSWindow.toolbar
    /// holds the toolbar itself but the delegate is weak; without this it
    /// would dealloc and the toolbar would stop building items.
    private var viewerToolbar: ViewerToolbar?

    /// Build (once) and return the shared viewer renderer. The window's
    /// close button maps to AppState.disconnect via a delegate that
    /// returns false from windowShouldClose so AppKit never tears the
    /// NSWindow + CAMetalLayer graph down (that release cascade was the
    /// SIGSEGV source we bisected at length).
    func ensureViewer() -> MetalViewerRenderer {
        if let r = viewerRenderer { return r }

        let r = MetalViewerRenderer()
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Reflect the peer in the title bar (native apps put the context
        // there); falls back to the app name before the first connect.
        // `refreshViewerWindowTitle` owns it from here on.
        win.title = connectedHostname.map { L("Viewing \($0)") } ?? "Tailscreen"
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        // Full-screen capable (⌃⌘F / the zoom button's Enter Full Screen).
        win.collectionBehavior.insert(.fullScreenPrimary)
        // Standard frame persistence. A frame restored from a previous run
        // must win over the first-frame auto-snap — the user put the
        // window there — so remember whether one existed; the View-menu
        // size presets clear the latch, being an explicit "snap me" ask.
        viewerRestoredSavedFrame = win.setFrameUsingName(Self.viewerFrameAutosaveName)
        _ = win.setFrameAutosaveName(Self.viewerFrameAutosaveName)

        // Drawing toolbar: pen / line / arrow / rectangle / oval +
        // undo + clear. Items target ViewerCommands.shared, same wiring
        // the menubar's Tools/Edit menus use.
        let toolbar = ViewerToolbar(appState: self)
        win.toolbar = toolbar.toolbar
        win.toolbarStyle = .unified
        self.viewerToolbar = toolbar
        // Sync the toolbar to the sharer's annotation capability, in case the
        // HELLO_ACK already resolved it before the window (and toolbar) came up.
        toolbar.setAnnotationsEnabled(sharerSupportsAnnotations)

        let delegate = ViewerWindowDelegate(
            onClose: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if self.connectionState == .viewing {
                        await self.disconnect()
                    } else {
                        // Ended state, mid-connect, or a stray close: act
                        // like a plain close. The NSWindow itself stays
                        // alive (process-lifetime), so this orders out
                        // rather than letting AppKit run the release
                        // cascade — previously this branch was a no-op and
                        // the close button did nothing outside `.viewing`.
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

        // The host view explicitly aspect-fits both the metal layer and
        // the annotation overlay to the video's pixel size. Without this
        // the overlay covered the full window while `.resizeAspect`
        // letterboxed the video — a click 50% across a 16:9 window
        // streamed to a 16:10 sharer landed at ~46% of the captured
        // screen, off by a noticeable amount.
        // NSWindow autocreates a contentView at init; the guard is
        // defence-in-depth in case AppKit ever returns nil on a future
        // OS. Falling back to the window's frame keeps the host sized
        // sensibly so the user still sees video instead of a crash.
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

        // Accessibility stand-in for the video surface: decoded frames
        // render into a CAMetalLayer, which is not a view — without this
        // the window reads as empty to VoiceOver. Framed to the same fit
        // rect as the Metal layer; never participates in hit-testing.
        let videoA11y = ViewerVideoAccessibilityView(frame: hostFrame)
        host.addSubview(videoA11y)
        host.accessibilitySubview = videoA11y
        self.viewerVideoAccessibilityView = videoA11y
        refreshViewerVideoAccessibilityLabel()
        // Mirror any video-size changes onto the host so it relays out the
        // overlay to the new aspect rect, and (unless the user has
        // dragged the viewer to a custom size) snap the window to the
        // captured content's pixel dims so video renders 1:1 — no
        // upscale blur, no black letterbox bars. The auto-snap is
        // skipped once the user has manually resized; the View menu's
        // Actual Size / 50% / 200% items reset that opt-out.
        r.onVideoSizeChanged = { [weak self, weak host, weak win] size in
            // A resolution change also resets the content zoom — that
            // lives in `AspectFitHostView.videoSize.didSet` so it holds
            // for every producer of the property.
            host?.videoSize = size
            guard let self, let win else { return }
            MainActor.assumeIsolated {
                // First decoded frame implies the sharer accepted us — clear
                // the "waiting for approval" placard (and the pre-admission
                // title) regardless of resize.
                self.viewerAwaitingApproval = false
                self.isAwaitingAdmission = false
                // Scripted local E2E harness greps for this marker to know
                // the viewer end-to-end pipeline is working. Cheap; only
                // fires once per session.
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
        overlayModel.onOp = { [weak self] op in
            Task { [weak self] in await self?.client?.sendAnnotationOp(op) }
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
        // Hidden until this viewer holds a grant; while active it intercepts
        // pointer/keyboard events and ships them as normalized InputEvents.
        let controlInput = RemoteControlInputView(frame: host.bounds)
        controlInput.onEvent = { [weak self] event in
            Task { [weak self] in await self?.client?.sendInputEvent(event) }
        }
        // The release chord (⌃⌥. unless remapped) while capturing releases
        // control instead of being forwarded to the sharer — the defensive
        // twin of the File-menu item. Seeded here, re-pushed on remap.
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

        // Diagnostics overlay (toggled by the toolbar's chart button).
        // Sits above the annotation layer so its readout doesn't get
        // obscured by mid-stream strokes. Hidden by default; the toolbar
        // / menu flips `model.isVisible` and posts the visibility
        // notification the host view listens for.
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

        // Shortcut cheat-sheet overlay (toggled by toolbar "?" /
        // Help → Keyboard Shortcuts / ⇧⌘/). Added late so it draws
        // above the stats overlay and the annotation canvas,
        // and so its tap-to-dismiss backdrop wins on hit-test.
        let shortcutsHost = ViewerShortcutsOverlayHost()
        host.addSubview(shortcutsHost.view)
        shortcutsHost.layout(in: host)
        self.viewerShortcutsHost = shortcutsHost
        syncShortcutChordDisplays()

        // "Waiting for sharer to accept" placard. Constraint-centered so
        // long translations grow it instead of truncating (the old fixed
        // 360×80 frame clipped anything wider); hidden by default,
        // visibility flipped from `viewerAwaitingApproval`. Added last so
        // HELLO_PENDING during a shortcuts-overlay-up moment still draws
        // above strokes/stats and sits beneath the shortcuts cheat-sheet
        // (acceptable — the cheat-sheet is user-initiated and
        // dismissible).
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

        // Center on the screen the user is working on — the hub window's
        // screen when it's up, else the one holding the mouse — so the
        // first connect doesn't land the viewer on an arbitrary display. A
        // frame restored from a previous run keeps its own position.
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

    /// View → Zoom In / Zoom Out (⌥⌘+ / ⌥⌘-). Steps the continuous
    /// content zoom by a multiplicative `delta`, anchored at the viewport
    /// center — unlike the window-sizing presets above, this magnifies a
    /// region of the received video inside the current window. Pinch and
    /// ⌥-scroll on the viewer do the same anchored at the cursor (see
    /// `AspectFitHostView`).
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

    /// Resize the viewer window so the captured video lands 1:1 on the
    /// user's screen — eliminates upscale fuzziness on small shared
    /// windows and removes the letterbox bars without changing aspect.
    /// Sizes the content view to (video-pixels ÷ backingScale) plus the
    /// toolbar/titlebar inset reported by `contentLayoutRect`, then
    /// clamps to the current screen's `visibleFrame` so the window
    /// never grows off-screen on a tiny display.
    @MainActor
    private static func snapViewerWindow(_ win: NSWindow, toVideoPixelSize px: CGSize) {
        guard px.width > 0, px.height > 0 else { return }
        guard let cv = win.contentView else { return }
        let scale = win.backingScaleFactor > 0 ? win.backingScaleFactor : 2.0

        // Toolbar/titlebar inset = how much taller the contentView is
        // than its usable layout rect. Zero with no toolbar; positive
        // with `.unified` toolbar style.
        let usable = win.contentLayoutRect
        let toolbarInset = max(0, cv.bounds.height - usable.height)

        let desiredVideoPt = NSSize(width: px.width / scale, height: px.height / scale)
        let desiredContent = NSSize(
            width: desiredVideoPt.width,
            height: desiredVideoPt.height + toolbarInset)

        // Clamp to `visibleFrame` so we don't grow under the menu bar or
        // off the right edge. Preserve aspect by picking the smaller
        // scale factor on each axis.
        let screen = win.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.size ?? desiredContent
        let widthScale = min(1.0, visible.width / desiredContent.width)
        let heightScale = min(1.0, visible.height / desiredContent.height)
        let fit = min(widthScale, heightScale)
        let bounded = NSSize(
            width: max(160, desiredContent.width * fit),
            height: max(120, desiredContent.height * fit))

        // No-op when the window is already at the target size — avoids
        // fighting the user's manual resize and dodges thrash during a
        // sharer-side live drag where contentRect updates per frame.
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
        await client?.disconnect()
        client = nil
        micCapture?.stop()
        micCapture = nil
        voiceChannel = nil
        isMicOn = false
        connectionState = .idle
        connectedHostname = nil
        viewerAwaitingApproval = false
        isAwaitingAdmission = false
        viewerSessionEnding = nil
        dismissViewerNotice()
        sharerSupportsRemoteControl = false
        sharerSupportsAnnotations = true
        // End any remote-control session and stop capturing input (also
        // clears the control border + announces to VoiceOver).
        if viewerControlState != .none {
            exitViewerControl()
        }
        viewerRenderer?.clearPendingBuffer()
        // The window survives disconnect (process-lifetime); drop the
        // content zoom so the next session doesn't inherit a magnified
        // view of a screen that's gone.
        viewerHost?.zoomState = ViewerZoomState()
        viewerWindow?.orderOut(nil)
        // Next connect should snap to the new sharer's dims even if the
        // user dragged the previous session's window to a custom size.
        userResizedViewer = false
        // Allow the next session to re-emit the E2E_MARKER on its first frame.
        didLogFirstViewerFrame = false
        refreshViewerWindowTitle()
    }

    /// The session ended without the user asking — sharer stop, timeout,
    /// connection loss, or a deny/kick. `disconnect()`'s teardown half,
    /// minus everything that hides the window or clears the last frame:
    /// the window stays up showing the frozen frame under an explicit
    /// "session ended" pane (reason + Reconnect / Close).
    func endViewerSession(reason: ViewerSessionEnding) async {
        await client?.disconnect()
        client = nil
        micCapture?.stop()
        micCapture = nil
        voiceChannel = nil
        isMicOn = false
        connectionState = .idle
        connectedHostname = nil
        viewerAwaitingApproval = false
        isAwaitingAdmission = false
        sharerSupportsRemoteControl = false
        sharerSupportsAnnotations = true
        if viewerControlState != .none {
            exitViewerControl()
        }
        dismissViewerNotice()
        viewerSessionEnding = reason
        postViewerAccessibilityAnnouncement(sessionEndedPresentation(reason).message)
        // Deliberately NOT: clearPendingBuffer (the last frame is the
        // context for the reason text), orderOut (the whole point), or the
        // zoom / resize-tracking resets — `dismissViewerWindow` owns those.
        didLogFirstViewerFrame = false
    }

    /// Ended-pane Close, ⌘W on the ended state, and the close button
    /// outside `.viewing`: a plain close of the process-lifetime viewer
    /// window (orderOut, never an AppKit close/release).
    func dismissViewerWindow() {
        viewerSessionEnding = nil
        dismissViewerNotice()
        viewerRenderer?.clearPendingBuffer()
        viewerHost?.zoomState = ViewerZoomState()
        viewerWindow?.orderOut(nil)
        userResizedViewer = false
        didLogFirstViewerFrame = false
        refreshViewerWindowTitle()
    }

    /// Redial the current / most recent peer. Serves both the ended pane's
    /// Reconnect button and the stall banner's — from a live (stalled)
    /// session it disconnects first.
    func reconnectViewerSession() {
        guard let peer = lastViewerPeer else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.connectionState == .viewing {
                await self.disconnect()
            }
            await self.connect(to: peer.host, displayName: peer.displayName)
            // A failed redial has already alerted (`connectionFailed`);
            // don't leave a visible window as an unexplained frozen frame
            // behind that alert. The deny path sets its own ending.
            if self.connectionState != .viewing, self.viewerSessionEnding == nil,
                self.viewerWindow?.isVisible == true
            {
                self.viewerSessionEnding = .connectionLost
            }
        }
    }

    /// Map the client's wire-side close reason onto the presentation enum,
    /// through the shared `resolve` all three platforms use.
    ///
    /// `wasAdmitted: true` is not a shrug: `.deniedOrKicked` never rides this
    /// notification on macOS (the deny path goes through `onDeniedBySharer`,
    /// which knows the real admission context and passes it), but the shared
    /// close reason carries the case, and the only state THIS observer accepts
    /// is an already-admitted session — so the already-admitted wording is the
    /// correct defensive answer rather than a guess.
    nonisolated static func sessionEnding(for reason: ViewerCloseReason) -> ViewerSessionEnding {
        ViewerSessionEndReason.resolve(reason, wasAdmitted: true)
    }

    /// Localized title + message for the ended pane (and the VoiceOver
    /// announcement). The deny-flavored wordings reuse the alert copy so
    /// the two surfaces can't tell the same story differently.
    private func sessionEndedPresentation(_ reason: ViewerSessionEnding) -> ViewerSessionEndedModel.EndedState {
        // `lastViewerPeer` is set at every `connect()` entry, so the
        // fallback (same key the hub's session strip uses) is defensive.
        let name = lastViewerPeer?.displayName ?? L("peer")
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
        if viewerSessionEnding != nil {
            win.title = L("Session Ended")
            return
        }
        guard let name = lastViewerPeer?.displayName ?? connectedHostname else {
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
        let name = connectedHostname ?? lastViewerPeer?.displayName
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
    /// deterministic peer list — no tsnet node, no networking — so CI can
    /// screenshot the chrome. Same flag, same fake tailnet as the GTK and
    /// Windows apps' preview modes, so the platforms' screenshots read as
    /// one product.
    static let isUIPreview = CommandLine.arguments.contains("--ui-preview")

    /// The extra preview states, each additive on top of `--ui-preview` and
    /// spelled exactly as the GTK app spells its own (`Apps/linux`'s
    /// `main.swift`), so one screenshot job drives all three platforms with
    /// one vocabulary. Each is an *element* match, so passing only
    /// `--ui-preview-sharing` leaves `isUIPreview` false and seeds nothing —
    /// CI passes the base flag alongside, as the GTK job does.
    static let isUIPreviewRequest = CommandLine.arguments.contains("--ui-preview-request")
    static let isUIPreviewSharing = CommandLine.arguments.contains("--ui-preview-sharing")
    static let isUIPreviewVideo = CommandLine.arguments.contains("--ui-preview-video")

    /// The seeded preview state: tagged and untagged, online and offline,
    /// one peer sharing and one relayed — so a single screenshot exercises
    /// the sharing chip, the route line, the latency figure, and every axis
    /// of the filter menu. Verbatim data, deliberately not localized.
    private func seedUIPreview() {
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

        // The viewer window and the main window both belong to SwiftUI's
        // scene machinery, which has built neither at init time — the video
        // seed needs a window to put a frame into, and the window-id file
        // needs one to name. One settle hop covers both, and CI's own dwell
        // before the shutter dwarfs it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self = self else { return }
            if Self.isUIPreviewVideo { self.seedUIPreviewVideo() }
            self.writeUIPreviewWindowID()
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
    /// same viewer asking for control — the two decision surfaces stacked, so
    /// a single shot carries the roster row, the grant prompt and the
    /// consequence line under it.
    private func seedUIPreviewSharing() {
        sharingState = .active
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
    }

    /// `--ui-preview-video`: the viewer window itself — chrome, drawing
    /// toolbar and overlay over a stand-in frame. `ensureViewer()` builds the
    /// whole graph (window, toolbar, annotation overlay, stats host), so the
    /// seed is: make it, feed it a frame, draw on it, front it.
    private func seedUIPreviewVideo() {
        let renderer = ensureViewer()
        connectionState = .viewing
        connectedHostname = "robert-macbook"
        sharerSupportsAnnotations = true
        refreshViewerWindowTitle()

        if let frame = Self.makeUIPreviewFrame(width: 1920, height: 1080) {
            renderer.setPixelBuffer(
                frame, receiveUptimeNs: DispatchTime.now().uptimeNanoseconds)
        }

        // One stroke per tool so the overlay and every shape's geometry are
        // both in the frame. `.click` is deliberately absent: it is an
        // EPHEMERAL annotation and this canvas is photographed seconds after
        // launch, so unlike the GTK seed — which can date a stroke into the
        // far future because its model takes the clock as an argument — this
        // model sweeps it on a real timer that a screenshot cannot outrun.
        func seed(_ tool: AnnotationTool, _ points: [CGPoint], _ colorIndex: Int) {
            viewerOverlay?.model.apply(
                remoteOp: .add(
                    Annotation(
                        id: UUID(), tool: tool, points: points,
                        color: Annotation.RGBA.palette[colorIndex], width: 4)))
        }
        seed(.pen, [CGPoint(x: 0.08, y: 0.30), CGPoint(x: 0.20, y: 0.55), CGPoint(x: 0.14, y: 0.72)], 0)
        seed(.line, [CGPoint(x: 0.28, y: 0.30), CGPoint(x: 0.40, y: 0.72)], 1)
        seed(.arrow, [CGPoint(x: 0.46, y: 0.72), CGPoint(x: 0.58, y: 0.30)], 2)
        seed(.rectangle, [CGPoint(x: 0.62, y: 0.34), CGPoint(x: 0.76, y: 0.66)], 3)
        seed(.oval, [CGPoint(x: 0.80, y: 0.34), CGPoint(x: 0.94, y: 0.66)], 4)

        viewerWindow?.orderFrontRegardless()
        viewerWindow?.makeKeyAndOrderFront(nil)
    }

    /// A 16:9 gradient stand-in for decoded video, big enough that the
    /// annotation overlay is legible in a screenshot. Same role as the GTK
    /// app's `makePreviewFrame`, in the pixel format the Metal renderer's
    /// BGRA path already takes.
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
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = bytes + y * stride
            let vertical = Double(y) / Double(height)
            for x in 0..<width {
                let horizontal = Double(x) / Double(width)
                let pixel = row + x * 4
                // BGRA, and a dark indigo-to-slate wash so white overlay
                // strokes and the toolbar both read against it.
                pixel[0] = UInt8(60 + 70 * vertical)
                pixel[1] = UInt8(38 + 46 * horizontal)
                pixel[2] = UInt8(46 + 40 * horizontal)
                pixel[3] = 255
            }
        }
        return buffer
    }

    /// Name the window CI should crop its capture to (`screencapture -l`), so
    /// a shot is the app's own window plus its shadow rather than the whole
    /// desktop. Silent no-op without the flag, which is every launch that
    /// isn't the screenshot job.
    ///
    /// An argument rather than an environment variable because the screenshot
    /// job launches the bundle through `open` — which forwards `--args` but
    /// not the caller's environment — and `open` is load-bearing there: it is
    /// what gets the app a real GUI session on the runner.
    private func writeUIPreviewWindowID() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--ui-preview-window-file") else { return }
        let next = args.index(after: flag)
        guard next < args.endIndex else { return }
        let path = args[next]
        guard !path.isEmpty else { return }
        // In video mode the subject is the viewer window; otherwise it is the
        // hub. `canBecomeMain` skips the MenuBarExtra's own backing windows,
        // which are titled panels that would otherwise match first.
        let subject =
            Self.isUIPreviewVideo
            ? viewerWindow
            : NSApp.windows.first {
                $0.isVisible && $0.canBecomeMain && $0.styleMask.contains(.titled)
            }
        guard let subject = subject else { return }
        try? String(subject.windowNumber).write(
            toFile: path, atomically: true, encoding: .utf8)
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
        // popover opens. Creating a fresh TailscalePeerDiscovery per
        // refresh stacked up watchers whose observer loops all kept
        // writing `availablePeers` — each write re-rendered the whole
        // popover, which read as flicker/jumping while it was open. The
        // node is created once per process (see getOrCreateNode), but
        // sign-out tears it down, so rebind if its identity changed.
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

            // Real-time IPN monitoring runs fire-and-forget so it never
            // blocks the user-visible "done" signal. The first attempt
            // usually races tsnet bring-up (this path runs right after
            // node.up(), before LocalAPI is ready), and the start is now
            // watchdog-bounded instead of parking — so retry with backoff
            // until it sticks. Without a live watcher the peer list only
            // refreshes on popover opens, and the always-rendered menubar
            // content goes stale between them.
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
    /// found, or after a short grace period when the answer was empty. A
    /// fresh tsnet node serves `backendStatus` before the control plane
    /// has delivered the netmap, so an empty *first* pass often means
    /// "not synced yet", not "no Tailscreen devices" — surfacing it
    /// immediately flashed the empty state and then animated the real
    /// rows in on top a beat later. The grace keeps the loading skeleton
    /// up long enough for the IPN watcher's first netmap to land; a
    /// genuinely empty tailnet settles to the real empty state after it.
    private func settleInitialDiscoveryAnswer() {
        guard !hasCompletedInitialDiscovery else { return }
        if !availablePeers.isEmpty {
            hasCompletedInitialDiscovery = true
            return
        }
        let discovery = peerDiscovery
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            // Discovery identity check: a sign-out tears the discovery
            // down and resets the flag — a stale timer must not re-set it.
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

    /// Query each online Tailscreen peer's TCP/7447 listener for its
    /// share status (`.metadataRequest` → `.metadataResponse`) and cache
    /// the answers for the sharing-status filter + the peer rows' share
    /// captions. Deliberately lazy — it runs off `discoverPeers()` (menu
    /// open / manual refresh) and when the "only sharing" filter turns on,
    /// so a large tailnet pays N short-lived dials only while the user is
    /// actually looking. Answers land incrementally as each dial resolves;
    /// a peer that gives no answer (offline, legacy build, timeout) has
    /// its entry removed so the filter treats it as unknown, never stale.
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

    /// Single-peer variant of `refreshPeerShareStatus`, fired when the main
    /// window's peer-detail pane expands so its share info reflects *now*
    /// rather than whenever the last full sweep ran. Same rule as the
    /// sweep: no answer removes the entry, so the pane can never show a
    /// stale "sharing" state.
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
    /// suppressed and check whether the on-disk state already authenticates
    /// us. If yes, the menu flips to its signed-in form without the user
    /// ever clicking. If no (stale or empty state), the suppressed
    /// BrowseToURL is dropped silently and the user still sees the
    /// "Sign in with Tailscale" CTA.
    private func attemptSessionRestore() async {
        // Skip when the active profile's state directory is empty — the
        // very first launch (or a just-added profile) has nothing to
        // restore, and bringing the node up would just emit a BrowseToURL
        // we're going to drop anyway.
        let statePath = profileStore.activeProfile.statePath(
            appSupport: Self.appSupportDirectory(),
            instanceSuffix: TailscreenInstance.stateSuffix)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: statePath)) ?? []
        guard !contents.isEmpty else {
            logger.log("No saved Tailscale state at \(statePath); skipping silent restore")
            return
        }

        // `interactiveLoginRequested` defaults to false, so any BrowseToURL
        // emitted during this `up()` is dropped by the watcher. If the
        // state is valid, `up()` returns quickly without ever emitting
        // one; if it's stale, `up()` will block in the background — that's
        // fine, it just sits there until the user clicks Sign In.
        do {
            let node = try await getOrCreateNode()
            await tailscaleAuth.checkAuthStatus(node: node)
            if tailscaleAuth.isAuthenticated {
                let ips = try await node.addrs()
                self.tailscaleIPs = [ips.ip4, ips.ip6].compactMap { $0 }
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
        // Allow the IPN BrowseToURL handler to actually open a browser
        // tab — we're here because the user explicitly asked to sign in.
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

            // Fetch IPs after successful login
            let ips = try await node.addrs()
            self.tailscaleIPs = [ips.ip4, ips.ip6].compactMap { $0 }

            // Label the active profile with the identity that just signed
            // in, so the account menu can name it while it's inactive.
            noteProfileIdentityFromAuth()

            // Login success is visible via the menu's user profile section;
            // a popup just interrupts the flow the user was already in.
            _ = silent
        } catch {
            logger.log("Login error: \(error)")
            presentError(.loginFailed(error))
        }
    }

    private func getOrCreateNode() async throws -> TailscaleNode {
        // If the node exists AND is running, return it. "Running" is read
        // from the backend itself (LocalAPI `backendStatus`), not assumed
        // from existence — a node whose `up()` threw after the assignment
        // below, or whose backend died since (key expiry, engine stop),
        // used to be handed back here as a permanently dead node.
        if let node = self.node {
            switch nodeBringUpState {
            case .upInFlight:
                // A concurrent caller while `up()` is still blocking —
                // typically the interactive browser login. Hand back the
                // same node rather than racing a second bring-up; a status
                // read here would report NeedsLogin and wrongly tear down
                // the node mid-login.
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

        // Subscribe to the IPN bus *before* calling `up()`. tsnet's
        // `tailscale_up` blocks until the backend reaches Running, which on
        // a fresh device means waiting for the user to complete an
        // interactive browser login. tsnet signals that login URL by
        // emitting a BrowseToURL notify on the IPN bus — if nothing's
        // listening when it fires, `up()` waits forever and the user
        // never sees the link. Subscribing first guarantees we catch it.
        if authIPNWatcher == nil {
            authIPNWatcher = await startBrowseURLWatcher(node: node)
        }

        // Bring the node up so discovery probes can actually route. Without
        // this the node's LocalAPI works (so login + status queries succeed),
        // but tailscale_dial fails silently — every peer probe returns false
        // and "Browse Shares" always lists zero.
        //
        // tsnet's up() has no internal timeout. With an auth key there's no
        // human in the loop, so it should reach Running in seconds — a hang
        // there means a bad key or an unreachable control plane, and we bound
        // it so the caller surfaces an error instead of parking forever. The
        // interactive path (no key) is intentionally left unbounded: up()
        // legitimately blocks until the user finishes the browser login, which
        // can take minutes.
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

        // Bind the shared TCP/7447 control listener once the node is up.
        // Idempotent (`start` no-ops on repeat); it has to live across
        // share start/stop so request-to-share messages reach us even
        // when we're not currently sharing.
        try await ensureControlListener(node: node)

        return node
    }

    /// Start (and keep) the long-lived TCP/7447 control listener bound to
    /// the local tsnet node — the shared coordinator's lifecycle, with the
    /// arrival, notification and answer routing wired in `init`. Awaited so
    /// a bind failure still fails node bring-up, exactly as before.
    private func ensureControlListener(node: TailscaleNode) async throws {
        guard try await askToShare.ensureListenerStarted(node: node) else { return }
        logger.log("Control listener bound on TCP/\(NetworkConfig.tailscreenPort)")
    }

    /// Post and withdraw request-to-share notices to match the live banner
    /// rows — the fourth call site onto the one shared decision.
    ///
    /// Identity is `PendingShareRequest.sourceKey`, which is exactly the key
    /// the coordinator's inbox already coalesces the banner list on: the
    /// requester's source IP, never the wire-claimed hostname an attacker can
    /// vary at will. Keying the notices the same way means a peer retrying
    /// while its first ask is still on screen replaces one row and mints no
    /// second banner, and the forget-on-leave prune re-announces a genuinely
    /// fresh ask after the last one was answered.
    ///
    /// Called from the coordinator's `onRequestsChanged` — on arrival and on
    /// answer, because both edit the list, and the notice for a request
    /// answered in the app has to come down with it.
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

    /// Answer an incoming request-to-share banner — the coordinator's
    /// sequencing: the accept/decline response rides the TCP connection the
    /// request arrived on (best-effort — the requester may have timed out and
    /// closed it), the row and its notice come down via `onRequestsChanged`,
    /// and on accept the pre-approval and the picker flow land in the
    /// closures `init` wired.
    func respondToShareRequest(_ request: PendingShareRequest, accepted: Bool) {
        askToShare.answer(id: request.id, accept: accepted)
    }

    /// Spin up an IPN-bus watcher whose only job is to open the
    /// browser-login URL tsnet emits during interactive sign-in. Returns
    /// the running watcher so the caller can keep it alive for the lifetime
    /// of the node it's tied to.
    private func startBrowseURLWatcher(node: TailscaleNode) async -> TailscaleIPNWatcher? {
        let watcher = TailscaleIPNWatcher()
        watcher.onBrowseToURL = { [weak self] url in
            // Hop to the main actor — NSWorkspace must be touched there,
            // and the IPN consumer fires from a background actor.
            Task { @MainActor in
                guard let self else { return }
                guard self.interactiveLoginRequested else {
                    // Silent restore in progress: dropping the BrowseToURL
                    // keeps a stale-state launch from popping a sign-in
                    // tab the user never asked for. The user clicking
                    // "Sign in with Tailscale" flips the flag and the
                    // next emitted URL gets opened.
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
            if sharingState == .active {
                await stopSharing(reason: "signOut")
            }

            // Disconnect if connected
            if connectionState == .viewing {
                await disconnect()
            }

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
            tailscaleIPs = []

        } catch {
            presentError(.signOutFailed(error))
        }
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

    /// Tear down the live node and everything hanging off it WITHOUT
    /// logging out — the profile's on-disk tsnet state stays valid, so
    /// switching back later restores the session silently. This is
    /// `signOut()`'s teardown half minus `tailscaleAuth.signOut()`.
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
        tailscaleIPs = []
        tailscaleAuth.isAuthenticated = false
        tailscaleAuth.userProfile = nil
    }

    /// True while a session is active enough that yanking the node out
    /// from under it on a menu click would be worse than asking the user
    /// to finish first.
    private var isBusyForProfileSwitch: Bool {
        !Self.canSwitchProfile(sharing: sharingState, connection: connectionState)
    }

    /// Pure gate: switching accounts closes the tsnet node, so it's only
    /// allowed while nothing is riding it — no share (including one still
    /// starting) and no viewer session (including one still connecting).
    /// Extracted so the precedence is pinned by tests rather than inferred
    /// from the two call sites. See `switchProfile` / `addAccountAndSignIn`.
    nonisolated static func canSwitchProfile(
        sharing: SharingState, connection: ConnectionState
    ) -> Bool {
        sharing == .idle && connection == .idle
    }

    /// Switch the active account profile, Tailscale-style: one node at a
    /// time, other profiles stay logged in on disk. Refuses mid-session;
    /// otherwise closes the current node locally and brings the selected
    /// profile up — silently when its saved state still authenticates,
    /// else the window falls back to the sign-in pane.
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
        await teardownNodeKeepingLogin()
        profileStore.setActive(profile.id)
        await login(silent: false)
    }

    /// Confirm and remove a non-active profile, deleting its on-disk node
    /// state. Removal is local: the machine may remain listed in that
    /// tailnet's admin console until it expires. Only directories under
    /// `profiles/` are ever deleted — never the legacy shared root.
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

    /// Open (or re-focus) the preferences window. A real titled `NSWindow`
    /// hosting `SettingsView`, kept around for the process lifetime.
    /// Resizable above a floor rather than the old fixed 440×600 — the
    /// grouped Form scrolls either way, but the Accounts and Keyboard
    /// Shortcuts rows earn their width, and a fixed frame fights large
    /// system text sizes. `SettingsView` declares the same minimum via
    /// `.frame(minWidth:minHeight:)`; `contentMinSize` is the AppKit-side
    /// belt to those SwiftUI braces.
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
        // The OS owns the login-item truth (the user can flip it in System
        // Settings behind our back) — re-read it on every open/refocus so
        // the General toggle never lies.
        refreshLaunchAtLoginStatus()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Launch at login

    /// Whether this process can register a login item at all: `SMAppService`
    /// registers the *bundle*, so a dev build running as a bare executable
    /// (`make run`, `swift run`) has nothing registrable — `register()`
    /// would just throw on every flip. The Settings toggle disables itself
    /// with an explanatory caption instead.
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

    /// Register / unregister the app as a login item. Errors surface via
    /// the standard alert path, and the published state is re-read from
    /// `SMAppService` afterwards either way — reflecting what the OS
    /// actually did, not what we asked for.
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

    /// Open (or re-focus) the docked main window. Routes through the
    /// SwiftUI `openWindow` action stashed in `openMainWindowAction` so the
    /// `Window` scene owns the NSWindow; the identifier-prefix fallback
    /// covers the theoretical gap where no SwiftUI view has appeared yet
    /// but the scene's window already exists.
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

    /// Raise the persistent viewer window — the "Show Window" action on
    /// the hub's and the popover's viewing cards. Re-fronts only, same
    /// ordering as the connect path: the window is built by connect and
    /// is nil until a first session, in which case there's nothing to
    /// show — never create one here.
    func focusViewerWindow() {
        guard let viewerWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        viewerWindow.orderFrontRegardless()
        viewerWindow.makeKeyAndOrderFront(nil)
    }

    /// Surface an error to the user as an `NSAlert`. Using AppKit
    /// directly (rather than a SwiftUI `.alert` modifier on the
    /// menubar view) is required because `MenuBarExtra(.window)`
    /// dismisses its popover on any click outside the popover bounds
    /// — including the alert's own buttons — so SwiftUI button
    /// handlers never run before the popover tears down. An
    /// `NSAlert` runs in its own modal panel, independent of the
    /// popover lifecycle. "Copy Details" re-presents the alert so
    /// the user can read it again after copying.
    func presentError(_ error: AppError) {
        logger.log("AppError[\(error.code)] \(error.title) — \(error.message)")

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

    /// Legacy free-form alert. Existing call sites use this — wraps
    /// strings in `AppError.legacy(...)` so the richer surface still
    /// gets a code + Copy Details, even when the call site doesn't
    /// supply one.
    private func showAlertMessage(title: String, message: String) {
        presentError(.legacy(title: title, message: message))
    }

    /// A soft, non-error informational notice — a plain `.informational`
    /// `NSAlert` with a single OK button and no error code / Copy Details.
    /// For *expected* events (e.g. the shared window was closed) that end the
    /// share but aren't failures, so the scary `presentError` surface is wrong.
    /// Runs its own modal panel for the same `MenuBarExtra` popover reason
    /// documented on `presentError`.
    func presentNotice(title: String, message: String) {
        logger.log("Notice: \(title) — \(message)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    // MARK: - Sharer notices

    /// Whether a capture is running — the sound gate for every notice we post.
    /// See `SharerNoticeDecision.playsSound`: a ding during a share is played
    /// by the notification daemon, which the "exclude our own audio" flag does
    /// not cover, so every viewer hears it.
    private var isCapturing: Bool { sharingState != .idle }

    /// Deliver a batch of notices. The single place `SharerNoticeCenter` is
    /// touched from the notice paths, so the sound gate can't be forgotten at
    /// one of them.
    private func post(_ notices: [SharerNotice]) {
        for notice in notices {
            SharerNoticeCenter.shared.post(notice, isCapturing: isCapturing)
        }
    }

    /// Project the connected-viewer roster onto notice candidates.
    ///
    /// Keyed by the server's `"ip:port"` id, so a viewer who drops and rejoins
    /// on a fresh ephemeral port is announced again — an arrival is news each
    /// time it happens. That is the **opposite** choice from the control-request
    /// projection below, and the reason `SharerNoticeDecision` takes an opaque
    /// string instead of picking a key for its callers.
    nonisolated static func noticeCandidates(_ viewers: [ViewerInfo]) -> [NoticeCandidate] {
        viewers.map { NoticeCandidate(identity: $0.id, label: $0.displayName) }
    }

    /// Project the approval gate onto notice candidates — same `"ip:port"` key
    /// and same reasoning as the roster.
    nonisolated static func noticeCandidates(_ pending: [PendingViewerInfo]) -> [NoticeCandidate] {
        pending.map { NoticeCandidate(identity: $0.id, label: $0.displayName) }
    }

    /// Project live control requests onto notice candidates.
    ///
    /// Keyed by viewer **IP**, not by the TCP `connectionID` the grant itself
    /// uses. Every reconnect mints a fresh connection UUID, so a connection-keyed
    /// notice is a spam vector: drop, redial, and the sharer gets another banner
    /// for a request they are already looking at. The IP is the same
    /// non-spoofable anchor the admission gate trusts, and it collapses parallel
    /// connections from one machine into one ask.
    nonisolated static func noticeCandidates(_ requests: [ControlRequestInfo]) -> [NoticeCandidate] {
        requests.map { NoticeCandidate(identity: $0.viewerIP, label: $0.displayName) }
    }

    /// Diff the new viewer roster to fire a per-join and per-leave
    /// notification exactly once per `id`. Notifications are best-effort: dev
    /// builds without a bundle ID won't be authorized by macOS to display
    /// banners, but the in-app roster still works.
    private func handleViewersChanged(_ viewers: [ViewerInfo]) {
        let newIDs = Set(viewers.map { $0.id })
        // Departures are the one thing `noticesToPost` cannot derive, because
        // it only ever posts about rows it can see and a viewer who left is by
        // definition absent from `viewers`. So they are read from the OUTGOING
        // roster, behind the two gates that keep them news rather than noise:
        // only viewers whose *arrival* was announced get a departure — a "left"
        // with no matching "joined" is a non-sequitur — and nothing is posted
        // while the share is being torn down, since `await server?.stop()`
        // expels every viewer at once and would otherwise fire one banner per
        // viewer at the exact moment the sharer already decided to stop.
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
        // Both rosters, coalesced to the end of the turn — see
        // `scheduleNoteRoster()`. The roster is re-emitted whenever anything
        // about it changes, including a StableNodeID resolving, which is
        // precisely the event a queued Deny & Block is waiting for; noting it
        // here rather than only on join/leave is what makes the queue drain.
        scheduleNoteRoster()
        // The shared decision does both halves: it prunes IDs that have left
        // (so a reconnect from the same address is announced again) and posts
        // only the arrivals not already announced.
        let decision = SharerNoticeDecision.noticesToPost(
            kind: .viewerJoined,
            candidates: Self.noticeCandidates(viewers),
            alreadyNotified: notifiedViewerIDs)
        notifiedViewerIDs = decision.notified
        post(departed)
        post(decision.post)
    }

    /// Sync the published pending list and fire a "wants to view"
    /// notification for newly-arrived pending viewers. Fires regardless
    /// of whether the menu popover is open — that's the whole point of
    /// the approval gate.
    private func handlePendingViewersChanged(_ pending: [PendingViewerInfo]) {
        pendingViewers = pending
        scheduleNoteRoster()
        let candidates = Self.noticeCandidates(pending)
        let answered = SharerNoticeDecision.noticesToWithdraw(
            candidates: candidates, alreadyNotified: notifiedPendingViewerIDs)
        let decision = SharerNoticeDecision.noticesToPost(
            kind: .viewerPending, candidates: candidates,
            alreadyNotified: notifiedPendingViewerIDs)
        notifiedPendingViewerIDs = decision.notified
        // Whoever left the gate — accepted here, denied here, or gave up —
        // takes their banner with them. An Accept/Deny left in Notification
        // Center for somebody already watching can only be pressed to no
        // effect, which reads as a broken button rather than a stale one.
        SharerNoticeCenter.shared.withdraw(kind: .viewerPending, identities: Array(answered))
        post(decision.post)
    }

    // MARK: - Remote control (sharer side)

    /// Sync the published control-request list and fire a "wants control"
    /// notification for newly-arrived requests, whether or not the popover is
    /// open — control is high-stakes, so the prompt shouldn't be missable.
    ///
    /// One notification per viewer **IP** per *pending episode*, and the whole
    /// rule now comes from `SharerNoticeDecision` — this path used to carry its
    /// own copy of it. The residual reconnect-loop exposure (drop connection,
    /// re-request, repeat) is accepted; the hard stop for that is the "Allow
    /// control requests" toggle. The pending row in the app still shows every
    /// live request; only the notification is deduped.
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

    /// The control request the sharer explicitly clicked Grant on while the
    /// app lacked the Accessibility permission. In-memory only — deliberately
    /// never persisted, so a relaunch can't resurrect a stale intent — and
    /// only ever set from an explicit Grant press (`grantRemoteControl`).
    /// While set, the request's row in `ControlRequestsList` shows a
    /// "Waiting for Accessibility permission…" caption and
    /// `accessibilityGrantRecheckTimer` watches for the permission landing.
    @Published private(set) var pendingAccessibilityGrantRequestID: UUID?

    /// 1 s poll scoped to a queued grant intent: started when the intent is
    /// set, invalidated the moment it clears. A poll rather than an
    /// app-activation observer because a TCC toggle takes effect with no
    /// edge this process can observe — the sharer flips the switch in
    /// System Settings and may interact only with the menubar popover
    /// afterwards, never re-activating the app. Same polling shape as
    /// `shareLockProbeTimer`, but intent-scoped like `revokeControlHotkey`
    /// so idle sessions never tick it.
    private var accessibilityGrantRecheckTimer: Timer?

    /// Grant remote control to the requesting viewer on `connectionID`. If
    /// the app lacks the Accessibility TCC grant the server refuses (and
    /// fires `onControlAccessibilityRequired` → alert + settings deep-link)
    /// — but the click is remembered as an intent for this specific
    /// request, and the moment the permission lands while the request is
    /// still pending the grant completes automatically, so the sharer
    /// doesn't have to notice the still-pending row and click Grant a
    /// second time after the trip to System Settings.
    func grantRemoteControl(_ connectionID: UUID) {
        // The newest explicit click wins: a grant aimed at one request
        // supersedes an intent queued for another — control goes to exactly
        // one viewer, and it must be the one the sharer chose last.
        if pendingAccessibilityGrantRequestID != connectionID {
            clearAccessibilityGrantIntent()
        }
        guard server?.grantControl(toConnectionID: connectionID) == true else {
            // Refused. The only refusal a later re-click could cure is the
            // missing Accessibility permission — queue the intent for
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

    /// Register / unregister the panic-revoke hotkey (⌃⌥. by default,
    /// remappable via `revokeHotkeyChord`) to track the live grant.
    /// Registration is cheap (Carbon), and scoping it to the grant
    /// means Tailscreen only claims the system-wide chord while a viewer can
    /// actually control this Mac. Keeps `id: 2` — the mic hotkey (`id: 1`)
    /// may be live at the same time, and `GlobalHotkey.handlerShouldFire`'s
    /// id filter is what keeps the two from swallowing each other's events.
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
            // The real registration is the authoritative availability
            // answer — it supersedes whatever the last probe reported.
            revokeHotkeyRegistered = revokeControlHotkey?.isRegistered ?? false
        } else {
            revokeControlHotkey = nil  // deinit unregisters
        }
    }

    /// Alert + deep-link when a grant is refused for want of Accessibility
    /// permission. Mirrors the Screen Recording settings deep-link. The
    /// refused grant is queued by `grantRemoteControl`, so the copy promises
    /// auto-completion rather than asking for a second click.
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

    /// Viewer leaves control mode (stops capturing + emitting input) and tells
    /// the sharer to release the grant via `.controlReleased`, so the sharer's
    /// banner + gate clear in step rather than leaving a zombie grant. Covers
    /// both the `.requested` (cancel a pending request) and `.controlling`
    /// states.
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

    /// Act on a notification button press, decoded by
    /// `TailscreenNotificationDelegate.route`.
    ///
    /// **Every case resolves the identity against the live list first.** A
    /// banner outlives the thing it is about — it sits in Notification Center
    /// until dismissed, which can be an hour after the viewer gave up — so "the
    /// row is gone" is the ordinary case here, not an error, and it has to be a
    /// no-op. The alternative is an Accept aimed at whoever holds that address
    /// now, which behind one NAT is a different machine; this is the same
    /// reasoning that makes `SharerAccessCoordinator` prune its queued intents.
    ///
    /// The press is deliberately routed into the *same* methods the in-app
    /// buttons call rather than to the server directly, so a decision made from
    /// a banner and one made in the window cannot diverge — including the
    /// pre-approval and policy-persistence side effects hanging off them.
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
        case .viewerJoined, .viewerLeft:
            // Reports, not asks — `SharerNoticeKind.actions` gives them no
            // buttons, so there is nothing that could have been pressed.
            break
        }
    }

    /// The control-request half, which is the one that doesn't map 1:1.
    ///
    /// The notice is keyed by viewer IP (see `noticeCandidates`) but a grant is
    /// keyed by the TCP connection, so the press has to find the live request
    /// or requests behind that address. Denying applies to all of them — the
    /// banner named a machine, not a socket, and leaving a sibling request
    /// pending after the sharer said no is not what they answered. Granting
    /// does not: control of the Mac goes to exactly one connection, and picking
    /// one of two arbitrarily is a coin flip over who gets the pointer. That
    /// case opens the list instead, where the rows are distinguishable.
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

    /// The banner body was clicked rather than one of its buttons.
    ///
    /// That is not an answer, so nothing is decided on the sharer's behalf —
    /// it opens the surface carrying the decision and lets them look at it.
    /// The hub window is always the right destination: every prompt that
    /// decides something about a person renders there as well as in the
    /// popover, and unlike the popover it can be opened programmatically.
    func presentNoticeSurface(kind: SharerNoticeKind) {
        logger.log("Notification body clicked (\(kind.rawValue)) — opening the hub")
        presentMainWindow()
    }

    /// Admit a pending viewer — hands off to the live server which
    /// emits the deferred HELLO_ACK and forces a keyframe.
    func approvePendingViewer(_ id: String) {
        server?.approveViewer(addr: id)
    }

    /// Reject a pending viewer — server sends HELLO_DENY + SERVER_BYE so
    /// the viewer tears their session down immediately.
    func denyPendingViewer(_ id: String) {
        server?.denyViewer(addr: id)
    }

    /// One-time disconnect of a *connected* viewer — the ✕ button on the
    /// SharingCard's viewer row. Nothing is remembered: the peer can
    /// reconnect and goes back through the normal admission gate. For the
    /// persistent variant, use "Deny & Block" on the pending row (or
    /// remove/deny via Settings → Viewers).
    func disconnectConnectedViewer(_ id: String) {
        server?.disconnectViewer(addr: id)
    }

    /// "Always Allow": remember the peer as allowed (so future HELLOs skip
    /// the prompt), then admit them now. If the StableNodeID hasn't resolved
    /// yet, queue the intent so it's persisted the instant resolution lands
    /// — the peer is admitted one-time in the meantime.
    func approvePendingViewerAlways(_ id: String) {
        if !persistPendingViewerPolicy(id, policy: .allow) {
            policyIntents.queue(id: id, policy: .allow)
            logger.log("Queued 'always allow' for \(id): StableNodeID unresolved — persist on resolve")
        }
        server?.approveViewer(addr: id)
    }

    /// "Deny & Block": remember the peer as denied (future HELLOs are
    /// silently rejected), then deny them now. If the StableNodeID hasn't
    /// resolved yet, queue the intent and leave the peer parked (denied
    /// access, no video) so the server keeps resolving its StableNodeID —
    /// the block is persisted the instant resolution lands, rather than
    /// silently degrading to a one-time deny the peer could re-HELLO past.
    func denyPendingViewerAndBlock(_ id: String) {
        if persistPendingViewerPolicy(id, policy: .deny) {
            server?.denyViewer(addr: id)
        } else {
            policyIntents.queue(id: id, policy: .deny)
            logger.log("Queued 'deny & block' for \(id): StableNodeID unresolved — parked until resolve")
        }
    }

    /// Keep the remembered-viewers list readable across machine renames:
    /// whenever a roster snapshot carries a resolved hostname for a peer
    /// we've remembered, refresh its cosmetic display name. No-ops (no
    /// persist, no publish) when nothing changed.
    private func refreshRememberedDisplayNames(stableIDHostnamePairs: [(String?, String?)]) {
        for (stableID, hostname) in stableIDHostnamePairs {
            guard let stableID, let hostname else { continue }
            viewerAccessPolicies.refreshDisplayName(
                stableID: stableID,
                displayName: TailscreenInstance.displayName(fromHostname: hostname))
        }
    }

    /// Both rosters as the shared queue's identity rows: the connected ones
    /// first, then the ones parked at the gate.
    ///
    /// **Both, never one at a time.** A peer moves between the lists on Accept,
    /// and a snapshot of only one would prune the other's queued intents as
    /// "gone" at exactly that moment — the rule `.claude/rules/protocol.md`'s
    /// Deny & Block pitfall spells out, and the shape `LinuxShareSession` and
    /// `WindowsShareSession` already use.
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

    /// Queue a roster note for the end of the current main-actor turn, at most
    /// one per turn.
    ///
    /// The one place this host cannot copy the other two verbatim. `Accept`
    /// makes the server fire `onPendingViewersChanged` (row removed) and then
    /// `onViewersChanged` (row added), and both arrive here through their own
    /// `Task { @MainActor }` hop — so for one turn the row is in NEITHER
    /// published list, and a note taken right then would prune the very intent
    /// the Accept just queued. macOS is the host where that matters, because
    /// macOS is the one that puts Always Allow / Deny & Block on the PENDING
    /// rows; the GTK and WinUI hubs offer them on connected rows only, where
    /// nothing moves. Coalescing to the end of the turn lets both callbacks
    /// land first, so the note sees a settled pair of lists.
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
    ///
    /// Persisting fires the remembered-store subscription, which pushes the
    /// policy to the live server (admitting/expelling as needed).
    private func noteRoster() {
        let rows = rosterIdentities()
        for applied in policyIntents.drain(snapshot: rows) {
            viewerAccessPolicies.upsert(
                stableID: applied.stableID, displayName: applied.displayName,
                policy: applied.policy)
            logger.log(
                "Applied queued \(applied.policy) intent for \(applied.id) → \(applied.stableID)")
        }
        // Fed the raw HOSTNAMES rather than `RosterIdentity.displayName`,
        // whose `hostname ?? tailscaleIP` fallback would rewrite a remembered
        // peer's name to a bare IP for as long as its netmap lookup is
        // outstanding — the exact thing this refresh exists to undo.
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

    /// Vibrancy-backed centered placard shown between HELLO_PENDING and
    /// the first decoded frame: spinner + "Waiting for the sharer…" +
    /// Cancel. Constraint-sized (the caller centers it and caps its
    /// width), so long translations grow it instead of truncating. Held by
    /// AppState and toggled via `viewerWaitingPlacard?.isHidden` from
    /// `viewerAwaitingApproval.didSet`.
    @MainActor
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

        let waitingText = L("Waiting for the sharer to accept your connection…")
        let label = NSTextField(wrappingLabelWithString: waitingText)
        label.alignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 320

        // Cancel = the same full disconnect ⌘W performs — without it the
        // only exits from an unanswered approval gate were the close
        // button and the menu bar.
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

/// Persistence for the Settings → Color capture opt-ins. Mirrors
/// `ViewerApprovalPreference` — plain `UserDefaults` so `AppState.init`'s
/// stored-property initialisers can read the saved value without
/// `@AppStorage`. Tri-state on purpose: a never-touched install (no stored
/// object) seeds from the pre-Settings env-var escape hatches
/// (`TAILSCREEN_ENABLE_10BIT=1` / `TAILSCREEN_ENABLE_HDR=1`) so an existing
/// scripted setup keeps its behavior; once the user flips a toggle the
/// stored choice wins, in either direction.
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

/// Invisible view whose only job is to represent the video surface to
/// accessibility: decoded frames render into a `CAMetalLayer`, which is
/// not a view and therefore invisible to VoiceOver — without this the
/// viewer window reads as empty. Framed to the aspect-fit rect by
/// `AspectFitHostView.layout`; never participates in hit-testing, so
/// every click still lands on the annotation canvas above it.
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

/// AppState's own log channel. Mirrors the per-file TSLogger pattern
/// used by the screen-share + tsnet wrappers so every `[AppState]` line
/// flows through a single sink we can later redirect or filter.
private struct AppLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[AppState] \(message)")
    }
}

/// NSWindowDelegate stand-in for the persistent viewer window. Returns
/// `false` from `windowShouldClose` so AppKit never proceeds with the
/// NSWindow.close() release cascade that crashed in earlier bisects;
/// instead it routes the close button to AppState.disconnect, which
/// orderOuts the window without releasing it.
private final class ViewerWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    /// Fired on every `windowDidResize`. AppState distinguishes user vs
    /// programmatic resizes via a suppress flag set around its own
    /// `setContentSize` calls — the delegate itself is dumb on purpose.
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

    /// While this viewer holds a remote-control grant, draw a highly
    /// visible orange outline around the video content rect. The toolbar
    /// item, window title and VoiceOver announcement carry the same state,
    /// so the color is never the only signal.
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
            // A sharer-side resolution change invalidates the content
            // zoom's pan space — reset to fit rather than keep magnifying
            // a stale region of the old frame.
            zoomState = ViewerZoomState()
            needsLayout = true
        }
    }

    /// Continuous content zoom/pan applied on top of the aspect-fit rect.
    /// All geometry lives in `ViewerZoomMath`; this view only feeds it
    /// gesture deltas and lays out both the metal layer and the annotation
    /// overlay from the single rect it returns — keeping the two congruent
    /// is the invariant that keeps strokes pixel-correct at any zoom.
    var zoomState = ViewerZoomState() {
        didSet {
            guard zoomState != oldValue else { return }
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let rect = ViewerZoomMath.videoRect(fit: aspectFitRect(), state: zoomState)
        // CALayer frame changes go through an implicit animation by
        // default — disable it so the layer snaps to the new aspect rect
        // in lockstep with the overlay subview (and so pinch-zoom doesn't
        // rubber-band through implicit animations).
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

    /// The texture-safe zoom ceiling for the given fit rect: keeps the
    /// zoomed rect (which frames the layer-backed annotation overlay)
    /// under Core Animation's per-axis texture limit at this window's
    /// backing scale.
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
            // Normalize so scrolling up (device-up) always zooms in,
            // regardless of the natural-scrolling preference — zoom has
            // no "content to drag", so direction shouldn't flip with it.
            // ~100 points of scroll doubles (or halves) the zoom.
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
            // scrollingDelta is expressed for a flipped (y-down)
            // coordinate space; this view is non-flipped, so negate Y to
            // keep the content tracking the fingers. Unlike the ⌥-zoom
            // above, panning deliberately follows the natural-scrolling
            // preference — it *is* dragging content.
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
        // NSView's autoresize machinery would otherwise stretch the
        // overlay to fill bounds; we manage the frame ourselves.
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Toolbar height changes (e.g. style toggle, full-screen enter /
        // exit) move `contentLayoutRect` without resizing the view, so
        // bounds-driven layout misses them. Reflect the change here.
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
    /// With `.unified` toolbar style, contentView spans the full window
    /// height (the toolbar floats above it), so a bounds-based aspect-fit
    /// would place equal letterboxes top and bottom, the top one hiding
    /// behind the opaque toolbar and the bottom one showing as a stray
    /// black strip. `contentLayoutRect` is the toolbar-excluded subregion
    /// — aspect-fitting within that keeps the video centered in the area
    /// the user actually sees.
    private func usableRect() -> CGRect {
        guard let window = self.window else { return bounds }
        let rect = window.contentLayoutRect
        return rect.isEmpty ? bounds : rect.intersection(bounds)
    }

    /// The shared `ViewerPointerMapping.fitRect` does the letterboxing (the
    /// same arithmetic the GTK and WinUI viewers use, and the same rect the
    /// pointer mapping normalizes against); this only supplies the
    /// toolbar-excluded pane and re-bases the result onto its origin.
    /// `videoSize` holds whole pixel counts (it is set from the decoded
    /// buffer's integer dimensions), so the `Int` conversion is exact.
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
