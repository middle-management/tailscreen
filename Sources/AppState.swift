import Combine
import Foundation
import Observation
import SwiftUI
import TailscaleKit

@MainActor
class AppState: ObservableObject {
    @Published var isSharing = false
    @Published var isConnected = false
    @Published var statusMessage = ""
    @Published var showAlert = false
    @Published var alertTitle = ""
    @Published var alertMessage = ""
    @Published var showConnectSheet = false
    @Published var showIPSheet = false
    @Published var showBrowseSheet = false

    private var server: TailscaleScreenShareServer?
    private var client: TailscaleScreenShareClient?
    private var node: TailscaleNode?
    private var tailscaleIPs: [String] = []

    // Peer discovery
    @Published var availablePeers: [CuplePeer] = []
    @Published var isDiscovering = false
    private var peerDiscovery: TailscalePeerDiscovery?

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
    }

    private var cancellables = Set<AnyCancellable>()

    var localIPAddresses: [String] {
        if !tailscaleIPs.isEmpty {
            return tailscaleIPs.map { "Tailscale: \($0)" }
        }
        return ["Starting Tailscale..."]
    }

    func startSharing() async {
        do {
            // If Tailscale is already initialized, just start sharing
            // Otherwise, initialize it first
            if server == nil {
                let hostname = "\(Host.current().localizedName ?? "cuple-share")\(CupleInstance.hostnameSuffix)"
                let srv = TailscaleScreenShareServer()
                server = srv

                try await srv.start(hostname: hostname)

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
        tailscaleIPs = []

        // Update metadata
        metadataService.updateMetadata(isSharing: false)

        // Stop peer monitoring if active
        peerDiscovery?.stopRealTimeMonitoring()

        isSharing = false
    }

    func connect(to host: String) async {
        guard !host.isEmpty else { return }

        do {
            client = TailscaleScreenShareClient()
            try await client?.connect(to: host, port: 7447)
            isConnected = true
        } catch {
            showAlertMessage(
                title: "Connection Failed",
                message: "Could not connect to \(host): \(error.localizedDescription)")
            client = nil
        }
    }

    func connectToPeer(_ peer: CuplePeer) async {
        await connect(to: peer.tailscaleIP)
    }

    func disconnect() async {
        await client?.disconnect()
        client = nil
        isConnected = false
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
