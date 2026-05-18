import AppKit
import CoreAudio
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var viewID = UUID()

    var body: some View {
        // Errors surface via `AppState.presentError` driving an
        // `NSAlert` directly — a SwiftUI `.alert` here lives inside the
        // `MenuBarExtra(.window)` popover, which dismisses on any click
        // outside its bounds, including the alert's own buttons, before
        // the handler can run.
        mainView
            .id(viewID)
            .onAppear {
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
                        if appState.sharingState == .active { await appState.stopSharing(reason: "QuitTailscreen") }
                        if appState.connectionState == .viewing { await appState.disconnect() }
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

    /// The brand artwork (display + stand variant) loaded from the
    /// SwiftPM resource bundle. Cached at type level so we don't decode
    /// the PDF every time the popover re-renders.
    private static let brandImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "WelcomeIcon", withExtension: "pdf") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Group {
                    if let brand = Self.brandImage {
                        Image(nsImage: brand)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
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
                        .accessibilityHint("Opens Tailscale sign-in in your browser")
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
        switch (appState.sharingState, appState.connectionState) {
        case (.active, _): SharingCard()
        case (_, .viewing): ViewingCard()
        case (.starting, _): StartingShareCard()
        case (_, .connecting): ConnectingCard()
        default: DisplayPickerSection()
        }
    }
}

/// Transitional state between peer click and `connectionState =
/// .viewing`. Mirror of `StartingShareCard` for the receive side.
private struct ConnectingCard: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.9)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connecting\(appState.connectedHostname.map { " to \($0)…" } ?? "…")")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Negotiating the WireGuard tunnel and waiting for the first frame.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

/// Transitional state between display click and `sharingState == .active`.
/// SCStream bring-up can take 5–10 s when replayd is unhappy
/// (multiple retries, watchdog timeouts). Without this card the
/// popover sits silently on the display picker the whole time and
/// looks like the click did nothing.
private struct StartingShareCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.9)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Starting share…")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Bringing up screen capture. macOS may take a few seconds.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

/// Card shown while sharing: live thumbnail, resolution, Stop button.
private struct SharingCard: View {
    @EnvironmentObject var appState: AppState

    private var resolutionText: String? {
        guard let res = appState.metadataService.currentMetadata?.screenResolution else { return nil }
        return "\(res.width) × \(res.height)"
    }

    /// Aspect ratio of the shared display, used to size the preview
    /// container. Falls back to 16:9 until the metadata service has
    /// reported a resolution so we don't show a 1:1 black square in
    /// the gap.
    private var screenAspect: CGFloat {
        if let res = appState.metadataService.currentMetadata?.screenResolution,
            res.height > 0
        {
            return CGFloat(res.width) / CGFloat(res.height)
        }
        return 16.0 / 9.0
    }

    /// Approximate preview height. The popover is 280 px wide, with
    /// 8 px outer padding + 12 px SharingCard inner padding on each
    /// side, leaving ~240 px of content width. Multiply by the
    /// inverse of the screen aspect to get the matching height.
    private var previewHeight: CGFloat {
        let contentWidth: CGFloat = 240
        return contentWidth / max(0.1, screenAspect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Sharing your screen")
                            .font(.system(size: 13, weight: .semibold))
                        if !appState.currentViewers.isEmpty {
                            // Pill-shaped viewer count. Small and
                            // unobtrusive — full per-viewer hostname
                            // list still renders below via `ViewersList`.
                            Text("\(appState.currentViewers.count)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Color.green)
                                )
                                .accessibilityLabel(
                                    "\(appState.currentViewers.count) "
                                        + (appState.currentViewers.count == 1
                                            ? "viewer connected"
                                            : "viewers connected")
                                )
                        }
                    }
                    if let resolutionText {
                        Text(resolutionText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            ViewersList(viewers: appState.currentViewers)

            // GeometryReader measures the popover's actual width, which
            // we feed into a derived height via the shared display's
            // aspect ratio. This is more robust than chaining
            // `.aspectRatio` + `.frame(maxWidth: .infinity)` on a Color,
            // which SwiftUI sometimes resolves to a single-line strip
            // when the parent VStack distributes height tightly.
            GeometryReader { geo in
                let height = geo.size.width / max(0.1, screenAspect)
                ZStack {
                    Color.black.opacity(appState.previewImage == nil ? 0.15 : 1.0)
                    if let image = appState.previewImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("Capturing…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: geo.size.width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: previewHeight)

            // Three buttons in 280px popover would truncate ("Unmut…",
            // "Stop Shari…"). Icon-only for Draw + Mic; full label only
            // on the destructive action so it stays prominent.
            HStack(spacing: 6) {
                Button {
                    appState.toggleSharerOverlay()
                } label: {
                    Image(systemName: appState.isSharerOverlayVisible ? "pencil.slash" : "pencil.tip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(appState.isSharerOverlayVisible ? "Stop Drawing" : "Draw")
                .accessibilityLabel(
                    appState.isSharerOverlayVisible
                        ? "Stop drawing on screen"
                        : "Draw on screen")

                Button {
                    Task { await appState.toggleMic() }
                } label: {
                    Image(systemName: appState.isMicOn ? "mic.fill" : "mic.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(appState.isMicOn ? "Mute Mic (⌃⌥M)" : "Unmute Mic (⌃⌥M)")
                .accessibilityLabel(appState.isMicOn ? "Mute microphone" : "Unmute microphone")
                .accessibilityHint("Toggles voice chat with viewers")

                Button {
                    Task { await appState.stopSharing(reason: "StopSharingButton") }
                } label: {
                    Text("Stop Sharing").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .layoutPriority(1)
                .accessibilityHint("Disconnects all viewers and ends the screen share")
            }

            AudioDevicePickers()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

/// Compact input + output device pickers. Used inside both
/// SharingCard and ViewingCard — anywhere voice playback is active.
/// Refreshes the device list on appear so hot-plugged devices show
/// up the next time the popover opens. `nil` selection means "follow
/// system default"; that's also the initial value, so newly-launched
/// instances inherit whatever the user has set in System Settings.
private struct AudioDevicePickers: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Picker(
                    "",
                    selection: Binding(
                        get: { appState.selectedInputDeviceID },
                        set: { appState.selectInputDevice($0) }
                    )
                ) {
                    Text("System default").tag(AudioDeviceID?.none)
                    ForEach(appState.availableInputDevices) { device in
                        Text(device.name).tag(AudioDeviceID?.some(device.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Microphone input device")
            }
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Picker(
                    "",
                    selection: Binding(
                        get: { appState.selectedOutputDeviceID },
                        set: { appState.selectOutputDevice($0) }
                    )
                ) {
                    Text("System default").tag(AudioDeviceID?.none)
                    ForEach(appState.availableOutputDevices) { device in
                        Text(device.name).tag(AudioDeviceID?.some(device.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Speaker output device")
            }
        }
        .font(.system(size: 11))
        .onAppear { appState.refreshAudioDevices() }
    }
}

/// Single-line viewer roster shown inside the SharingCard. Hostnames come
/// from the netmap lookup in `TailscaleScreenShareServer.resolveHostname`;
/// rows that haven't resolved yet (or whose peer isn't in the netmap) fall
/// back to the raw Tailscale IP. Truncates to keep the SharingCard
/// vertical layout stable as viewers come and go.
private struct ViewersList: View {
    let viewers: [ViewerInfo]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: viewers.isEmpty ? "person" : "person.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private var label: String {
        if viewers.isEmpty { return "No viewers yet" }
        let names = viewers.map { $0.hostname ?? $0.tailscaleIP }
        return "\(viewers.count) watching: " + names.joined(separator: ", ")
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

            HStack(spacing: 6) {
                Button {
                    Task { await appState.toggleMic() }
                } label: {
                    Label(
                        appState.isMicOn ? "Mute Mic" : "Unmute Mic",
                        systemImage: appState.isMicOn ? "mic.fill" : "mic.slash"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Toggle mic (⌃⌥M)")
                .accessibilityLabel(appState.isMicOn ? "Mute microphone" : "Unmute microphone")
                .accessibilityHint("Toggles voice chat with the sharer")

                Button {
                    Task { await appState.disconnect() }
                } label: {
                    Text("Disconnect").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Closes the viewer window and ends this session")
            }

            AudioDevicePickers()
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
///
/// Before macOS Screen Recording permission has been granted, the underlying
/// `SCShareableContent` call would pop a TCC prompt the moment the menu
/// opens. To avoid that, the section renders a single "Share my screen" CTA
/// instead of probing the displays — the prompt only fires when the user
/// actually tries to share.
private struct DisplayPickerSection: View {
    @EnvironmentObject var appState: AppState
    @State private var didKickOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "SHARE A DISPLAY")
                .padding(.top, 2)

            if !appState.hasScreenRecordingPermission {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tailscreen needs Screen Recording permission to share your display.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        // Drive the TCC prompt via the CoreGraphics
                        // surface (CGRequestScreenCaptureAccess) so the
                        // main process never has to touch
                        // SCShareableContent. If the user has previously
                        // denied access, this no-ops and the AppState
                        // shim surfaces the System Settings deep-link.
                        Task {
                            await appState.requestPermission()
                            await appState.refreshDisplays()
                        }
                    } label: {
                        Text("Grant Permission").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            } else if appState.availableDisplays.isEmpty {
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
                    .accessibilityHidden(true)

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
                        .accessibilityHidden(true)
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
        .accessibilityLabel("\(display.name), \(display.width) by \(display.height)")
        .accessibilityHint("Starts sharing this display")
    }
}

// MARK: - Devices section

private struct DevicesSection: View {
    @EnvironmentObject var appState: AppState
    @State private var didAutoDiscover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("AVAILABLE SCREENS")
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
                .help("Refresh screens")
                .accessibilityLabel("Refresh available screens")
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)

            content
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
                Text("Looking for screens…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 28)
            .padding(.horizontal, 14)
        } else if appState.availablePeers.isEmpty {
            Text("No screens available on your tailnet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(height: 28)
                .padding(.horizontal, 14)
        } else {
            let maxRows = 6
            let rowHeight: CGFloat = 28
            // `.frame(height:)` (not `maxHeight:`) commits to the
            // row count's height so SwiftUI's intrinsic sizing can't
            // collapse the ScrollView when its content negotiates a
            // smaller natural size — observed as an "empty" peer
            // section even though discovery had 1+ peers.
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
                height: rowHeight * CGFloat(min(appState.availablePeers.count, maxRows))
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
                    .accessibilityHidden(true)

                Text(peer.hostname)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Circle()
                    .fill(peer.isOnline ? Color.green : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                if isHovered && peer.isOnline {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
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
                .fill(
                    isHovered && peer.isOnline
                        ? Color.primary.opacity(0.08)
                        : Color.clear
                )
                .padding(.horizontal, 4)
        )
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(peer.hostname), \(peer.isOnline ? "online" : "offline")")
        .accessibilityHint(peer.isOnline ? "Connects to view this device's screen" : "")
    }
}

// MARK: - Identity footer

private struct IdentityFooter: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    var body: some View {
        if let profile = appState.tailscaleAuth.userProfile {
            VStack(alignment: .leading, spacing: 2) {
                Divider().padding(.vertical, 4)

                Button {
                    Task { await appState.signOut() }
                } label: {
                    HStack(spacing: 8) {
                        Image(
                            systemName: isHovered
                                ? "rectangle.portrait.and.arrow.right"
                                : "person.crop.circle.fill"
                        )
                        .font(.system(size: 18))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(isHovered ? .primary : .secondary)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(isHovered ? "Sign out" : profile.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(
                                isHovered
                                    ? "End your Tailscale session"
                                    : profile.loginName
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                        .padding(.horizontal, 4)
                )
                .onHover { isHovered = $0 }
                .help("Sign out of Tailscale")
                .accessibilityLabel("Sign out of Tailscale, signed in as \(profile.displayName)")
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
