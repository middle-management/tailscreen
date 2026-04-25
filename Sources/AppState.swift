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
    @Published var showConnectSheet = false

    private var server: TailscaleScreenShareServer?
    private var client: TailscaleScreenShareClient?
    private var node: TailscaleNode?
    private var tailscaleIPs: [String] = []

    // Persistent viewer window + renderer. Owned for the process lifetime so
    // disconnect never closes/releases an NSWindow + CAMetalLayer chain (the
    // dealloc of those types autoreleases pooled IOSurfaces into the same
    // main-queue pool a Swift Task is about to pop, producing a SIGSEGV in
    // objc_release on every disconnect variant we tried). On disconnect we
    // orderOut the window and clear the renderer's pending frame; on connect
    // we reuse the existing instances.
    @Published var viewerWindow: NSWindow?
    private var viewerRenderer: MetalViewerRenderer?

    // Peer discovery
    @Published var availablePeers: [CuplePeer] = []
    @Published var isDiscovering = false
    private var peerDiscovery: TailscalePeerDiscovery?

    // Display selection
    @Published var availableDisplays: [DisplayInfo] = []
    @Published var selectedDisplayID: CGDirectDisplayID?

    // Live thumbnail of the shared screen for the menu preview
    @Published var previewImage: NSImage?

    // Authentication
    var tailscaleAuth = TailscaleAuth()

    // Metadata and requests
    @Published var metadataService = CupleMetadataService()

    // Track if auto-login has been triggered
    private var hasTriggeredAutoLogin = false
    private var isLoggingIn = false

    init() {
        // Observe changes in tailscaleAuth and propagate them
        tailscaleAuth.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        // Kick off auto-login as soon as the app launches, not on first
        // menu open. tsnet's `node.up()` and the LocalAPI handshake take a
        // few seconds; doing it eagerly means the menubar icon is already
        // in its authenticated state by the time the user clicks.
        triggerAutoLoginIfNeeded()

        // Sharer dropped its end of the TCP connection — viewer needs to
        // run its disconnect() so the UI doesn't sit on a stale last
        // frame.
        NotificationCenter.default.addObserver(
            forName: .cupleViewerPeerClosed,
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

    var localIPAddresses: [String] {
        if !tailscaleIPs.isEmpty {
            return tailscaleIPs.map { "Tailscale: \($0)" }
        }
        return ["Starting Tailscale..."]
    }

    var rawTailscaleIPs: [String] { tailscaleIPs }

    /// Populate `availableDisplays` via ScreenCaptureKit. Safe to call any
    /// time the menu is opened; silently clears the list if the API errors
    /// (permission not granted yet).
    func refreshDisplays() async {
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

    func startSharing(displayID: CGDirectDisplayID? = nil) async {
        do {
            let pickedID = displayID ?? selectedDisplayID
            // If Tailscale is already initialized, just start sharing
            // Otherwise, initialize it first
            if server == nil {
                let hostname = "\(Host.current().localizedName ?? "cuple-share")\(CupleInstance.hostnameSuffix)"
                let srv = TailscaleScreenShareServer()
                server = srv
                if let pickedID = pickedID {
                    selectedDisplayID = pickedID
                }

                // If the user stops the ScreenCaptureKit stream from the
                // macOS menubar, tear down sharing rather than leaving an
                // empty server that's listening but has no capture source.
                srv.onCaptureStopped = { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.isSharing else { return }
                        await self.stopSharing()
                        // SCStreamErrorCode.userStopped (-3817) is what
                        // macOS sends when the user clicks "Stop" in the
                        // menubar Control Center — that's a normal stop,
                        // not an error worth a popup. Anything else
                        // (display lost, daemon crash, permission revoked)
                        // is worth surfacing.
                        if let error = error,
                           (error as NSError).code != -3817 {
                            self.showAlertMessage(
                                title: "Sharing Stopped",
                                message: "Screen capture ended: \(error.localizedDescription)"
                            )
                        }
                    }
                }
                srv.onPreviewImage = { [weak self] image in
                    Task { @MainActor [weak self] in
                        self?.previewImage = image
                    }
                }

                do {
                    try await srv.start(hostname: hostname, displayID: pickedID)
                } catch {
                    // server.start cleans itself up (await self.stop()) on
                    // capture failure; just drop our reference so a future
                    // Start Sharing rebuilds from scratch.
                    server = nil
                    if case ScreenCaptureError.startTimeout = error {
                        showAlertMessage(
                            title: "Couldn't Start Sharing",
                            message: "macOS didn't return shareable screens in time. If this is the first time you've shared, grant Cuple permission in System Settings → Privacy & Security → Screen Recording, then try again."
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

            let hostname = "\(Host.current().localizedName ?? "cuple-share")\(CupleInstance.hostnameSuffix)"

            // Update metadata
            metadataService.updateMetadata(isSharing: true, shareName: "\(hostname)'s Screen")

            isSharing = true
        } catch {
            showAlertMessage(
                title: "Error", message: "Failed to start sharing: \(error.localizedDescription)")
        }
    }

    func stopSharing() async {
        await server?.stop()
        server = nil
        previewImage = nil
        tailscaleIPs = []

        // Update metadata
        metadataService.updateMetadata(isSharing: false)

        // Stop peer monitoring if active
        peerDiscovery?.stopRealTimeMonitoring()

        isSharing = false
    }

    func connect(to host: String) async {
        guard !host.isEmpty else { return }

        let renderer = ensureViewer()
        do {
            let c = TailscaleScreenShareClient(renderer: renderer)
            client = c
            try await c.connect(to: host, port: 7447)
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

        let delegate = ViewerWindowDelegate { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, self.isConnected else { return }
                await self.disconnect()
            }
        }
        win.delegate = delegate
        self.viewerWindowDelegate = delegate

        let host = NSView(frame: win.contentView!.bounds)
        host.wantsLayer = true
        host.layer = CALayer()
        host.layer?.backgroundColor = NSColor.black.cgColor
        host.layer?.addSublayer(r.metalLayer)
        r.metalLayer.frame = host.bounds
        r.metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        win.contentView = host

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

    func connectToPeer(_ peer: CuplePeer) async {
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
                    "You need to be logged in to discover other Cuple instances."
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

    /// Trigger auto-login only once on app startup
    func triggerAutoLoginIfNeeded() {
        guard !hasTriggeredAutoLogin else { return }
        hasTriggeredAutoLogin = true

        Task {
            await initializeTailscaleAndLogin(silent: true)
        }
    }

    func login(silent: Bool = false) async {
        // Prevent multiple concurrent login attempts
        guard !isLoggingIn else {
            print("📱 [AppState] Login already in progress, skipping...")
            return
        }
        isLoggingIn = true
        defer { isLoggingIn = false }

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

        // Use a state dir distinct from the screen-share server. Both nodes
        // run in the same process and both need a Tailscale identity; pointing
        // them at the same tailscaled.state gives them the same machine key,
        // so tsnet's netmap sees a single confused peer listening twice and
        // peer discovery from a second Cuple instance silently fails to dial.
        let statePath = {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            return appSupport.appendingPathComponent("Cuple/tailscale-auth\(CupleInstance.stateSuffix)").path
        }()

        // Create directory if needed
        try? FileManager.default.createDirectory(
            atPath: statePath, withIntermediateDirectories: true)

        // Suffix "-auth" so this node doesn't share a hostname with the
        // screen-share server node. Two tsnet nodes on the same tailnet
        // with identical hostnames confuse routing/probing — peers
        // receive `connection refused` on dial even though the server
        // is actively listening.
        let baseHostname = Host.current().localizedName ?? "cuple"
        let config = Configuration(
            hostName: "\(baseHostname)\(CupleInstance.hostnameSuffix)-auth",
            path: statePath,
            authKey: nil,
            controlURL: kDefaultControlURL,
            ephemeral: true
        )

        let node = try TailscaleNode(config: config, logger: SimpleLogger())
        self.node = node

        // Bring the node up so discovery probes can actually route. Without
        // this the node's LocalAPI works (so login + status queries succeed),
        // but tailscale_dial fails silently — every peer probe returns false
        // and "Browse Shares" always lists zero.
        try await node.up()

        return node
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
            tailscaleIPs = []

        } catch {
            showAlertMessage(
                title: "Sign Out Failed",
                message: error.localizedDescription
            )
        }
    }

    func requestToShare(from peer: CuplePeer) async {
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
