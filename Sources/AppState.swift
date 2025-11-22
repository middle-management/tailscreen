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
    @Published var tailscaleAuth = TailscaleAuth()

    // Metadata and requests
    @Published var metadataService = CupleMetadataService()

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
                let hostname = Host.current().localizedName ?? "cuple-share"
                let srv = TailscaleScreenShareServer()
                server = srv

                try await srv.start(hostname: hostname)

                // Get the Tailscale IP addresses
                let ips = try await srv.getIPAddresses()
                tailscaleIPs = [ips.ip4, ips.ip6].compactMap { $0 }
            }

            let hostname = Host.current().localizedName ?? "cuple-share"

            // Update metadata
            metadataService.updateMetadata(isSharing: true, shareName: "\(hostname)'s Screen")

            isSharing = true

            let ipList = tailscaleIPs.joined(separator: "\n")
            showAlertMessage(
                title: "Sharing Started",
                message:
                    "Your screen is being shared via Tailscale!\n\nYour addresses:\n\(ipList)\n\nOthers can connect using your Tailscale hostname: \(hostname)"
            )
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
        showAlertMessage(title: "Sharing Stopped", message: "Screen sharing has been stopped.")
    }

    func connect(to host: String) async {
        guard !host.isEmpty else { return }

        do {
            client = TailscaleScreenShareClient()
            try await client?.connect(to: host, port: 7447)
            isConnected = true
            showAlertMessage(
                title: "Connected", message: "Successfully connected to \(host) via Tailscale")
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
        showAlertMessage(title: "Disconnected", message: "Disconnected from remote screen.")
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

            if availablePeers.isEmpty {
                showAlertMessage(
                    title: "No Shares Found",
                    message: "No other Cuple instances are currently sharing on your tailnet."
                )
            }
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
    func initializeTailscaleAndLogin() async {
        await login()
    }

    func login() async {
        do {
            // Get or create the Tailscale node
            let node = try await getOrCreateNode()

            // Run the login flow
            try await tailscaleAuth.login(node: node)

            // Update auth status after login
            await tailscaleAuth.checkAuthStatus(node: node)

            // Fetch IPs after successful login
            let ips = try await node.addrs()
            self.tailscaleIPs = [ips.ip4, ips.ip6].compactMap { $0 }

            showAlertMessage(
                title: "Login Successful",
                message: "You are now logged in to Tailscale!"
            )
        } catch {
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

        // Determine state directory
        let statePath = {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            return appSupport.appendingPathComponent("Cuple/tailscale").path
        }()

        // Create directory if needed
        try? FileManager.default.createDirectory(
            atPath: statePath, withIntermediateDirectories: true)

        // Create Tailscale configuration
        let config = Configuration(
            hostName: Host.current().localizedName ?? "cuple",
            path: statePath,
            authKey: nil,
            controlURL: kDefaultControlURL,
            ephemeral: true
        )

        // Initialize Tailscale node
        let node = try TailscaleNode(config: config, logger: SimpleLogger())
        self.node = node

        // Bring up the node in a background task
        Task {
            do {
                try await node.up()
            } catch {
                // This will fail if the user doesn't authenticate, which is expected
                // We can log this if needed, but for now we'll ignore it
                print("❗️ node.up() failed: \(error.localizedDescription)")
            }
        }

        // Give the node a moment to start up and generate the auth URL
        try await Task.sleep(for: .seconds(2))

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

            showAlertMessage(
                title: "Signed Out",
                message: "You have been signed out of Tailscale."
            )
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
            showAlertMessage(
                title: "Request Sent",
                message: "Requested \(peer.hostname) to start sharing their screen."
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
