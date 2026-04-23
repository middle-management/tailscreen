import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var viewID = UUID()

    var body: some View {
        Group {
            // SwiftUI sheets inside a MenuBarExtra(.window) popover cause the
            // popover itself to dismiss: the sheet opens in a separate NSWindow
            // that becomes key, and the menubar popover auto-closes on focus
            // loss. Render the "sheets" as inline views instead, swapping the
            // menu list out for whichever one is active.
            if appState.showBrowseSheet {
                BrowseSharesSheet()
            } else if appState.showConnectSheet {
                ConnectSheet()
            } else if appState.showIPSheet {
                IPAddressSheet()
            } else {
                menuList
            }
        }
        .alert(appState.alertTitle, isPresented: $appState.showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.alertMessage)
        }
        .id(viewID)
        .onAppear {
            print("📱 [MenuBarView] onAppear called")
            appState.triggerAutoLoginIfNeeded()
            viewID = UUID()
        }
    }

    private var menuList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Authentication section - show first if not authenticated
            if !appState.tailscaleAuth.isAuthenticated {
                Group {
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
                        .padding(.vertical, 8)
                    } else {
                        MenuButton("Log in to Tailscale", systemImage: "person.circle.fill") {
                            Task {
                                await appState.initializeTailscaleAndLogin()
                            }
                        }
                    }
                }

                Divider()
            }

            // Sharing section - only show if authenticated
            if appState.tailscaleAuth.isAuthenticated {
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
            }

            // Connection section - only show if authenticated
            if appState.tailscaleAuth.isAuthenticated {
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
            }

            // Info section - only show if authenticated
            if appState.tailscaleAuth.isAuthenticated {
                MenuButton("Show Tailscale Info", systemImage: "info.circle") {
                    appState.showIPSheet = true
                }

                Divider()
            }

            // User profile section - show when authenticated
            if let userProfile = appState.tailscaleAuth.userProfile {
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

                Divider()
            }

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
        .background(
            isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.5) : Color.clear
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct ConnectSheet: View {
    @EnvironmentObject var appState: AppState
    @State private var hostname = ""

    private func dismiss() { appState.showConnectSheet = false }

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
                .buttonStyle(.borderless)
                .controlSize(.large)

                Button("Connect") {
                    Task {
                        await appState.connect(
                            to: hostname.trimmingCharacters(in: .whitespacesAndNewlines))
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

    private func dismiss() { appState.showIPSheet = false }

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
                                NSPasteboard.general.setString(
                                    address.components(separatedBy: ": ").last ?? address,
                                    forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.borderless)
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
            .buttonStyle(.borderless)
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 450)
    }
}

struct BrowseSharesSheet: View {
    @EnvironmentObject var appState: AppState

    private func dismiss() { appState.showBrowseSheet = false }

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
                .buttonStyle(.borderless)
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
                .buttonStyle(.borderless)
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
        // Whole-row button. MenuBarExtra(.window) dismisses its popover on
        // any click that doesn't hit an interactive control; gaps around a
        // nested Connect button (icon area, hostname, spacer) fell through
        // to the popover and closed the Browse sheet. Making the row itself
        // the button fixes that and also lets the user click anywhere on
        // the row to connect.
        Button(action: onConnect) {
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
                        Text(
                            "\(metadata.shareName) • \(metadata.screenResolution.width)×\(metadata.screenResolution.height)"
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    } else {
                        Text(peer.tailscaleIP)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(peer.isOnline ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isHovered
                            ? Color(nsColor: .controlBackgroundColor)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        Color(nsColor: .separatorColor).opacity(peer.isOnline ? 0.3 : 0.15),
                        lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!peer.isOnline)
        .opacity(peer.isOnline ? 1.0 : 0.6)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
