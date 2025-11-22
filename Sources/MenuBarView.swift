import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sharing section
            Group {
                if appState.isSharing {
                    MenuButton("Stop Sharing", systemImage: "stop.circle") {
                        Task {
                            await appState.stopSharing()
                        }
                    }
                } else {
                    MenuButton("Start Sharing", systemImage: "play.circle") {
                        Task {
                            await appState.startSharing()
                        }
                    }
                }
            }

            Divider()

            // Connection section
            Group {
                if appState.isConnected {
                    MenuButton("Disconnect", systemImage: "xmark.circle") {
                        Task {
                            await appState.disconnect()
                        }
                    }
                } else {
                    MenuButton("Browse Shares...", systemImage: "network") {
                        appState.showBrowseSheet = true
                    }
                    MenuButton("Connect to...", systemImage: "link") {
                        appState.showConnectSheet = true
                    }
                }
            }

            Divider()

            // Info section
            MenuButton("Show Tailscale Info", systemImage: "info.circle") {
                appState.showIPSheet = true
            }

            Divider()

            // Authentication section
            Group {
                if let userProfile = appState.tailscaleAuth.userProfile {
                    // Show user info when logged in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Text(userProfile.displayName)
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text(userProfile.loginName)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 19)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))

                    MenuButton("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                        Task {
                            await appState.signOut()
                        }
                    }
                } else if appState.isSharing || appState.isConnected {
                    // Show login button when Tailscale is active but not logged in
                    if appState.tailscaleAuth.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.8)
                            Text("Authenticating...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    } else {
                        MenuButton("Log in to Tailscale", systemImage: "person.circle") {
                            Task {
                                await appState.login()
                            }
                        }
                    }
                }
            }

            Divider()

            // Status
            if appState.isSharing {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                    Text("Sharing")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }

            if appState.isConnected {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.blue)
                    Text("Connected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }

            Divider()

            // Quit
            MenuButton("Quit", systemImage: "power") {
                Task {
                    if appState.isSharing {
                        await appState.stopSharing()
                    }
                    if appState.isConnected {
                        await appState.disconnect()
                    }
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .frame(width: 220)
        .sheet(isPresented: $appState.showConnectSheet) {
            ConnectSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showIPSheet) {
            IPAddressSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showBrowseSheet) {
            BrowseSharesSheet()
                .environmentObject(appState)
        }
        .alert(appState.alertTitle, isPresented: $appState.showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(appState.alertMessage)
        }
    }
}

struct MenuButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
                    .font(.system(size: 13))
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.5) : Color.clear)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct ConnectSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var hostname = ""

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Connect via Tailscale")
                    .font(.system(size: 15, weight: .semibold))

                Text("Enter the Tailscale hostname or IP address:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            TextField("hostname or 100.x.x.x", text: $hostname)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(width: 280)

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                .controlSize(.large)

                Button("Connect") {
                    Task {
                        await appState.connect(to: hostname.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(hostname.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

struct IPAddressSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Tailscale Connection Info")
                .font(.system(size: 15, weight: .semibold))

            if appState.localIPAddresses.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Tailscale not connected")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 100)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(appState.localIPAddresses, id: \.self) { address in
                        HStack(spacing: 12) {
                            Text(address)
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(address.components(separatedBy: ": ").last ?? address, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .help("Copy to clipboard")
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.return)
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 450)
    }
}

struct BrowseSharesSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Browse Available Shares")
                    .font(.system(size: 15, weight: .semibold))

                Spacer()

                Button {
                    Task {
                        await appState.discoverPeers()
                    }
                } label: {
                    if appState.isDiscovering {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                    }
                }
                .buttonStyle(.plain)
                .disabled(appState.isDiscovering)
                .help("Refresh")
            }

            if appState.isDiscovering {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Discovering Cuple instances on your tailnet...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 180)
            } else if appState.availablePeers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No shares found")
                        .font(.system(size: 14, weight: .medium))
                    Text("Click the refresh button to search for Cuple instances on your tailnet")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(height: 180)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.availablePeers) { peer in
                            PeerRow(peer: peer) {
                                Task {
                                    await appState.connectToPeer(peer)
                                    dismiss()
                                }
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(height: 220)
            }

            HStack(spacing: 12) {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                .controlSize(.large)

                Spacer()

                if !appState.isDiscovering && appState.availablePeers.isEmpty {
                    Button("Discover") {
                        Task {
                            await appState.discoverPeers()
                        }
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            // Auto-discover when sheet opens
            Task {
                await appState.discoverPeers()
            }
        }
    }
}

struct PeerRow: View {
    @EnvironmentObject var appState: AppState
    let peer: CuplePeer
    let onConnect: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Computer icon with online status indicator
            ZStack(alignment: .topTrailing) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 20))
                    .foregroundStyle(peer.isOnline ? .primary : .secondary)
                    .frame(width: 28)

                // Online status dot
                Circle()
                    .fill(peer.isOnline ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                    .offset(x: 2, y: -2)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(peer.hostname)
                        .font(.system(size: 13, weight: .medium))

                    if !peer.isOnline {
                        Text("(offline)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                // Show metadata if available
                if let metadata = peer.metadata {
                    Text("\(metadata.shareName) • \(metadata.screenResolution.width)×\(metadata.screenResolution.height)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text(peer.tailscaleIP)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Connect button
            Button("Connect") {
                onConnect()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!peer.isOnline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(peer.isOnline ? 0.3 : 0.15), lineWidth: 0.5)
        )
        .opacity(peer.isOnline ? 1.0 : 0.6)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
