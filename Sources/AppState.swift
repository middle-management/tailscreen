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

    private var server: TailscaleScreenShareServer?
    private var client: TailscaleScreenShareClient?
    private var node: TailscaleNode?
    private var tailscaleIPs: [String] = []
    private var sharerOverlay: SharerOverlayWindow?

    // Persistent viewer window + renderer. Owned for the process lifetime so
    // disconnect never closes/releases an NSWindow + CAMetalLayer chain (the
    // dealloc of those types autoreleases pooled IOSurfaces into the same
    // main-queue pool a Swift Task is about to pop, producing a SIGSEGV in
    // objc_release on every disconnect variant we tried). On disconnect we
    // orderOut the window and clear the renderer's pending frame; on connect
    // we reuse the existing instances.
    @Published var viewerWindow: NSWindow?
    private var viewerRenderer: MetalViewerRenderer?
    private var viewerOverlay: AnnotationOverlayHostView?
    /// Hosts the stats overlay subview pinned to the top-left of the
    /// viewer's content view. Held strongly so the visibility-toggle
    /// Combine subscription it owns lives for the lifetime of the
    /// viewer window.
    private var viewerStatsHost: ViewerStatsOverlayHost?
    /// Hosts the keyboard-shortcut cheat-sheet overlay. Toggled by the
    /// toolbar's "?" button and Help → Keyboard Shortcuts (⇧⌘/).
    private var viewerShortcutsHost: ViewerShortcutsOverlayHost?

    // Peer discovery
    @Published var availablePeers: [TailscreenPeer] = []
    @Published var isDiscovering = false
    private var peerDiscovery: TailscalePeerDiscovery?

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

    init() {
        // Observe changes in tailscaleAuth and propagate them
        tailscaleAuth.objectWillChange.sink { [weak self] _ in
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

    /// True once macOS has granted Screen Recording. UI uses this to swap a
    /// "Share my screen" CTA in for the picker button before first grant.
    var hasScreenRecordingPermission: Bool {
        ScreenCapture.hasPermission()
    }

    /// Spawn the `--picker-helper` subprocess to present the native
    /// `SCContentSharingPicker`. Once the user picks something, kicks
    /// off `startSharing(filterData:)`. User cancellation is silent —
    /// the menubar returns to idle without an alert.
    func presentNativePicker() async {
        // Proactive permission gate. `SCContentSharingPicker` won't
        // show anything useful without baseline TCC. Trigger the
        // (non-invasive) request first; if the user denies, surface
        // actionable guidance instead of spawning a picker that will
        // come back empty.
        if !ScreenCapture.hasPermission() {
            let granted = ScreenCapture.requestPermissionNonInvasive()
            if !granted {
                presentScreenRecordingDenied()
                return
            }
        }
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
        // Proactive permission gate. Even though `presentNativePicker`
        // gates here too, this is the common entry — every route into
        // a share lands on it, so the gate belongs here. Without it,
        // a permission denial would only surface mid-bring-up after
        // the user had already waited through the cool-down + watchdog.
        if !ScreenCapture.hasPermission() {
            let granted = ScreenCapture.requestPermissionNonInvasive()
            if !granted {
                presentScreenRecordingDenied()
                return
            }
        }
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
                // overlay panel. ScreenCaptureKit captures the panel (the
                // helper's `SCContentFilter` excludes nothing — see
                // `ScreenCapture.start`), so the drawings flow out to every
                // viewer via the H.264 stream — no sharer→viewer broadcast
                // needed.
                srv.onAnnotationReceived = { [weak self] op in
                    Task { @MainActor [weak self] in
                        self?.ensureSharerOverlay().apply(remoteOp: op)
                    }
                }

                srv.onViewersChanged = { [weak self] viewers in
                    Task { @MainActor [weak self] in
                        self?.currentViewers = viewers
                    }
                }

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
                        existingNode: sharedNode
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

    func stopSharing(reason: String = "<unknown>", caller: String = #function) async {
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
        tailscaleIPs = []

        // Update metadata
        metadataService.updateMetadata(isSharing: false)

        // Stop peer monitoring if active
        peerDiscovery?.stopRealTimeMonitoring()

        sharerOverlay?.hide()
        sharerOverlay = nil
        isSharerOverlayVisible = false

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
    /// either the sharer toggles input on, or a viewer sends us an op. The
    /// panel needs to be on-screen for ScreenCaptureKit to pick up its
    /// annotations and carry them into the video for every viewer.
    @discardableResult
    private func ensureSharerOverlay() -> SharerOverlayWindow {
        if let overlay = sharerOverlay { return overlay }
        let overlay = SharerOverlayWindow()
        // Sharer's own strokes don't need to be transmitted; they appear in
        // the video stream automatically.
        overlay.onOp = { _ in }
        overlay.show()
        sharerOverlay = overlay
        return overlay
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
        let renderer = ensureViewer()
        do {
            let c = TailscaleScreenShareClient(renderer: renderer)
            client = c

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
        win.title = "Tailscale Screen Share"
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false

        // Drawing toolbar: pen / line / arrow / rectangle / oval +
        // undo + clear. Items target ViewerCommands.shared, same wiring
        // the menubar's Tools/Edit menus use.
        let toolbar = ViewerToolbar(appState: self)
        win.toolbar = toolbar.toolbar
        win.toolbarStyle = .unified
        self.viewerToolbar = toolbar

        let delegate = ViewerWindowDelegate { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, self.connectionState == .viewing else { return }
                await self.disconnect()
            }
        }
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
        host.metalLayer = r.metalLayer
        host.layer?.addSublayer(r.metalLayer)
        // Mirror any video-size changes onto the host so it relays out the
        // overlay to the new aspect rect.
        r.onVideoSizeChanged = { [weak host] size in
            host?.videoSize = size
        }
        if r.videoSize != .zero {
            host.videoSize = r.videoSize
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

        // Shortcut cheat-sheet overlay (toggled by toolbar "?" /
        // Help → Keyboard Shortcuts / ⇧⌘/). Added last so it draws
        // above both the stats overlay and the annotation canvas,
        // and so its tap-to-dismiss backdrop wins on hit-test.
        let shortcutsHost = ViewerShortcutsOverlayHost()
        host.addSubview(shortcutsHost.view)
        shortcutsHost.layout(in: host)
        self.viewerShortcutsHost = shortcutsHost
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
        viewerRenderer?.clearPendingBuffer()
        viewerWindow?.orderOut(nil)
        // Drop back to .accessory so the Dock icon goes away when there's
        // no viewer window up. connect() will promote back to .regular.
        NSApp.setActivationPolicy(.accessory)
    }

    func discoverPeers() async {
        // Need an active Tailscale node to discover peers
        // Try to get it from either server or client
        guard let node = server?.node ?? client?.node ?? self.node else {
            presentError(.discoveryUnauthenticated())
            return
        }

        let discovery = TailscalePeerDiscovery()
        self.peerDiscovery = discovery

        isDiscovering = true
        do {
            try await discovery.startDiscovery(node: node)
            self.availablePeers = discovery.availablePeers

            // Start real-time monitoring for peer status updates
            try? await discovery.startRealTimeMonitoring(node: node)

            // Observe peer changes
            Task { @MainActor in
                for await peers in discovery.$availablePeers.values {
                    self.availablePeers = peers
                }
            }

            // Empty list is already reflected inline in the Browse sheet —
            // no popup needed.
        } catch {
            presentError(.discoveryFailed(error))
        }
        isDiscovering = false
    }

    /// Trigger the macOS Screen Recording TCC prompt (or surface a
    /// "go to System Settings" guidance alert if the user has already
    /// denied access). Uses `CGRequestScreenCaptureAccess` so the main
    /// process never has to touch `SCShareableContent` — see the
    /// CLAUDE.md warning. Safe to call on every "Share my screen"
    /// click; after the first grant it's a no-op.
    func requestPermission() async {
        let granted = ScreenCapture.requestPermissionNonInvasive()
        if !granted {
            presentError(.screenRecordingDenied())
        }
    }

    /// Surface a clear guidance alert when Screen Recording permission
    /// is denied. The alert includes a button that deep-links into
    /// System Settings → Privacy & Security → Screen Recording so the
    /// user can flip the toggle without hunting through panes.
    func presentScreenRecordingDenied() {
        presentError(.screenRecordingDenied())
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
            hostName: "tailscreen-\(baseHostname)\(TailscreenInstance.hostnameSuffix)",
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
        try await node.up()

        return node
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
            try? await node?.close()
            node = nil
            authIPNWatcher?.stopWatching()
            authIPNWatcher = nil
            tailscaleIPs = []

        } catch {
            presentError(.signOutFailed(error))
        }
    }

    func requestToShare(from peer: TailscreenPeer) async {
        let hostname = Host.current().localizedName ?? "Unknown"
        do {
            try await metadataService.sendRequestToShare(
                to: peer.tailscaleIP,
                port: NetworkConfig.tailscreenPort,
                from: hostname
            )
        } catch {
            presentError(.requestToShareFailed(peer: peer.hostname, underlying: error))
        }
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
            alert.informativeText = "\(error.message)\n\nError code: \(error.code)"
            alert.alertStyle = .warning

            if let action = error.action {
                alert.addButton(withTitle: action.title)
            }
            alert.addButton(withTitle: "Copy Details")
            alert.addButton(withTitle: "OK")

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
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        return false
    }
}

/// Container for the viewer window's video + annotation overlay. Lays
/// both out at the aspect-fit rect of the source video inside the host
/// bounds, so a click on the overlay maps 1:1 to a pixel on the sharer's
/// captured screen no matter how the user resizes the window.
private final class AspectFitHostView: NSView {
    weak var metalLayer: CAMetalLayer?
    weak var contentSubview: NSView?
    var videoSize: CGSize = .zero {
        didSet {
            guard videoSize != oldValue else { return }
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let rect = aspectFitRect()
        // CALayer frame changes go through an implicit animation by
        // default — disable it so the layer snaps to the new aspect rect
        // in lockstep with the overlay subview.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer?.frame = rect
        CATransaction.commit()
        contentSubview?.frame = rect
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        // NSView's autoresize machinery would otherwise stretch the
        // overlay to fill bounds; we manage the frame ourselves.
        needsLayout = true
    }

    private func aspectFitRect() -> CGRect {
        let bounds = self.bounds
        guard videoSize.width > 0, videoSize.height > 0,
            bounds.width > 0, bounds.height > 0
        else {
            return bounds
        }
        let videoAspect = videoSize.width / videoSize.height
        let viewAspect = bounds.width / bounds.height
        if viewAspect > videoAspect {
            // Wider than video — letterbox left/right.
            let w = bounds.height * videoAspect
            return CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
        } else {
            // Taller than video — letterbox top/bottom.
            let h = bounds.width / videoAspect
            return CGRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        }
    }
}
