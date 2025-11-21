import SwiftUI
import Observation

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

    private var screenCapture: ScreenCapture?
    private var server: ScreenShareServer?
    private var client: ScreenShareClient?

    var localIPAddresses: [String] {
        NetworkHelper.getLocalIPAddresses()
    }

    func startSharing() async {
        do {
            // Initialize screen capture
            screenCapture = ScreenCapture()
            try await screenCapture?.start()

            // Start server
            server = ScreenShareServer(port: 7447)
            try server?.start()

            isSharing = true
            showAlertMessage(title: "Sharing Started", message: "Your screen is now being shared on port 7447.\nOthers can connect to your IP address.")
        } catch {
            showAlertMessage(title: "Error", message: "Failed to start sharing: \(error.localizedDescription)")
        }
    }

    func stopSharing() async {
        await server?.stop()
        await screenCapture?.stop()
        server = nil
        screenCapture = nil
        isSharing = false
        showAlertMessage(title: "Sharing Stopped", message: "Screen sharing has been stopped.")
    }

    func connect(to host: String) async {
        guard !host.isEmpty else { return }

        do {
            client = ScreenShareClient()
            try await client?.connect(to: host, port: 7447)
            isConnected = true
            showAlertMessage(title: "Connected", message: "Successfully connected to \(host)")
        } catch {
            showAlertMessage(title: "Connection Failed", message: "Could not connect to \(host): \(error.localizedDescription)")
            client = nil
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        isConnected = false
        showAlertMessage(title: "Disconnected", message: "Disconnected from remote screen.")
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
