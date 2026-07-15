import AppKit
import Carbon.HIToolbox
import Combine
import CoreAudio
import CoreGraphics
import Foundation
import Observation
import QuartzCore
import ScreenCaptureKit
import SwiftUI
import TailscaleKit

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

@MainActor
class AppState: ObservableObject {
    @Published var sharingState: SharingState = .idle
    @Published var connectionState: ConnectionState = .idle
    @Published var connectedHostname: String?
    @Published var statusMessage = ""
    /// Whether the sharer's drawing overlay panel is currently visible and
    /// accepting input. The panel itself is only created while sharing.
    @Published var isSharerOverlayVisible = false
    @Published var isMicOn = false

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

    /// User preference: park new viewers in a pending state and require
    /// explicit Accept/Deny before they see video. Persisted to
    /// UserDefaults under `requireViewerApproval`. Defaults off so the
    /// out-of-box experience matches the existing open-door behavior.
    /// SwiftUI views bind to this via `appState.requireViewerApproval`;
    /// the setter syncs the live server too so the toggle takes effect
    /// mid-share.
    @Published var requireViewerApproval: Bool = ViewerApprovalDefaults.load() {
        didSet {
            ViewerApprovalDefaults.save(requireViewerApproval)
            server?.setRequireApproval(requireViewerApproval)
        }
    }

    /// Viewer IDs we've already fired a "joined" notification for this
    /// session. Keyed by the server's internal `"ip:port"` ID so a viewer
    /// who briefly drops and rejoins (different ephemeral port) gets a
    /// fresh ping, but hostname-resolution updates to the same viewer
    /// don't double-fire. Cleared on `stopSharing`.
    private var notifiedViewerIDs: Set<String> = []

    private var server: TailscaleScreenShareServer?
    private var client: TailscaleScreenShareClient?
    private var node: TailscaleNode?
    private var tailscaleIPs: [String] = []
    /// Long-lived TCP/7447 listener that demultiplexes the framed control
    /// protocol. Bound once after `node.up()` and kept alive across share
    /// start/stop cycles so peer-initiated request-to-share messages
    /// arrive whether or not we're sharing. Torn down on sign-out.
    private var controlListener: TailscreenControlListener?
    private var sharerOverlay: SharerOverlayWindow?
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
    private var viewerRenderer: MetalViewerRenderer?
    private var viewerOverlay: AnnotationOverlayHostView?
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

    /// True between the sharer reporting HELLO_PENDING and the viewer
    /// receiving its first decoded frame. Drives the placard overlaid on
    /// the viewer window. Reset on connect/disconnect.
    @Published var viewerAwaitingApproval: Bool = false {
        didSet {
            guard viewerAwaitingApproval != oldValue else { return }
            viewerWaitingPlacard?.isHidden = !viewerAwaitingApproval
        }
    }

    // Peer discovery
    @Published var availablePeers: [TailscreenPeer] = []
    @Published var isDiscovering = false
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

        // `@Published var metadataService` only fires when the *reference*
        // changes, not when its inner `@Published` properties (notably
        // `pendingRequests`) mutate. Mirror its `objectWillChange` through
        // ours so the request-to-share banner repaints when a new request
        // lands.
        metadataService.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // Try to restore a previous session silently. If on-disk Tailscale
        // state is valid, `up()` returns quickly and the user is signed in
        // without clicking anything. If the state is stale or missing, the
        // BrowseToURL the IPN bus emits is suppressed (see
        // `interactiveLoginRequested`) so no browser tab pops unsolicited —
        // the user still sees the "Sign in with Tailscale" CTA.
        Task { @MainActor [weak self] in
            await self?.attemptSessionRestore()
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

        // Sharer dropped its end of the TCP connection — viewer needs to
        // run its disconnect() so the UI doesn't sit on a stale last
        // frame.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenViewerPeerClosed,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.connectionState == .viewing else { return }
                    await self.disconnect()
                }
            }
        )

        // Viewer's decoder couldn't build a session for the stream's codec.
        // The client has already asked the sharer to fall back to H.264; tell
        // the user so a momentary black screen isn't a silent mystery.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenViewerDecodeFailed,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let codec = (note.userInfo?["codec"] as? String) ?? "this"
                Task { @MainActor [weak self] in
                    guard let self = self, self.connectionState == .viewing else { return }
                    self.showAlertMessage(
                        title: L("Can't decode the video"),
                        message: L(
                            "This Mac can't decode the \(codec) video stream from the sharer (it likely lacks \(codec) hardware decode). Asking the sharer to switch to H.264 — the screen should appear in a moment."
                        ))
                }
            }
        )

        // The decode-failure escalation ladder's last rung: frames are
        // arriving but decoding has been failing for several seconds despite
        // a keyframe request and a decoder-session rebuild. Tell the user
        // the video has stalled rather than letting a frozen frame
        // masquerade as a live stream.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenViewerVideoStalled,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.connectionState == .viewing else { return }
                    self.showAlertMessage(
                        title: L("Video Has Stalled"),
                        message: L(
                            "Decoding has been failing for several seconds and automatic recovery hasn't helped. Check the connection on both ends, or disconnect and reconnect."
                        ))
                }
            }
        )

        // File → Disconnect (⌘W) posts this; bounce to disconnect().
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .tailscreenDisconnectRequested,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.connectionState == .viewing else { return }
                    await self.disconnect()
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

        // ⌃⌥M from anywhere — toggle mic without finding the menubar
        // popover or clicking through. Useful during a screen share
        // when the popover isn't visible.
        micHotkey = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: .controlOptionMask
        ) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.toggleMic()
            }
        }

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
    }

    private var cancellables = Set<AnyCancellable>()

    /// Spawn the `--picker-helper` subprocess to present the native
    /// `SCContentSharingPicker`. Once the user picks something, kicks
    /// off `startSharing(filterData:)`. User cancellation is silent —
    /// the menubar returns to idle without an alert. macOS drives the
    /// Screen Recording TCC prompt inside the picker-helper on first
    /// use; the parent process never preflights or requests permission.
    func presentNativePicker() async {
        let result: Data?
        do {
            result = try await PickerHelperClient.run()
        } catch {
            showAlertMessage(
                title: "Couldn't Open Picker",
                message: "macOS's screen-sharing picker failed to start: \(error.localizedDescription)"
            )
            return
        }
        guard let filterData = result else {
            // User cancelled — nothing to do.
            return
        }
        await startSharing(filterData: filterData)
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
        // Decode the picker selection so the sharer overlay (built lazily
        // when the first annotation arrives or "Draw on Screen" is toggled)
        // can scope its panel to the shared window/app instead of the
        // whole display. A decode failure isn't fatal — we just fall
        // back to the legacy full-display overlay.
        currentSelection = try? JSONDecoder().decode(PickerSelection.self, from: filterData)
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
            }
        }
        do {
            // If Tailscale is already initialized, just start sharing
            // Otherwise, initialize it first
            if server == nil {
                let hostname =
                    "\(Host.current().localizedName ?? "tailscreen-share")\(TailscreenInstance.hostnameSuffix)"
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
                        if Self.isUserInitiatedCaptureStop(error) {
                            await self.stopSharing(
                                reason: "SCStream userStopped: \(error?.localizedDescription ?? "nil")")
                            return
                        }
                        let receiveLoopDomain = TailscaleScreenShareServer.receiveLoopErrorDomain
                        if let error, (error as NSError).domain == receiveLoopDomain {
                            // The share's UDP control loop is dead — that's
                            // not something a fresh capture helper can fix,
                            // so skip the restart path and tear down. Tell
                            // the user: the share ending on its own must
                            // not be a silent mystery.
                            self.logger.log("Share receive loop dead (\(error)); tearing sharing down.")
                            await self.stopSharing(reason: "receive loop dead: \(error.localizedDescription)")
                            self.showAlertMessage(
                                title: L("Sharing Stopped"),
                                message: L(
                                    "The connection to your viewers was lost and couldn't be re-established, so the share was stopped. Check the network and start sharing again."
                                ))
                            return
                        }
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
                srv.onPreviewImage = { [weak self] image in
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

                // Sync the toggle state to the server before `start()` so a
                // viewer racing to HELLO during bring-up is caught.
                srv.setRequireApproval(requireViewerApproval)

                // Sharer's audio SSRC is fixed at 0. Build the channel up
                // front so HELLO_ACK assignment for viewers can route
                // through, and inbound viewer audio can be decoded.
                // Start playback engine immediately so the sharer can hear
                // viewers without first toggling their own mic on.
                do {
                    let voice = try VoiceChannel(localSSRC: 0) { [weak srv] packet in
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
                        filterData: filterData,
                        existingNode: sharedNode,
                        controlListener: controlListener
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

            let hostname = "\(Host.current().localizedName ?? "tailscreen-share")\(TailscreenInstance.hostnameSuffix)"

            // Update metadata
            metadataService.updateMetadata(isSharing: true, shareName: "\(hostname)'s Screen")

            // Hold the UI on the picker until the first preview frame
            // arrives, so SharingCard skips its black "Capturing…"
            // placeholder and lands with the live thumbnail visible.
            await waitForFirstPreview(timeout: .milliseconds(500))

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
        previewImage = nil
        currentViewers = []
        pendingViewers = []
        notifiedViewerIDs.removeAll()
        tailscaleIPs = []

        // Update metadata
        metadataService.updateMetadata(isSharing: false)

        // Stop peer monitoring if active
        peerDiscovery?.stopRealTimeMonitoring()

        sharerOverlay?.hide()
        sharerOverlay = nil
        isSharerOverlayVisible = false
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
    /// rather than refusing to render annotations.
    private static func overlayMode(for selection: PickerSelection?) -> SharerOverlayWindow.Mode {
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
        return nsErr.domain == SCStreamError.errorDomain
            && nsErr.code == SCStreamError.Code.userStopped.rawValue
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

    func connect(to host: String) async {
        guard !host.isEmpty else { return }

        connectionState = .connecting
        defer {
            if connectionState == .connecting { connectionState = .idle }
        }
        viewerAwaitingApproval = false
        let renderer = ensureViewer()
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

            // Install the audio callback BEFORE connecting. HELLO_ACK can
            // arrive on the receive loop the moment connect() returns (or
            // even slightly before, if the loop is scheduled fast); a
            // callback installed afterwards races and may miss the only
            // assignment the client ever surfaces.
            c.onAudioSSRCAssigned = { [weak self, weak c] ssrc in
                Task { @MainActor [weak self, weak c] in
                    guard let self = self, let c = c else { return }
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

            connectionState = .viewing
            connectedHostname = host
            viewerWindow?.title = L("Viewing \(host)")
            // Order matters: with the app at .accessory activation policy
            // (MenuBarExtra-only), makeKeyAndOrderFront silently no-ops
            // because non-regular apps can't make a window key. Promote
            // to .regular first, then activate, then bring the window
            // up — same idea as AppMenu's activation policy toggle.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            viewerWindow?.orderFrontRegardless()
            viewerWindow?.makeKeyAndOrderFront(nil)
        } catch {
            presentError(.connectionFailed(host: host, underlying: error))
            client = nil
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
        win.title = connectedHostname.map { L("Viewing \($0)") } ?? "Tailscreen"
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false

        // Drawing toolbar: pen / line / arrow / rectangle / oval +
        // undo + clear. Items target ViewerCommands.shared, same wiring
        // the menubar's Tools/Edit menus use.
        let toolbar = ViewerToolbar(appState: self)
        win.toolbar = toolbar.toolbar
        win.toolbarStyle = .unified
        self.viewerToolbar = toolbar

        let delegate = ViewerWindowDelegate(
            onClose: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self, self.connectionState == .viewing else { return }
                    await self.disconnect()
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
                // the "waiting for approval" placard regardless of resize.
                self.viewerAwaitingApproval = false
                // Scripted local E2E harness greps for this marker to know
                // the viewer end-to-end pipeline is working. Cheap; only
                // fires once per session.
                if !self.didLogFirstViewerFrame, size.width > 0, size.height > 0 {
                    self.didLogFirstViewerFrame = true
                    self.logger.log(
                        "E2E_MARKER firstFrame width=\(Int(size.width)) height=\(Int(size.height))")
                }
                guard !self.userResizedViewer else { return }
                self.programmaticSnap(win, toVideoPixelSize: size)
            }
        }
        if r.videoSize != .zero {
            host.videoSize = r.videoSize
            if !userResizedViewer {
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
        let overlay = AnnotationOverlayHostView(model: overlayModel)
        overlay.frame = host.bounds
        host.contentSubview = overlay
        host.addSubview(overlay)
        // Plug this canvas into the app menu so Tools / Edit / File menu
        // items act on it. ViewerCommands holds the model weakly.
        ViewerCommands.shared.activeOverlay = overlayModel
        self.viewerOverlay = overlay

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

        // Shortcut cheat-sheet overlay (toggled by toolbar "?" /
        // Help → Keyboard Shortcuts / ⇧⌘/). Added last so it draws
        // above both the stats overlay and the annotation canvas,
        // and so its tap-to-dismiss backdrop wins on hit-test.
        let shortcutsHost = ViewerShortcutsOverlayHost()
        host.addSubview(shortcutsHost.view)
        shortcutsHost.layout(in: host)
        self.viewerShortcutsHost = shortcutsHost

        // "Waiting for sharer to accept" placard. Centered, fixed size,
        // hidden by default; visibility flipped from
        // `viewerAwaitingApproval`. Added last so HELLO_PENDING during a
        // shortcuts-overlay-up moment still draws above strokes/stats and
        // sits beneath the shortcuts cheat-sheet (acceptable — the
        // cheat-sheet is user-initiated and dismissible).
        let placard = makeWaitingPlacard()
        let placardSize = NSSize(width: 360, height: 80)
        placard.frame = NSRect(
            x: (host.bounds.width - placardSize.width) / 2,
            y: (host.bounds.height - placardSize.height) / 2,
            width: placardSize.width,
            height: placardSize.height
        )
        placard.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        placard.isHidden = !viewerAwaitingApproval
        host.addSubview(placard)
        self.viewerWaitingPlacard = placard
        ViewerCommands.shared.shortcutsModel = shortcutsHost.model

        win.contentView = host
        win.makeFirstResponder(overlay)

        // Center on the main screen so the first connect doesn't dump the
        // window in the bottom-left corner.
        if let screenFrame = NSScreen.main?.visibleFrame {
            win.setFrameOrigin(
                NSPoint(
                    x: screenFrame.midX - win.frame.width / 2,
                    y: screenFrame.midY - win.frame.height / 2
                ))
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
        await connect(to: peer.tailscaleIP)
        if connectionState == .viewing {
            connectedHostname = peer.hostname
        }
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
        // Drop back to .accessory so the Dock icon goes away when there's
        // no viewer window up. connect() will promote back to .regular.
        NSApp.setActivationPolicy(.accessory)
    }

    func discoverPeers() async {
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
        // Skip when the state directory is empty — the very first launch
        // has nothing to restore, and bringing the node up would just
        // emit a BrowseToURL we're going to drop anyway.
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            logger.log("No Application Support URL available; skipping silent restore")
            return
        }
        let statePath =
            appSupport
            .appendingPathComponent("Tailscreen/tailscale\(TailscreenInstance.stateSuffix)")
            .path
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

            // Login success is visible via the menu's user profile section;
            // a popup just interrupts the flow the user was already in.
            _ = silent
        } catch {
            logger.log("Login error: \(error)")
            presentError(.loginFailed(error))
        }
    }

    private func getOrCreateNode() async throws -> TailscaleNode {
        // If node exists and is running, return it
        if let node = self.node {
            // TODO: We should check the status of the node
            return node
        }

        // One tsnet node per process, used for sign-in *and* for the
        // screen-share Listener / Client. An earlier two-node design
        // (separate "-auth" node + per-feature ephemeral nodes) made every
        // share + every connect pop a second / third browser login,
        // because each tsnet node = a distinct machine in the tailnet.
        // FileManager almost always returns Application Support under
        // .userDomainMask, but fall back to the conventional home-relative
        // path rather than force-unwrap so a missing-URL edge case
        // (sandboxing quirk, unusual environment) lands in a recoverable
        // directory creation below instead of trapping.
        let statePath = {
            let appSupport: URL
            if let url = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first {
                appSupport = url
            } else {
                logger.log("No Application Support URL; falling back to ~/Library/Application Support")
                appSupport = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support")
            }
            return appSupport.appendingPathComponent("Tailscreen/tailscale\(TailscreenInstance.stateSuffix)").path
        }()

        // Create directory if needed
        try? FileManager.default.createDirectory(
            atPath: statePath, withIntermediateDirectories: true)

        // Persist the node in the tailnet across launches so the user only
        // signs in once per Mac. `ephemeral: true` would garbage-collect
        // the device server-side as soon as the app quits, forcing a
        // browser login every relaunch — fine for CI but painful in daily
        // use.
        let baseHostname = Host.current().localizedName ?? "mac"
        let config = Configuration(
            hostName: "\(TailscreenInstance.serverHostnamePrefix)\(baseHostname)\(TailscreenInstance.hostnameSuffix)",
            path: statePath,
            authKey: TailscreenInstance.authKey,
            controlURL: TailscreenInstance.controlURLOverride ?? kDefaultControlURL,
            ephemeral: false
        )

        let node = try TailscaleNode(config: config, logger: SimpleLogger())
        self.node = node

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
        if TailscreenInstance.authKey != nil {
            try await withTimeout(seconds: 60) { try await node.up() }
        } else {
            try await node.up()
        }

        // Bind the shared TCP/7447 control listener once the node is up.
        // Idempotent (`start` no-ops on repeat); it has to live across
        // share start/stop so request-to-share messages reach us even
        // when we're not currently sharing.
        try await ensureControlListener(node: node)

        return node
    }

    /// Start (and keep) the long-lived TCP/7447 control listener bound to
    /// the local tsnet node. The `onRequestToShare` handler routes
    /// incoming prompts into `TailscreenMetadataService.pendingRequests`
    /// and fires a `UNUserNotificationCenter` toast so the user notices
    /// while the menubar popover is closed.
    private func ensureControlListener(node: TailscaleNode) async throws {
        if controlListener != nil { return }
        let l = TailscreenControlListener()
        l.onRequestToShare = { [weak self] fromHostname in
            Task { @MainActor [weak self] in
                self?.handleIncomingRequestToShare(from: fromHostname)
            }
        }
        try await l.start(node: node)
        controlListener = l
        logger.log("Control listener bound on TCP/\(NetworkConfig.tailscreenPort)")
    }

    private func handleIncomingRequestToShare(from hostname: String) {
        logger.log("Incoming request-to-share from \(hostname)")
        metadataService.handleRequestToShare(from: hostname)
        TailscreenUserNotifications.shared.postRequestToShareNotification(fromHostname: hostname)
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
            await controlListener?.stop()
            controlListener = nil
            try? await node?.close()
            node = nil
            authIPNWatcher?.stopWatching()
            authIPNWatcher = nil
            peerDiscovery?.stopRealTimeMonitoring()
            peerDiscovery = nil
            peerDiscoveryNode = nil
            availablePeers = []
            hasCompletedInitialDiscovery = false
            tailscaleIPs = []

        } catch {
            presentError(.signOutFailed(error))
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
            if let peer = availablePeers.first(where: { $0.hostname.hasPrefix(prefix) }) {
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

    func requestToShare(from peer: TailscreenPeer) async {
        let hostname = Host.current().localizedName ?? "Unknown"
        do {
            let node = try await getOrCreateNode()
            try await metadataService.sendRequestToShare(
                toIP: peer.tailscaleIP,
                port: NetworkConfig.tailscreenPort,
                from: hostname,
                via: node
            )
        } catch {
            presentError(.requestToShareFailed(peer: peer.hostname, underlying: error))
        }
    }

    /// Open (or re-focus) the preferences window. A real titled `NSWindow`
    /// hosting `SettingsView`, kept around for the process lifetime. Promote
    /// to `.regular` first for the same reason the viewer window does — an
    /// `.accessory` app (the `MenuBarExtra` default) can't make a window key,
    /// so `makeKeyAndOrderFront` would silently no-op. `AppMenu`'s window
    /// observers drop the policy back to `.accessory` once it closes.
    func presentSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(appState: self))
            let win = NSWindow(contentViewController: hosting)
            win.title = L("Tailscreen Settings")
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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

    /// Diff the new viewer roster against the previous one to fire a
    /// per-join user notification exactly once per `id`. Reuses
    /// `notifiedViewerIDs` so a hostname-resolution update that
    /// re-emits the same `id` doesn't ping twice. Notifications are
    /// best-effort: dev builds without a bundle ID won't be authorized
    /// by macOS to display banners, but the in-popover pending list
    /// still works.
    private func handleViewersChanged(_ viewers: [ViewerInfo]) {
        let previousIDs = Set(currentViewers.map { $0.id })
        let newIDs = Set(viewers.map { $0.id })
        let joinedIDs = newIDs.subtracting(previousIDs)
        currentViewers = viewers
        // Forget IDs that have left so a reconnect from the same
        // address fires a new notification.
        notifiedViewerIDs.formIntersection(newIDs)
        for id in joinedIDs where !notifiedViewerIDs.contains(id) {
            notifiedViewerIDs.insert(id)
            guard let viewer = viewers.first(where: { $0.id == id }) else { continue }
            let label = viewer.hostname ?? viewer.tailscaleIP
            ViewerJoinNotifier.shared.postJoined(label: label)
        }
    }

    /// Sync the published pending list and fire a "wants to view"
    /// notification for newly-arrived pending viewers. Fires regardless
    /// of whether the menu popover is open — that's the whole point of
    /// the approval gate.
    private func handlePendingViewersChanged(_ pending: [PendingViewerInfo]) {
        let previousIDs = Set(pendingViewers.map { $0.id })
        let newIDs = Set(pending.map { $0.id })
        let arrivedIDs = newIDs.subtracting(previousIDs)
        pendingViewers = pending
        for id in arrivedIDs {
            guard let viewer = pending.first(where: { $0.id == id }) else { continue }
            let label = viewer.hostname ?? viewer.tailscaleIP
            ViewerJoinNotifier.shared.postPending(label: label)
        }
    }

    /// Admit a pending viewer — hands off to the live server which
    /// emits the deferred HELLO_ACK and forces a keyframe.
    func approvePendingViewer(_ id: String) {
        server?.approveViewer(addr: id)
    }

    /// Reject a pending viewer — server sends SERVER_BYE so the viewer
    /// tears their session down immediately.
    func denyPendingViewer(_ id: String) {
        server?.denyViewer(addr: id)
    }

    /// Vibrancy-backed centered placard reading "Waiting for sharer to
    /// accept your connection…". Sized in caller; held by AppState and
    /// toggled via `viewerWaitingPlacard?.isHidden` from
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

        let label = NSTextField(labelWithString: "Waiting for sharer to accept your connection…")
        label.alignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: effect.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: effect.trailingAnchor, constant: -16)
        ])
        return effect
    }
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
        CATransaction.commit()
        contentSubview?.frame = rect
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

    private func aspectFitRect() -> CGRect {
        let usable = usableRect()
        guard videoSize.width > 0, videoSize.height > 0,
            usable.width > 0, usable.height > 0
        else {
            return usable
        }
        let videoAspect = videoSize.width / videoSize.height
        let viewAspect = usable.width / usable.height
        if viewAspect > videoAspect {
            // Wider than video — letterbox left/right.
            let w = usable.height * videoAspect
            return CGRect(
                x: usable.minX + (usable.width - w) / 2,
                y: usable.minY,
                width: w,
                height: usable.height)
        } else {
            // Taller than video — letterbox top/bottom.
            let h = usable.width / videoAspect
            return CGRect(
                x: usable.minX,
                y: usable.minY + (usable.height - h) / 2,
                width: usable.width,
                height: h)
        }
    }
}
