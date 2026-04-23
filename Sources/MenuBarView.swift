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
            if appState.showConnectSheet {
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
                if appState.isSharing {
                    MenuButton("Stop Sharing", systemImage: "stop.circle") {
                        Task {
                            await appState.stopSharing()
                        }
                    }
                } else {
                    DisplayPickerSection()
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
                        InlinePeersSection()
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

/// Display picker rendered inline in the menu when the user is not yet
/// sharing. One row per attached display; clicking a row starts sharing
/// that specific display. Refreshes on appear to catch hot-plug changes.
struct DisplayPickerSection: View {
    @EnvironmentObject var appState: AppState
    @State private var didKickOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Share a Display")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if appState.availableDisplays.isEmpty {
                Text("No displays available")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.availableDisplays) { display in
                    DisplayRow(display: display) {
                        Task { await appState.startSharing(displayID: display.id) }
                    }
                }
            }
        }
        .onAppear {
            guard !didKickOff else { return }
            didKickOff = true
            Task { await appState.refreshDisplays() }
        }
    }
}

private struct DisplayRow: View {
    let display: DisplayInfo
    let onPick: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                Image(systemName: "display")
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                        .font(.system(size: 13))
                    Text("\(display.width)×\(display.height)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.5) : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Compact peer list rendered directly in the menu, replacing the old
/// "Browse Shares..." modal. Kicks discovery on appear and shows a one-line
/// row per Cuple peer — click to connect.
struct InlinePeersSection: View {
    @EnvironmentObject var appState: AppState
    @State private var didKickOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Available Shares")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await appState.discoverPeers() }
                } label: {
                    if appState.isDiscovering {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(appState.isDiscovering)
                .help("Refresh")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            if appState.isDiscovering && appState.availablePeers.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Searching…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            } else if appState.availablePeers.isEmpty {
                Text("No shares found")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                ForEach(appState.availablePeers) { peer in
                    InlinePeerRow(peer: peer) {
                        Task { await appState.connectToPeer(peer) }
                    }
                }
            }
        }
        .onAppear {
            guard !didKickOff else { return }
            didKickOff = true
            Task { await appState.discoverPeers() }
        }
    }
}

private struct InlinePeerRow: View {
    @EnvironmentObject var appState: AppState
    let peer: CuplePeer
    let onConnect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 13))
                    .foregroundStyle(peer.isOnline ? .primary : .secondary)
                Text(peer.hostname)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(peer.isOnline ? Color.accentColor : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.5) : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!peer.isOnline)
        .opacity(peer.isOnline ? 1.0 : 0.5)
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

