import Foundation

// EXAMPLE: How to use Tailscale with Cuple
// This file demonstrates the basic usage patterns

// MARK: - Server Example

func exampleServer() async {
    print("=== Tailscale Server Example ===\n")

    let server = TailscaleScreenShareServer(port: 7447)

    do {
        // Option 1: Use environment variable TS_AUTHKEY
        try await server.start(hostname: "my-mac-screen")

        // Option 2: Provide auth key explicitly
        // try await server.start(
        //     hostname: "my-mac-screen",
        //     authKey: "tskey-auth-xxxxxxxxxxxxx"
        // )

        // Get Tailscale IPs
        let ips = server.getIPAddresses()
        print("✅ Server started!")
        print("📡 Tailscale IPs: \(ips.joined(separator: ", "))")
        print("🔗 Share this with others: my-mac-screen:7447")
        print("💡 Or use IP: \(ips.first ?? "unknown"):7447\n")

        // Server is now:
        // - Capturing your screen
        // - Encoding to H.264
        // - Streaming to any connected clients over Tailscale

        // Keep running until interrupted
        print("Server running... Press Ctrl+C to stop")
        try await Task.sleep(for: .seconds(3600)) // Run for 1 hour

    } catch {
        print("❌ Server error: \(error)")
    }

    server.stop()
    print("🛑 Server stopped")
}

// MARK: - Client Example

func exampleClient() async {
    print("=== Tailscale Client Example ===\n")

    let client = TailscaleScreenShareClient()

    do {
        // Connect using hostname (preferred)
        try await client.connect(to: "my-mac-screen", port: 7447)

        // Or connect using Tailscale IP
        // try await client.connect(to: "100.64.0.1", port: 7447)

        print("✅ Connected!")
        print("🎥 Video window should appear automatically\n")

        // Client is now:
        // - Receiving H.264 stream
        // - Decoding frames
        // - Displaying in window

        // Keep running until window is closed
        print("Client running... Close the window to disconnect")
        try await Task.sleep(for: .seconds(3600)) // Run for 1 hour

    } catch {
        print("❌ Client error: \(error)")
    }

    client.disconnect()
    print("🛑 Client disconnected")
}

// MARK: - Advanced Example: Managing Multiple Connections

class TailscaleScreenShareManager {
    private var server: TailscaleScreenShareServer?
    private var client: TailscaleScreenShareClient?
    private var isServerRunning = false
    private var isClientConnected = false

    func startServer(hostname: String? = nil) async throws {
        guard !isServerRunning else {
            print("ℹ️ Server already running")
            return
        }

        let server = TailscaleScreenShareServer()
        self.server = server

        let hostname = hostname ?? Host.current().localizedName ?? "cuple-\(UUID().uuidString.prefix(8))"
        try await server.start(hostname: hostname)

        isServerRunning = true

        let ips = server.getIPAddresses()
        print("✅ Server running on: \(ips.joined(separator: ", "))")
        print("📱 Share: \(hostname)")
    }

    func stopServer() {
        guard isServerRunning else { return }

        server?.stop()
        server = nil
        isServerRunning = false

        print("🛑 Server stopped")
    }

    func connectClient(to host: String) async throws {
        guard !isClientConnected else {
            print("ℹ️ Client already connected")
            return
        }

        let client = TailscaleScreenShareClient()
        self.client = client

        try await client.connect(to: host, port: 7447)

        isClientConnected = true

        print("✅ Connected to \(host)")
    }

    func disconnectClient() {
        guard isClientConnected else { return }

        client?.disconnect()
        client = nil
        isClientConnected = false

        print("🛑 Client disconnected")
    }

    func getServerInfo() -> [String]? {
        guard isServerRunning else { return nil }
        return server?.getIPAddresses()
    }
}

// MARK: - Integration with AppState

// Here's how you might integrate with your existing AppState:
/*
@Observable
class AppState {
    // Existing properties
    var screenShareServer: ScreenShareServer?
    var screenShareClient: ScreenShareClient?

    // Add Tailscale support
    var tailscaleServer: TailscaleScreenShareServer?
    var tailscaleClient: TailscaleScreenShareClient?
    var useTailscale: Bool = false

    func startSharing() {
        Task {
            if useTailscale {
                let server = TailscaleScreenShareServer()
                tailscaleServer = server
                try? await server.start(hostname: Host.current().localizedName ?? "cuple")

                // Get and display Tailscale IPs
                let ips = server.getIPAddresses()
                print("Share via Tailscale: \(ips.first ?? "unknown")")
            } else {
                // Traditional TCP
                let server = ScreenShareServer(port: 7447)
                screenShareServer = server
                try? server.start()
            }
        }
    }

    func stopSharing() {
        if useTailscale {
            tailscaleServer?.stop()
            tailscaleServer = nil
        } else {
            screenShareServer?.stop()
            screenShareServer = nil
        }
    }

    func connectToServer(address: String) {
        Task {
            if useTailscale {
                let client = TailscaleScreenShareClient()
                tailscaleClient = client
                try? await client.connect(to: address, port: 7447)
            } else {
                let client = ScreenShareClient()
                screenShareClient = client
                try? await client.connect(to: address, port: 7447)
            }
        }
    }

    func disconnect() {
        if useTailscale {
            tailscaleClient?.disconnect()
            tailscaleClient = nil
        } else {
            screenShareClient?.disconnect()
            screenShareClient = nil
        }
    }
}
*/

// MARK: - UI Integration

// Add to MenuBarView.swift:
/*
Section("Network Mode") {
    Picker("Network", selection: $appState.useTailscale) {
        Text("LAN (Traditional)").tag(false)
        Text("Tailscale (Secure)").tag(true)
    }

    if appState.useTailscale {
        Text("🔒 Encrypted via Tailscale")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
*/

// MARK: - Main Entry Point Example

@main
struct TailscaleExampleApp {
    static func main() async {
        print("Cuple Tailscale Integration Example\n")
        print("1. Run as server")
        print("2. Run as client\n")

        // For demo purposes, you'd read user input here
        // For now, let's show server example:

        await exampleServer()

        // To run client instead:
        // await exampleClient()
    }
}
