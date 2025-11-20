import AppKit
import Network
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var screenCapture: ScreenCapture?
    private var server: ScreenShareServer?
    private var client: ScreenShareClient?
    private var isSharing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create menubar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "📺"
            button.toolTip = "Cuple - Screen Share"
        }

        setupMenu()

        // Request screen recording permission
        requestScreenRecordingPermission()
    }

    private func setupMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Start Sharing", action: #selector(startSharing), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Stop Sharing", action: #selector(stopSharing), keyEquivalent: "x"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Connect to...", action: #selector(connectToServer), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Disconnect", action: #selector(disconnect), keyEquivalent: "d"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show IP Address", action: #selector(showIPAddress), keyEquivalent: "i"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func requestScreenRecordingPermission() {
        // This will trigger the permission dialog if needed
        Task {
            _ = try? await ScreenCapture.requestPermission()
        }
    }

    @objc private func startSharing() {
        guard !isSharing else { return }

        Task { @MainActor in
            do {
                // Initialize screen capture
                screenCapture = ScreenCapture()
                try await screenCapture?.start()

                // Start server
                server = ScreenShareServer(port: 7447)
                try server?.start()

                isSharing = true
                statusItem.button?.title = "📡"

                showAlert(title: "Sharing Started", message: "Your screen is now being shared on port 7447.\nOthers can connect to your IP address.")
            } catch {
                showAlert(title: "Error", message: "Failed to start sharing: \(error.localizedDescription)")
            }
        }
    }

    @objc private func stopSharing() {
        guard isSharing else { return }

        server?.stop()
        screenCapture?.stop()
        server = nil
        screenCapture = nil
        isSharing = false
        statusItem.button?.title = "📺"

        showAlert(title: "Sharing Stopped", message: "Screen sharing has been stopped.")
    }

    @objc private func connectToServer() {
        let alert = NSAlert()
        alert.messageText = "Connect to Screen Share"
        alert.informativeText = "Enter the IP address of the computer you want to view:"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "192.168.1.100"
        alert.accessoryView = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let ipAddress = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ipAddress.isEmpty else { return }

            connectToHost(ipAddress)
        }
    }

    private func connectToHost(_ host: String) {
        Task { @MainActor in
            do {
                client = ScreenShareClient()
                try await client?.connect(to: host, port: 7447)

                statusItem.button?.title = "👁️"
                showAlert(title: "Connected", message: "Successfully connected to \(host)")
            } catch {
                showAlert(title: "Connection Failed", message: "Could not connect to \(host): \(error.localizedDescription)")
                client = nil
            }
        }
    }

    @objc private func disconnect() {
        client?.disconnect()
        client = nil
        statusItem.button?.title = "📺"

        showAlert(title: "Disconnected", message: "Disconnected from remote screen.")
    }

    @objc private func showIPAddress() {
        let addresses = getLocalIPAddresses()
        let message = addresses.isEmpty ? "No network interfaces found" : addresses.joined(separator: "\n")
        showAlert(title: "Your IP Addresses", message: message)
    }

    @objc private func quit() {
        stopSharing()
        disconnect()
        NSApplication.shared.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return addresses }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            guard let interface = ptr?.pointee else { continue }
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                let name = String(cString: interface.ifa_name)

                // Skip loopback and non-active interfaces
                guard !name.starts(with: "lo") else { continue }

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                             &hostname, socklen_t(hostname.count),
                             nil, socklen_t(0), NI_NUMERICHOST) == 0 {
                    let address = String(cString: hostname)

                    // Only include IPv4 addresses
                    if addrFamily == UInt8(AF_INET) {
                        addresses.append("\(name): \(address)")
                    }
                }
            }
        }

        return addresses
    }
}
