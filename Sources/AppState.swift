import AppKit
import Combine
import CoreGraphics
import Foundation
import Observation
import QuartzCore
import SwiftUI
import TailscaleKit

@MainActor
class AppState: ObservableObject {
    @Published var isSharing = false
    @Published var isConnected = false
    @Published var connectedHostname: String?
    @Published var statusMessage = ""
    @Published var showAlert = false
    @Published var alertTitle = ""
    @Published var alertMessage = ""
    /// Whether the sharer's drawing overlay panel is currently visible and
    /// accepting input. The panel itself is only created while sharing.
    @Published var isSharerOverlayVisible = false

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
    private var viewerOverlay: DrawingOverlayView?

    // Peer discovery
    @Published var availablePeers: [TailscreenPeer] = []
    @Published var isDiscovering = false
    private var peerDiscovery: TailscalePeerDiscovery?

    // IPN-bus watcher dedicated to surfacing the interactive-login URL.
    // tsnet's `node.up()` blocks until login completes, so the only way to
    // unblock it on a fresh device is to listen on the IPN bus and open
    // the BrowseToURL it emits in the user's browser.
    private var authIPNWatcher: TailscaleIPNWatcher?

    // Display selection
    @Published var availableDisplays: [DisplayInfo] = []
    @Published var selectedDisplayID: CGDirectDisplayID?

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
        NotificationCenter.default.addObserver(
            forName: .tailscreenViewerPeerClosed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isConnected else { return }
                await self.disconnect()
            }
        }

        // File → Disconnect (⌘W) posts this; bounce to disconnect().
        NotificationCenter.default.addObserver(
            forName: .tailscreenDisconnectRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isConnected else { return }
                await self.disconnect()
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()

    /// Populate `availableDisplays` via ScreenCaptureKit. Safe to call any
    /// time the menu is opened; silently clears the list if the API errors
    /// (permission not granted yet).
    ///
    /// Skips the underlying `SCShareableContent` call entirely when Screen
    /// Recording permission has not been granted, so opening the menubar
    /// never triggers the TCC prompt — that prompt is deferred until the
    /// user actually clicks "Share my screen".
    func refreshDisplays() async {
        guard ScreenCapture.hasPermission() else {
            availableDisplays = []
            return
        }
        do {
            let displays = try await ScreenCapture.listDisplays()
            availableDisplays = displays
            if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = displays.first?.id
            }
        } catch {
            availableDisplays = []
        }
    }

    /// True once macOS has granted Screen Recording. UI uses this to swap a
    /// "Share my screen" CTA in for the display picker before first grant.
    var hasScreenRecordingPermission: Bool {
        ScreenCapture.hasPermission()
    }

    func startSharing(displayID: CGDirectDisplayID? = nil) async {
        do {
            let pickedID = displayID ?? selectedDisplayID
            // If Tailscale is already initialized, just start sharing
            // Otherwise, initialize it first
            if server == nil {
                let hostname = "\(Host.current().localizedName ?? "tailscreen-share")\(TailscreenInstance.hostnameSuffix)"
                let srv = TailscaleScreenShareServer()
                server = srv
                if let pickedID = pickedID {
                    selectedDisplayID = pickedID
                }

                // If the user stops the ScreenCaptureKit stream from the
                // macOS menubar, tear down sharing rather than leaving an
                // empty server that's listening but has no capture source.
                srv.onCaptureStopped = { [weak self] _ in
                    // The macOS Control Center "Stop" button is the only
                    // common path here, and the menubar icon already
                    // reflects the new idle state — popping an alert on
                    // top of an action the user just took is pure
                    // friction. Tear sharing down quietly.
                    Task { @MainActor [weak self] in
                        guard let self = self, self.isSharing else { return }
                        await self.stopSharing()
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
                // overlay panel. ScreenCaptureKit captures the panel (nothing
                // is excluded, see `ScreenCapture.swift:41`), so the drawings
                // flow out to every viewer via the H.264 stream — no
                // sharer→viewer broadcast needed.
                srv.onAnnotationReceived = { [weak self] op in
                    Task { @MainActor [weak self] in
                        self?.ensureSharerOverlay().apply(remoteOp: op)
                    }
                }

                do {
                    // Reuse the AppState-owned tsnet node so the screen
                    // share doesn't spin up a second machine that needs
                    // its own browser sign-in.
                    let sharedNode = try await getOrCreateNode()
                    try await srv.start(
                        hostname: hostname,
                        displayID: pickedID,
                        existingNode: sharedNode
                    )
                } catch {
                    // server.start cleans itself up (await self.stop()) on
                    // capture failure; just drop our reference so a future
                    // Start Sharing rebuilds from scratch.
                    server = nil
                    if case ScreenCaptureError.startTimeout = error {
                        showAlertMessage(
                            title: "Couldn't Start Sharing",
                            message: "macOS didn't return shareable screens in time. If this is the first time you've shared, grant Tailscreen permission in System Settings → Privacy & Security → Screen Recording, then try again."
                        )
                    } else {
                        showAlertMessage(
                            title: "Couldn't Start Sharing",
                            message: error.localizedDescription
                        )
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

            isSharing = true
        } catch {
            showAlertMessage(
                title: "Error", message: "Failed to start sharing: \(error.localizedDescription)")
        }
    }

    func stopSharing() async {
        // Unblock any startSharing still waiting on the first preview, so
        // a fast start→stop doesn't strand its continuation.
        if let cont = pendingFirstPreview {
            pendingFirstPreview = nil
            cont.resume()
        }

        await server?.stop()
        server = nil
        previewImage = nil
        tailscaleIPs = []

        // Update metadata
        metadataService.updateMetadata(isSharing: false)

        // Stop peer monitoring if active
        peerDiscovery?.stopRealTimeMonitoring()

        sharerOverlay?.hide()
        sharerOverlay = nil
        isSharerOverlayVisible = false

        isSharing = false
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

    /// Toggle whether the sharer can draw on their own screen. The panel is
    /// always present while sharing (so viewer-originated drawings render);
    /// this only flips input capture vs. click-through.
    func toggleSharerOverlay() {
        guard isSharing else { return }
        let overlay = ensureSharerOverlay()
        isSharerOverlayVisible.toggle()
        overlay.setInputEnabled(isSharerOverlayVisible)
    }

    func connect(to host: String) async {
        guard !host.isEmpty else { return }

        let renderer = ensureViewer()
        do {
            let c = TailscaleScreenShareClient(renderer: renderer)
            client = c
            // Reuse the AppState-owned tsnet node so connecting doesn't
            // spin up a third machine + browser sign-in flow.
            let sharedNode = try await getOrCreateNode()
            try await c.connect(to: host, port: 7447, existingNode: sharedNode)
            isConnected = true
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
            showAlertMessage(
                title: "Connection Failed",
                message: "Could not connect to \(host): \(error.localizedDescription)")
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
        let toolbar = ViewerToolbar()
        win.toolbar = toolbar.toolbar
        win.toolbarStyle = .unified
        self.viewerToolbar = toolbar

        let delegate = ViewerWindowDelegate { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, self.isConnected else { return }
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
        let host = AspectFitHostView(frame: win.contentView!.bounds)
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
        let overlay = DrawingOverlayView(frame: host.bounds)
        overlay.currentColor = Annotation.RGBA.paletteColor(forIdentity: TailscaleScreenShareClient.localIdentity())
        host.contentSubview = overlay
        host.addSubview(overlay)
        overlay.onOp = { [weak self] op in
            Task { [weak self] in await self?.client?.sendAnnotationOp(op) }
        }
        // Plug this overlay into the app menu so Tools / Edit / File
        // menu items act on it. ViewerCommands holds it weakly.
        ViewerCommands.shared.activeOverlay = overlay
        self.viewerOverlay = overlay

        win.contentView = host
        win.makeFirstResponder(overlay)

        // Center on the main screen so the first connect doesn't dump the
        // window in the bottom-left corner.
        if let screenFrame = NSScreen.main?.visibleFrame {
            win.setFrameOrigin(NSPoint(
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
        if isConnected {
            connectedHostname = peer.hostname
        }
    }

    func disconnect() async {
        await client?.disconnect()
        client = nil
        isConnected = false
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
            showAlertMessage(
                title: "Discovery Failed",
                message:
                    "Sign in with Tailscale first to discover other Tailscreen instances on your tailnet."
            )
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
            showAlertMessage(title: "Discovery Failed", message: error.localizedDescription)
        }
        isDiscovering = false
    }

    func requestPermission() async {
        do {
            try await ScreenCapture.requestPermission()
        } catch {
            showAlertMessage(
                title: "Permission Error",
                message:
                    "Failed to request screen recording permission: \(error.localizedDescription)")
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
        // Skip when the state directory is empty — the very first launch
        // has nothing to restore, and bringing the node up would just
        // emit a BrowseToURL we're going to drop anyway.
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let statePath = appSupport
            .appendingPathComponent("Tailscreen/tailscale\(TailscreenInstance.stateSuffix)")
            .path
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: statePath)) ?? []
        guard !contents.isEmpty else {
            print("📱 [AppState] No saved Tailscale state at \(statePath); skipping silent restore")
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
                print("📱 [AppState] Restored signed-in Tailscale session")
            } else {
                print("📱 [AppState] No valid saved session; awaiting explicit sign-in")
            }
        } catch {
            print("📱 [AppState] Silent restore skipped: \(error)")
        }
    }

    func login(silent: Bool = false) async {
        // Prevent multiple concurrent login attempts
        guard !isLoggingIn else {
            print("📱 [AppState] Login already in progress, skipping...")
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
            print("📱 [AppState] Starting login flow...")
            // Get or create the Tailscale node
            let node = try await getOrCreateNode()

            print("📱 [AppState] Node created, calling tailscaleAuth.login...")
            // Run the login flow
            try await tailscaleAuth.login(node: node)

            print("📱 [AppState] Login completed, checking auth status...")
            // Update auth status after login
            await tailscaleAuth.checkAuthStatus(node: node)

            // Fetch IPs after successful login
            let ips = try await node.addrs()
            self.tailscaleIPs = [ips.ip4, ips.ip6].compactMap { $0 }

            // Login success is visible via the menu's user profile section;
            // a popup just interrupts the flow the user was already in.
            _ = silent
        } catch {
            print("📱 [AppState] Login error: \(error)")
            showAlertMessage(
                title: "Login Failed",
                message: "Failed to log in: \(error.localizedDescription)"
            )
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
        let statePath = {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
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
            authKey: nil,
            controlURL: kDefaultControlURL,
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
                    print("📱 [AppState] Suppressing BrowseToURL during silent restore")
                    return
                }
                print("📱 [AppState] Opening login URL in browser: \(url)")
                NSWorkspace.shared.open(url)
            }
        }
        do {
            try await watcher.startWatching(node: node)
            return watcher
        } catch {
            print("📱 [AppState] Browse-URL watcher failed to start: \(error)")
            return nil
        }
    }

    func signOut() async {
        do {
            try await tailscaleAuth.signOut()

            // Stop sharing if active
            if isSharing {
                await stopSharing()
            }

            // Disconnect if connected
            if isConnected {
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
            showAlertMessage(
                title: "Sign Out Failed",
                message: error.localizedDescription
            )
        }
    }

    func requestToShare(from peer: TailscreenPeer) async {
        let hostname = Host.current().localizedName ?? "Unknown"
        do {
            try await metadataService.sendRequestToShare(
                to: peer.tailscaleIP,
                port: 7447,
                from: hostname
            )
        } catch {
            showAlertMessage(
                title: "Request Failed",
                message: "Could not send request to \(peer.hostname): \(error.localizedDescription)"
            )
        }
    }

    private func showAlertMessage(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

// Simple logger for LocalAPIClient
private struct SimpleLogger: LogSink {
    var logFileHandle: Int32? = nil

    func log(_ message: String) {
        print("[LocalAPI] \(message)")
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
              bounds.width > 0, bounds.height > 0 else {
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
