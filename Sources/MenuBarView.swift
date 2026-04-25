import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
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
            } else {
                mainView
            }
        }
        .alert(appState.alertTitle, isPresented: $appState.showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.alertMessage)
        }
        .id(viewID)
        .onAppear {
            appState.triggerAutoLoginIfNeeded()
            viewID = UUID()
        }
    }

    @ViewBuilder
    private var mainView: some View {
        if !appState.tailscaleAuth.isAuthenticated {
            WelcomeView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                StatusSection()
                DevicesSection()
                IdentityFooter()
                Divider().padding(.vertical, 4)
                MenuRow(
                    "Quit Tailscreen",
                    systemImage: nil,
                    shortcut: "⌘Q"
                ) {
                    Task {
                        if appState.isSharing { await appState.stopSharing() }
                        if appState.isConnected { await appState.disconnect() }
                        NSApplication.shared.terminate(nil)
                    }
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.vertical, 6)
            .frame(width: 280)
        }
    }
}

// MARK: - Welcome / Unauthenticated

private struct WelcomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "tv")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                Text("Welcome to Tailscreen")
                    .font(.system(size: 15, weight: .semibold))

                Text("Sign in with Tailscale to share and view screens with your peers.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)

                Group {
                    if appState.tailscaleAuth.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Signing in…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 28)
                    } else {
                        Button {
                            Task { await appState.initializeTailscaleAndLogin() }
                        } label: {
                            Text("Sign in with Tailscale")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
            .padding(.vertical, 16)

            Divider().padding(.vertical, 4)

            MenuRow("Quit Tailscreen", systemImage: nil, shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 6)
        .frame(width: 280)
    }
}

// MARK: - Status section (idle / sharing / viewing)

private struct StatusSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.isSharing {
            SharingCard()
        } else if appState.isConnected {
            ViewingCard()
        } else {
            DisplayPickerSection()
        }
    }
}

/// Card shown while sharing: live thumbnail, resolution, Stop button.
private struct SharingCard: View {
    @EnvironmentObject var appState: AppState

    private var resolutionText: String? {
        guard let res = appState.metadataService.currentMetadata?.screenResolution else { return nil }
        return "\(res.width) × \(res.height)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sharing your screen")
                        .font(.system(size: 13, weight: .semibold))
                    if let resolutionText {
                        Text(resolutionText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Group {
                if let image = appState.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("Capturing…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.15))
                    )
                }
            }

            HStack(spacing: 6) {
                Button {
                    appState.toggleSharerOverlay()
                } label: {
                    Label(
                        appState.isSharerOverlayVisible ? "Stop Drawing" : "Draw",
                        systemImage: appState.isSharerOverlayVisible ? "pencil.slash" : "pencil.tip"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task { await appState.stopSharing() }
                } label: {
                    Text("Stop Sharing").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

/// Card shown while viewing a remote peer.
private struct ViewingCard: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Viewing \(appState.connectedHostname ?? "peer")")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Connected over Tailscale")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Button {
                Task { await appState.disconnect() }
            } label: {
                Text("Disconnect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

/// Display picker shown when idle. One row per attached display; clicking
/// a row starts sharing that display.
private struct DisplayPickerSection: View {
    @EnvironmentObject var appState: AppState
    @State private var didKickOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "SHARE A DISPLAY")
                .padding(.top, 2)

            if appState.availableDisplays.isEmpty {
                Text("No displays available")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: 28)
                    .padding(.horizontal, 14)
            } else {
                ForEach(appState.availableDisplays) { display in
                    DisplayRow(display: display) {
                        Task { await appState.startSharing(displayID: display.id) }
                    }
                }
            }
        }
        .padding(.bottom, 6)
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
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text("\(display.width) × \(display.height)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if isHovered {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                .padding(.horizontal, 4)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Devices section

private struct DevicesSection: View {
    @EnvironmentObject var appState: AppState
    @State private var didAutoDiscover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("DEVICES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    Task { await appState.discoverPeers() }
                } label: {
                    if appState.isDiscovering {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 14)
                    }
                }
                .buttonStyle(.plain)
                .disabled(appState.isDiscovering)
                .help("Refresh devices")
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)

            content

            MenuRow("Connect to address…", systemImage: "keyboard") {
                appState.showConnectSheet = true
            }
        }
        .padding(.bottom, 4)
        .onAppear {
            guard !didAutoDiscover else { return }
            didAutoDiscover = true
            Task { await appState.discoverPeers() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if appState.isDiscovering && appState.availablePeers.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Looking for devices…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 28)
            .padding(.horizontal, 14)
        } else if appState.availablePeers.isEmpty {
            Text("No devices found on your tailnet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(height: 28)
                .padding(.horizontal, 14)
        } else {
            let maxRows = 6
            let rowHeight: CGFloat = 28
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(appState.availablePeers) { peer in
                        PeerMenuRow(peer: peer) {
                            Task { await appState.connectToPeer(peer) }
                        }
                    }
                }
            }
            .frame(
                maxHeight: rowHeight * CGFloat(min(appState.availablePeers.count, maxRows))
            )
        }
    }
}

private struct PeerMenuRow: View {
    @EnvironmentObject var appState: AppState
    let peer: TailscreenPeer
    let onConnect: () -> Void
    @State private var isHovered = false

    // Whole-row button. MenuBarExtra(.window) dismisses its popover on any
    // click that doesn't hit an interactive control; making the row itself
    // the button avoids gaps falling through to the popover.
    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 13))
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(peer.isOnline ? .secondary : .tertiary)

                Text(peer.hostname)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Circle()
                    .fill(peer.isOnline ? Color.green : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 6, height: 6)

                Spacer(minLength: 0)

                if isHovered && peer.isOnline {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!peer.isOnline)
        .opacity(peer.isOnline ? 1.0 : 0.55)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered && peer.isOnline
                    ? Color.primary.opacity(0.08)
                    : Color.clear)
                .padding(.horizontal, 4)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Identity footer

private struct IdentityFooter: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let profile = appState.tailscaleAuth.userProfile {
            VStack(alignment: .leading, spacing: 2) {
                Divider().padding(.vertical, 4)

                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(profile.loginName)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)

                MenuRow("Copy Tailscale address", systemImage: "doc.on.doc") {
                    let ip = appState.rawTailscaleIPs.first ?? ""
                    guard !ip.isEmpty else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ip, forType: .string)
                }

                MenuRow("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await appState.signOut() }
                }
            }
        }
    }
}

// MARK: - Small section header label

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

// MARK: - Menu row

struct MenuRow: View {
    let title: String
    let systemImage: String?
    let shortcut: String?
    let action: () -> Void
    @State private var isHovered = false

    init(
        _ title: String,
        systemImage: String?,
        shortcut: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                        .frame(width: 16, alignment: .center)
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(width: 16, height: 1)
                }

                Text(title)
                    .font(.system(size: 13))

                Spacer()

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                .padding(.horizontal, 4)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Connect sheet

struct ConnectSheet: View {
    @EnvironmentObject var appState: AppState
    @State private var hostname = ""

    private func dismiss() { appState.showConnectSheet = false }

    private var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard isValid else { return }
        let host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await appState.connect(to: host)
            dismiss()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect to address")
                    .font(.system(size: 14, weight: .semibold))
                Text("Enter a Tailscale hostname or IP.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            TextField("hostname or 100.x.x.x", text: $hostname)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .controlSize(.regular)

                Button("Connect", action: submit)
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(!isValid)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
