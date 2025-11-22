import SwiftUI
import Observation
import Foundation

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
    private var tailscaleIPs: [String] = []

    // Peer discovery
    @Published var availablePeers: [CuplePeer] = []
    @Published var isDiscovering = false
    private var peerDiscovery: TailscalePeerDiscovery?

    var localIPAddresses: [String] {
        if !tailscaleIPs.isEmpty {
            return tailscaleIPs.map { "Tailscale: \($0)" }
        }
        return ["Starting Tailscale..."]
    }

    func startSharing() async {
        do {
            // Start Tailscale server with hostname
            let hostname = Host.current().localizedName ?? "cuple-share"
            let srv = TailscaleScreenShareServer()
            server = srv

            try await srv.start(hostname: hostname)

            // Get the Tailscale IP addresses
            let ips = try await srv.getIPAddresses()
            tailscaleIPs = [ips.ip4, ips.ip6].compactMap { $0 }

            isSharing = true

            let ipList = tailscaleIPs.joined(separator: "\n")
            showAlertMessage(
                title: "Sharing Started",
                message: "Your screen is being shared via Tailscale!\n\nYour addresses:\n\(ipList)\n\nOthers can connect using your Tailscale hostname: \(hostname)"
            )
        } catch {
            showAlertMessage(title: "Error", message: "Failed to start sharing: \(error.localizedDescription)")
        }
    }

    func stopSharing() async {
        await server?.stop()
        server = nil
        tailscaleIPs = []
        isSharing = false
        showAlertMessage(title: "Sharing Stopped", message: "Screen sharing has been stopped.")
    }

    func connect(to host: String) async {
        guard !host.isEmpty else { return }

        do {
            client = TailscaleScreenShareClient()
            try await client?.connect(to: host, port: 7447)
            isConnected = true
            showAlertMessage(title: "Connected", message: "Successfully connected to \(host) via Tailscale")
        } catch {
            showAlertMessage(title: "Connection Failed", message: "Could not connect to \(host): \(error.localizedDescription)")
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
        guard let node = server?.node ?? client?.node else {
            showAlertMessage(
                title: "Discovery Failed",
                message: "You need to start sharing or connect to a peer first to discover other Cuple instances."
            )
            return
        }

        let discovery = TailscalePeerDiscovery()
        self.peerDiscovery = discovery

        isDiscovering = true
        do {
            try await discovery.startDiscovery(node: node)
            self.availablePeers = discovery.availablePeers

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
            showAlertMessage(title: "Permission Error", message: "Failed to request screen recording permission: \(error.localizedDescription)")
        }
    }

    private func showAlertMessage(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}
