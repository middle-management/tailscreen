import AppKit
import CoreAudio
import SwiftUI

/// `card` for top-level module cards; `inner` for anything nested inside a
/// card or hoverable row. `.continuous` corners throughout, matching macOS
/// system surfaces.
private enum PopoverRadius {
    static let card: CGFloat = 10
    static let inner: CGFloat = 6
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var viewID = UUID()

    var body: some View {
        // Errors surface via `AppState.presentError` driving an `NSAlert`
        // directly — a SwiftUI `.alert` here lives inside the
        // `MenuBarExtra(.window)` popover, which dismisses on any outside
        // click, including the alert's own buttons, before the handler runs.
        mainView
            .id(viewID)
            .onAppear {
                // Second stash site for the main-window opener (see
                // `MainWindowView.onAppear`).
                appState.openMainWindowAction = { openWindow(id: TailscreenApp.mainWindowID) }
                // Remount without animation: MenuBarExtra(.window) keeps this
                // view alive while closed, so an animated id-swap would
                // crossfade stale content with fresh (ghost rows/doubled headers).
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    viewID = UUID()
                }
            }
    }

    @ViewBuilder
    private var mainView: some View {
        // Signed out AND idle -> pointer to the window's sign-in pane. Signed
        // out but SHARING (guest-only link share) -> full popover, since its
        // approval prompts must stay reachable.
        //
        // `== .idle`, not `!isLive`: a failed link-only start has nothing
        // running but plenty to say (its reason lives on the sharing card
        // here), so routing it to the signed-out pointer would bury the
        // explanation once the alert is dismissed.
        if !appState.tailscaleAuth.isAuthenticated && appState.sharingState == .idle {
            SignedOutMenuView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                PopoverIdentityHeader()
                PendingRequestsBanner()
                StatusSection()
                Divider().padding(.vertical, 4)
                MenuRow(
                    L("Open Tailscreen"),
                    systemImage: nil
                ) {
                    appState.presentMainWindow()
                }
                MenuRow(
                    L("Quit Tailscreen"),
                    systemImage: nil,
                    shortcut: "⌘Q"
                ) {
                    Task {
                        if appState.sharingState == .sharing { await appState.stopSharing(reason: "QuitTailscreen") }
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

// MARK: - Signed out

/// Compact signed-out popover: the full welcome / sign-in pane lives in the
/// main window (`MainWindowView.WelcomePane`); the menubar just points there.
private struct SignedOutMenuView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Not signed in"))
                    .font(.headline)
                Text(L("Open Tailscreen to sign in with Tailscale."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider().padding(.vertical, 4)

            MenuRow(L("Open Tailscreen"), systemImage: nil) {
                appState.presentMainWindow()
            }
            MenuRow(L("Quit Tailscreen"), systemImage: nil, shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 6)
        .frame(width: 280)
    }
}

// MARK: - Identity strip

/// Which account/tailnet a share started here will appear on — ambiguous
/// otherwise with multi-account profiles. Tailnet name leads since login
/// names collide across tailnets; click opens the main window.
private struct PopoverIdentityHeader: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    var body: some View {
        if let profile = appState.tailscaleAuth.userProfile {
            Button {
                appState.presentMainWindow()
            } label: {
                HStack(spacing: 8) {
                    AccountAvatar(
                        name: profile.displayName, pictureURL: profile.profilePicURL,
                        size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(
                            verbatim: profile.tailnetName.isEmpty
                                ? profile.loginName : profile.tailnetName
                        )
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        if !profile.tailnetName.isEmpty {
                            Text(verbatim: profile.loginName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(MenuRowHoverBackground(isHovered: isHovered))
            .onHover { isHovered = $0 }
            .help(L("Open Tailscreen"))
            .accessibilityLabel(L("Signed in as \(profile.loginName)"))
            .accessibilityHint(L("Opens the Tailscreen window"))

            Divider().padding(.vertical, 4)
        }
    }
}

// MARK: - Pending requests (peer asked us to share)

/// Renders one orange card per incoming request-to-share. Shown at the top
/// of both the menubar popover and the main window's hub. Share routes
/// through `presentNativePicker` — the same path the "Choose what to
/// share…" button uses — so the picker-helper subprocess + TCC handshake
/// always runs.
struct PendingRequestsBanner: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let requests = appState.pendingShareRequests
        // Suppress while already sharing/viewing; requests stay queued for
        // when state returns to idle.
        let busy = appState.sharingState.isLive || appState.connectionState != .idle
        if requests.isEmpty || busy {
            EmptyView()
        } else {
            VStack(spacing: 6) {
                ForEach(requests) { req in
                    HStack(spacing: 10) {
                        Image(systemName: "hand.wave.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("\(req.fromHostname) wants you to share"))
                                .font(.callout.weight(.semibold))
                                .lineLimit(2)
                            Text(L("Tap Share to choose what to show"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button(L("Decline")) {
                            appState.respondToShareRequest(req, accepted: false)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        Button(L("Share")) {
                            appState.respondToShareRequest(req, accepted: true)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.sharingState == .sharing)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: PopoverRadius.card, style: .continuous)
                            .fill(Color.orange.opacity(0.14))
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Status section (idle / sharing / viewing)

private struct StatusSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch (appState.sharingState, appState.connectionState) {
        case (.sharing, _): SharingCard()
        case (_, .viewing): ViewingCard()
        case (.starting, _): StartingShareCard()
        case (_, .connecting): ConnectingCard()
        default: DisplayPickerSection()
        }
    }
}

/// Mirror of `StartingShareCard` for the receive side.
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
                    Text(appState.connectedHostname.map { L("Connecting to \($0)…") } ?? L("Connecting…"))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(L("Negotiating the WireGuard tunnel and waiting for the first frame."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: PopoverRadius.card, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

/// SCStream bring-up can take 5-10s when replayd is unhappy; without this
/// card the click looks like it did nothing.
private struct StartingShareCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.9)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Starting share…"))
                        .font(.headline)
                    Text(L("Bringing up screen capture. macOS may take a few seconds."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: PopoverRadius.card, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
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

    /// Popover is 280px wide minus 8px outer + 12px card padding each side = ~240px.
    private var previewHeight: CGFloat {
        let contentWidth: CGFloat = 240
        return contentWidth / SharePreviewThumbnail.screenAspect(appState)
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
                        Text(L("Sharing your screen"))
                            .font(.headline)
                        if !appState.currentViewers.isEmpty {
                            // Full per-viewer list still renders below via `ViewersList`.
                            Text(verbatim: "\(appState.currentViewers.count)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Color.green)
                                )
                                .accessibilityLabel(
                                    appState.currentViewers.count == 1
                                        ? L("1 viewer connected")
                                        : L("\(appState.currentViewers.count) viewers connected")
                                )
                        }
                    }
                    if let resolutionText {
                        Text(resolutionText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if appState.notificationsDenied {
                NotificationsOffNotice()
            }

            ViewersList(viewers: appState.currentViewers)

            if !appState.pendingViewers.isEmpty {
                PendingViewersList(viewers: appState.pendingViewers)
            }

            if let grantee = appState.controlGrantee {
                RemoteControlGranteeBanner(grantee: grantee)
            }

            if !appState.controlRequests.isEmpty {
                ControlRequestsList(requests: appState.controlRequests)
            }

            // A guest-only share has no tailnet viewers to approve.
            if !appState.isGuestOnlyShare {
                ApprovalToggle()
            }

            if appState.linkSharingEnabled {
                ShareViaLinkSection()
            }

            SharePreviewThumbnail(height: previewHeight)

            ShareSessionControls(style: .popover)

            AudioDevicePickers()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: PopoverRadius.card, style: .continuous)
                .fill(Color.green.opacity(0.12))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

/// The ~1Hz thumbnail the capture helper sends back, as a black rounded box
/// shaped like the shared display.
///
/// The caller gives the height; width derives from the shared display's
/// aspect, so one component serves both a fixed-width popover and a
/// resizable window without either measuring anything, and stays letterbox-free.
struct SharePreviewThumbnail: View {
    @EnvironmentObject var appState: AppState
    let height: CGFloat

    /// Falls back to 16:9 before the metadata service reports a resolution.
    /// Static because `SharingCard` needs the same number for its own height.
    static func screenAspect(_ appState: AppState) -> CGFloat {
        guard let res = appState.metadataService.currentMetadata?.screenResolution,
            res.height > 0
        else { return 16.0 / 9.0 }
        return CGFloat(res.width) / CGFloat(res.height)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(appState.previewImage == nil ? 0.15 : 1.0)
            if let image = appState.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(L("Capturing…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: height * max(0.1, Self.screenAspect(appState)), height: height)
        .clipShape(RoundedRectangle(cornerRadius: PopoverRadius.inner, style: .continuous))
        // No-op in the popover; centers the narrower box in the window card.
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            appState.previewImage == nil
                ? L("Capturing…")
                : L("Live preview of what you're sharing"))
    }
}

/// One component, two layouts, since the two surfaces have different width
/// budgets for the same four actions. `style` rather than a bool pair: only
/// these two real surfaces exist.
struct ShareSessionControls: View {
    enum Style: Equatable {
        /// One row of icon-only buttons, Stop Sharing on the end — labelled
        /// buttons would truncate in 280pt; `.help` tooltips carry the naming.
        case popover
        /// 2x2 grid of labelled buttons, no Stop (the card's status row
        /// already carries it).
        case window
    }

    @EnvironmentObject var appState: AppState
    var style: Style = .popover

    private var isLabelled: Bool { style == .window }

    /// nil `micShortcutDisplay` hides an unmappable stored chord rather than
    /// misprinting it.
    private var micTooltip: String {
        guard let chord = appState.micShortcutDisplay else {
            return appState.isMicOn ? L("Mute Mic") : L("Unmute Mic")
        }
        return appState.isMicOn ? L("Mute Mic (\(chord))") : L("Unmute Mic (\(chord))")
    }

    var body: some View {
        switch style {
        case .popover:
            HStack(spacing: 6) {
                changeSourceButton
                drawButton
                micButton
                systemAudioButton
                stopButton
            }
        case .window:
            // Two HStacks, not a Grid: columns line up across rows for free.
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    changeSourceButton
                    drawButton
                }
                HStack(spacing: 6) {
                    micButton
                    systemAudioButton
                }
            }
        }
    }

    @ViewBuilder
    private func controlLabel(_ systemImage: String, _ title: String) -> some View {
        if isLabelled {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        } else {
            Image(systemName: systemImage)
                .frame(maxWidth: .infinity)
        }
    }

    private var changeSourceButton: some View {
        Button {
            Task { await appState.changeShareSource() }
        } label: {
            controlLabel("rectangle.on.rectangle", L("Change source…"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(appState.isChangingSource)
        .help(L("Change source…"))
        .accessibilityLabel(L("Change what you're sharing"))
        .accessibilityHint(L("Reopens the picker without disconnecting viewers"))
    }

    private var drawButton: some View {
        Button {
            appState.toggleSharerOverlay()
        } label: {
            controlLabel(
                appState.isSharerOverlayVisible ? "pencil.slash" : "pencil.tip",
                appState.isSharerOverlayVisible ? L("Stop Drawing") : L("Draw"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(appState.isSharerOverlayVisible ? L("Stop Drawing") : L("Draw"))
        .accessibilityLabel(
            appState.isSharerOverlayVisible
                ? L("Stop drawing on screen")
                : L("Draw on screen"))
    }

    private var micButton: some View {
        Button {
            Task { await appState.toggleMic() }
        } label: {
            controlLabel(
                appState.isMicOn ? "mic.fill" : "mic.slash",
                appState.isMicOn ? L("Mute Mic") : L("Unmute Mic"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(micTooltip)
        .accessibilityLabel(appState.isMicOn ? L("Mute microphone") : L("Unmute microphone"))
        .accessibilityHint(L("Toggles voice chat with viewers"))
    }

    private var systemAudioButton: some View {
        Button {
            appState.toggleSystemAudio()
        } label: {
            controlLabel(
                appState.isSystemAudioOn ? "speaker.wave.2.fill" : "speaker.slash",
                appState.isSystemAudioOn ? L("Mute System Audio") : L("Share System Audio"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(
            appState.isSystemAudioOn
                ? L("Mute System Audio")
                : L("Share System Audio")
        )
        .accessibilityLabel(
            appState.isSystemAudioOn
                ? L("Mute System Audio")
                : L("Share System Audio")
        )
        .accessibilityHint(L("Shares your computer's audio with viewers"))
    }

    private var stopButton: some View {
        Button {
            Task {
                // Recorded here, not inside `stopSharing` (also the teardown
                // funnel for failures/quit) — this is the menubar press specifically.
                AppDiagnostics.action(.actionShareStop, ["surface": .string("MenuBar")])
                await appState.stopSharing(reason: "StopSharingButton")
            }
        } label: {
            Text(L("Stop Sharing")).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .layoutPriority(1)
        .accessibilityHint(L("Disconnects all viewers and ends the screen share"))
    }
}

/// The "Share via Link" toggle, live token with Copy Link/Copy Token, New
/// Link rotation, and guest count. Hidden when Settings -> Link Sharing is
/// off. The token dies with the toggle, a rotation, or the share.
///
/// Non-private: the hub window's share card renders it too.
struct ShareViaLinkSection: View {
    @EnvironmentObject var appState: AppState

    private var guestCountText: String {
        switch appState.guestCount {
        case 0: return L("No guests yet")
        case 1: return L("1 guest")
        default: return L("\(appState.guestCount) guests")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appState.isGuestOnlyShare {
                // No off position short of Stop Sharing; state the mode
                // instead of a toggle that refuses to flip.
                Text(L("Sharing via link — the link is the only way in"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle(
                    isOn: Binding(
                        get: { appState.shareLinkToken != nil || appState.shareLinkBusy },
                        set: { appState.setShareLinkActive($0) }
                    )
                ) {
                    Text(L("Share via Link"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(appState.shareLinkBusy)
                .accessibilityHint(
                    L("Creates a link that lets people outside your tailnet ask to join"))
            }

            if appState.shareLinkBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(L("Creating link…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let token = appState.shareLinkToken {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: token)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("Share link token"))
                HStack(spacing: 6) {
                    Button(L("Copy Link")) {
                        copyToPasteboard(ShareLinkFormat.link(token: token))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .help(L("Copies a tailscreen: link that opens the join screen"))
                    Button(L("Copy Web Link")) {
                        copyToPasteboard(ShareLinkFormat.webLink(token: token))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(L("Copies an https: link that opens the share in a browser — no app needed"))
                    Button(L("Copy Token")) {
                        copyToPasteboard(token)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(L("Copies the bare token, for pasting into the join screen"))
                    Button(L("New Link")) {
                        appState.rotateShareLink()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(L("Replaces the link — the old one stops working and current guests are dropped"))
                    Spacer(minLength: 0)
                }
                Text(verbatim: guestCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    L(
                        "Anyone with the link can ask to join; you approve each guest. The link stops working when sharing stops."
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = appState.shareLinkError {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Refreshes the device list on appear so hot-plugged devices show up next
/// open. `nil` selection means "follow system default", also the initial value.
struct AudioDevicePickers: View {
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
                    Text(L("System default")).tag(AudioDeviceID?.none)
                    ForEach(appState.availableInputDevices) { device in
                        Text(device.name).tag(AudioDeviceID?.some(device.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(L("Microphone input device"))
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
                    Text(L("System default")).tag(AudioDeviceID?.none)
                    ForEach(appState.availableOutputDevices) { device in
                        Text(device.name).tag(AudioDeviceID?.some(device.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(L("Speaker output device"))
            }
        }
        .font(.subheadline)
        .onAppear { appState.refreshAudioDevices() }
    }
}

/// One row per connected viewer with a health dot reflecting the server's
/// per-viewer loss attribution: `good`, `degraded` (packet loss), or
/// `throttled` (keyframe-only, that viewer was isolating the session).
/// Trailing X disconnects one-time — nothing is remembered ("Deny & Block" is
/// the persistent variant, on the pending row).
///
/// Non-private, like `PendingViewersList`/`ControlRequestsList`, so the hub
/// window can render it too.
struct ViewersList: View {
    @EnvironmentObject var appState: AppState
    let viewers: [ViewerInfo]

    var body: some View {
        if viewers.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "person")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(L("No viewers yet"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(viewers) { viewer in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Self.dotColor(for: viewer.health))
                            .frame(width: 8, height: 8)
                            .help(Self.tooltip(for: viewer.health))
                            .accessibilityHidden(true)
                        Text(rowName(for: viewer))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityLabel(healthLabel(for: viewer))
                        if viewer.isGuest {
                            GuestBadge()
                        }
                        Spacer(minLength: 0)
                        Button {
                            appState.disconnectConnectedViewer(viewer.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Disconnect this viewer"))
                        .accessibilityLabel(L("Disconnect \(viewer.displayName)"))
                    }
                }
            }
        }
    }

    private func healthLabel(for viewer: ViewerInfo) -> String {
        let name = rowName(for: viewer)
        return L("\(name), \(Self.tooltip(for: viewer.health))")
    }

    /// Guests have no hostname; falls back to the tunnel IP before the
    /// fingerprint resolves.
    private func rowName(for viewer: ViewerInfo) -> String {
        guard viewer.isGuest else { return viewer.displayName }
        return appState.guestFingerprint(forIP: viewer.tailscaleIP) ?? viewer.displayName
    }

    private static func dotColor(for health: ViewerHealth) -> Color {
        switch health {
        case .good: return .green
        case .degraded: return .yellow
        case .throttled: return .orange
        }
    }

    private static func tooltip(for health: ViewerHealth) -> String {
        switch health {
        case .good: return L("Connection healthy")
        case .degraded: return L("Connection degraded — packet loss")
        case .throttled: return L("Limited to keyframes — poor connection")
        }
    }
}

/// Warns the sharer that macOS will not show the approval banners this app
/// relies on — the user explicitly denied notification permission.
///
/// Rendered on **both** sharer surfaces, like the other decision-adjacent
/// components: someone who never opens the popover is exactly the person this
/// warning is for.
///
/// One-directional on purpose. It appears only when the app *knows* delivery is
/// off; its absence is not a claim that notifications work, because a Focus
/// filtering us, a revoked Time Sensitive allowance, or an alert style of None
/// are all invisible to the app. Reassuring on incomplete information would be
/// worse than saying nothing — a sharer who trusts a green light and misses a
/// waiting viewer is the failure this whole surface exists to prevent.
struct NotificationsOffNotice: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "bell.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                // The text says it; the glyph would just repeat it.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Notifications are turned off for Tailscreen."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("Requests to view or control will only appear here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Open Settings")) {
                    let path = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
                    if let url = URL(string: path) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Primary click acts once; each button's attached menu adds the remembered
/// variant ("Always Allow"/"Deny & Block"), persisted under the peer's
/// StableNodeID. Hostnames/StableNodeID may take a moment to resolve via the
/// netmap lookup; falls back to the raw Tailscale IP meanwhile.
struct PendingViewersList: View {
    @EnvironmentObject var appState: AppState
    let viewers: [PendingViewerInfo]

    var body: some View {
        listBody
            // Distinguishes "sharer never saw it" from "sharer saw it and did
            // nothing" — the two halves of the commonest stuck session.
            .recordsDiagnosticSurface("PendingViewersList")
    }

    private var listBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewers) { viewer in
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Text(rowName(for: viewer))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if viewer.isGuest {
                        GuestBadge()
                    }
                    Spacer(minLength: 4)
                    if viewer.isGuest {
                        // No remembered variants for guests (no StableNodeID);
                        // Deny already denylists the guest's node key at the
                        // tunnel for this link's life.
                        Button(L("Deny")) {
                            appState.denyPendingViewer(viewer.id)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .fixedSize()
                        .accessibilityLabel(L("Deny \(viewer.displayName)"))
                        Button(L("Accept")) {
                            appState.approvePendingViewer(viewer.id)
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .fixedSize()
                        .accessibilityLabel(L("Accept \(viewer.displayName)"))
                    } else {
                        Menu {
                            // Enabled before StableNodeID resolves: the intent
                            // queues and persists once it lands.
                            Button(L("Deny & Block")) {
                                appState.denyPendingViewerAndBlock(viewer.id)
                            }
                        } label: {
                            Text(L("Deny")).font(.caption)
                        } primaryAction: {
                            appState.denyPendingViewer(viewer.id)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .fixedSize()
                        .accessibilityLabel(L("Deny \(viewer.displayName)"))
                        Menu {
                            // Same as Deny & Block above.
                            Button(L("Always Allow")) {
                                appState.approvePendingViewerAlways(viewer.id)
                            }
                        } label: {
                            Text(L("Accept")).font(.caption)
                        } primaryAction: {
                            appState.approvePendingViewer(viewer.id)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .fixedSize()
                        .accessibilityLabel(L("Accept \(viewer.displayName)"))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: PopoverRadius.inner, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    /// See `ViewersList.rowName(for:)`.
    private func rowName(for viewer: PendingViewerInfo) -> String {
        guard viewer.isGuest else { return viewer.displayName }
        return appState.guestFingerprint(forIP: viewer.tailscaleIP) ?? viewer.displayName
    }
}

/// Marks a roster/approval row as a share-by-token guest, identified by node
/// key rather than a machine name.
struct GuestBadge: View {
    var body: some View {
        Text(L("Guest"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.purple)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.purple.opacity(0.15)))
            .accessibilityLabel(L("Guest viewer"))
    }
}

/// Granting revokes any current grantee (single-holder). Granting without
/// Accessibility permission queues the grant, which completes once the
/// permission lands (see `AppState.grantRemoteControl`).
struct ControlRequestsList: View {
    @EnvironmentObject var appState: AppState
    let requests: [ControlRequestInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(requests) { request in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "cursorarrow.rays")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                        Text(L("\(request.displayName) wants control"))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button(L("Deny")) {
                            appState.denyRemoteControl(request.id)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .fixedSize()
                        .accessibilityLabel(L("Deny control for \(request.displayName)"))
                        Button(L("Grant")) {
                            appState.grantRemoteControl(request.id)
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .fixedSize()
                        .help(L("Grants full keyboard and mouse control of your entire Mac"))
                        .accessibilityLabel(L("Grant control to \(request.displayName)"))
                        .accessibilityHint(
                            L("Gives full keyboard and mouse control of your entire Mac, not just the shared window"))
                    }
                    // Queued, not refused — say so, or the auto-grant is a surprise.
                    if appState.pendingAccessibilityGrantRequestID == request.id {
                        Text(L("Waiting for Accessibility permission…"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // Keyboard input lands on the sharer's frontmost app, not
            // confined to the shared window.
            Text(
                L("Granting gives full keyboard and mouse control of your entire Mac — not just the shared window.")
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: PopoverRadius.inner, style: .continuous)
                .fill(Color.blue.opacity(0.12))
        )
    }
}

/// "X is controlling your Mac" banner with a prominent Stop button, shown in
/// the SharingCard while a viewer holds remote control.
struct RemoteControlGranteeBanner: View {
    @EnvironmentObject var appState: AppState
    let grantee: ControlGrantInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cursorarrow.click.badge.clock")
                .font(.subheadline)
                .foregroundStyle(.orange)
            Text(L("\(grantee.displayName) is controlling your Mac"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(L("Stop")) {
                appState.revokeRemoteControl()
            }
            .font(.caption)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.mini)
            .fixedSize()
            .accessibilityLabel(L("Stop Remote Control"))
            .accessibilityHint(L("Immediately revokes the viewer's control of your Mac (⌃⌥.)"))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: PopoverRadius.inner, style: .continuous)
                .fill(Color.orange.opacity(0.16))
        )
    }
}

/// Backed by `AppState.requireViewerApproval` (persisted, propagated to the
/// live server).
struct ApprovalToggle: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Toggle(isOn: $appState.requireViewerApproval) {
            Text(L("Require approval for new viewers"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .accessibilityHint(L("New viewers will see a Connecting prompt until you Accept or Deny"))
    }
}

/// Card shown while viewing a remote peer.
private struct ViewingCard: View {
    @EnvironmentObject var appState: AppState

    private var micTooltip: String {
        guard let chord = appState.micShortcutDisplay else { return L("Toggle mic") }
        return L("Toggle mic (\(chord))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Viewing \(appState.connectedHostname ?? L("peer"))"))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(L("Connected over Tailscale"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            RemoteControlViewerButton()

            Button {
                appState.focusViewerWindow()
            } label: {
                Label(L("Show Window"), systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityHint(L("Brings the viewer window to the front"))

            HStack(spacing: 6) {
                Button {
                    Task { await appState.toggleMic() }
                } label: {
                    Label(
                        appState.isMicOn ? L("Mute Mic") : L("Unmute Mic"),
                        systemImage: appState.isMicOn ? "mic.fill" : "mic.slash"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(micTooltip)
                .accessibilityLabel(appState.isMicOn ? L("Mute microphone") : L("Unmute microphone"))
                .accessibilityHint(L("Toggles voice chat with the sharer"))

                Button {
                    Task { await appState.disconnect() }
                } label: {
                    Text(L("Disconnect")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint(L("Closes the viewer window and ends this session"))
            }

            AudioDevicePickers()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: PopoverRadius.card, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

/// State comes from `AppState.viewerControlState`; the sharer's Grant/Revoke
/// drive the transitions.
private struct RemoteControlViewerButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch appState.viewerControlState {
        case .none:
            // Only offer when the sharer advertised it can inject input.
            if appState.sharerSupportsRemoteControl {
                Button {
                    appState.requestRemoteControl()
                } label: {
                    Label(L("Request Control"), systemImage: "cursorarrow.rays")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L("Ask the sharer to let you control their Mac"))
                .accessibilityHint(L("The sharer must grant control before your input is injected"))
            }
        case .requested:
            Button {
                appState.stopViewerControl()
            } label: {
                Label(L("Requesting Control…"), systemImage: "hourglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L("Waiting for the sharer to grant control"))
        case .controlling:
            HStack(spacing: 6) {
                Label(L("You are controlling this Mac"), systemImage: "cursorarrow.click.badge.clock")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(L("Stop")) {
                    appState.stopViewerControl()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .fixedSize()
                .accessibilityLabel(L("Stop Controlling"))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: PopoverRadius.inner, style: .continuous)
                    .fill(Color.orange.opacity(0.14))
            )
        }
    }
}

/// Hands off to the native `SCContentSharingPicker` running in the
/// picker-helper subprocess; the TCC prompt fires inside the helper, so the
/// main process never preflights Screen Recording.
private struct DisplayPickerSection: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false
    /// SF Symbols at `.body` scale with text size; a hard 16pt slot clips
    /// them at large sizes.
    @ScaledMetric(relativeTo: .body) private var iconSlot: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let why = appState.sharingState.failureReason {
                Text(L("Share failed: \(why)"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            if appState.anotherInstanceSharing {
                // Another Tailscreen instance on this Mac is currently
                // capturing. macOS's `replayd` only allows one SCStream
                // per bundle, so attempting another would fail with
                // -3805 — surface the constraint up-front instead of
                // letting the user discover it through a failed bring-up.
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.body)
                        .frame(width: iconSlot, alignment: .center)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Another Tailscreen is sharing"))
                            .font(.body)
                        Text(L("Stop the other instance first"))
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 34)
                .opacity(0.6)
                .padding(.horizontal, 4)
            } else {
                Button {
                    Task { await appState.presentNativePicker() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.body)
                            .frame(width: iconSlot, alignment: .center)
                            .foregroundStyle(.secondary)
                        Text(L("Choose what to share…"))
                            .font(.body)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(MenuRowHoverBackground(isHovered: isHovered))
                .onHover { isHovered = $0 }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

// MARK: - Menu row

struct MenuRow: View {
    /// See `DisplayPickerSection.iconSlot`.
    @ScaledMetric(relativeTo: .body) private var iconSlot: CGFloat = 16
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
                        .font(.callout)
                        .frame(width: iconSlot, alignment: .center)
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(width: iconSlot, height: 1)
                }

                Text(title)
                    .font(.body)

                Spacer()

                if let shortcut {
                    Text(shortcut)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuRowHoverBackground(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }
}

/// Shared hover highlight, matching macOS Control Center/system menus.
/// `quaternaryLabelColor` adapts to light/dark mode and Reduce Transparency.
struct MenuRowHoverBackground: View {
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: PopoverRadius.inner, style: .continuous)
            .fill(isHovered ? Color(nsColor: .quaternaryLabelColor) : Color.clear)
            .padding(.horizontal, 4)
    }
}
