import AppKit
import CoreAudio
import SwiftUI

/// Corner-radius scale for the menubar popover. Two tiers keep the nested
/// surfaces visually coherent instead of each site picking its own value:
/// `card` for the top-level module cards (sharing / viewing / connecting /
/// request prompts), `inner` for everything nested inside a card or a
/// hoverable row (the preview thumbnail, the pending-viewer sublist, the
/// row hover highlight). Every popover rect uses `.continuous` corners to
/// match macOS system surfaces (Control Center, sheets) rather than the
/// circular default.
private enum PopoverRadius {
    static let card: CGFloat = 10
    static let inner: CGFloat = 6
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
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
                // Second stash site for the main-window opener (see
                // `MainWindowView.onAppear`) — covers the theoretical
                // launch path where the main window never presented.
                appState.openMainWindowAction = { openWindow(id: TailscreenApp.mainWindowID) }
                // Remount without animation. MenuBarExtra(.window) keeps
                // this view alive (and rendering) while the popover is
                // closed, so the pre-open tree can hold stale content; an
                // animated id-swap crossfades that stale tree with the
                // fresh one — seen as ghost rows / doubled headers on
                // open whenever the content changed since last time.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    viewID = UUID()
                }
            }
    }

    @ViewBuilder
    private var mainView: some View {
        if !appState.tailscaleAuth.isAuthenticated {
            SignedOutMenuView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
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
                    L("Settings…"),
                    systemImage: nil,
                    shortcut: "⌘,"
                ) {
                    appState.presentSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                MenuRow(
                    L("Quit Tailscreen"),
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

// MARK: - Pending requests (peer asked us to share)

/// Renders one orange card per incoming request-to-share. Shown at the top
/// of both the menubar popover and the main window's hub. Share routes
/// through `presentNativePicker` — the same path the "Choose what to
/// share…" button uses — so the picker-helper subprocess + TCC handshake
/// always runs.
struct PendingRequestsBanner: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let requests = appState.metadataService.pendingRequests
        // Suppress while the user is already sharing or viewing — the
        // Share button would be disabled and the banner would read as
        // "X wants you to share" while a share is on-screen, which is
        // confusing. Requests stay queued for when state returns to idle.
        let busy = appState.sharingState != .idle || appState.connectionState != .idle
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
                        .disabled(appState.sharingState == .active)
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
                        Text(L("Sharing your screen"))
                            .font(.headline)
                        if !appState.currentViewers.isEmpty {
                            // Pill-shaped viewer count. Small and
                            // unobtrusive — full per-viewer hostname
                            // list still renders below via `ViewersList`.
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

            ApprovalToggle()

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
                            Text(L("Capturing…"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: geo.size.width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: PopoverRadius.inner, style: .continuous))
            }
            .frame(height: previewHeight)

            // Multiple buttons in a 280px popover would truncate ("Unmut…",
            // "Stop Shari…"). Icon-only for Change Source + Draw + Mic;
            // full label only on the destructive action so it stays
            // prominent.
            HStack(spacing: 6) {
                Button {
                    Task { await appState.changeShareSource() }
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isChangingSource)
                .help(L("Change Source…"))
                .accessibilityLabel(L("Change what you're sharing"))
                .accessibilityHint(L("Reopens the picker without disconnecting viewers"))

                Button {
                    appState.toggleSharerOverlay()
                } label: {
                    Image(systemName: appState.isSharerOverlayVisible ? "pencil.slash" : "pencil.tip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(appState.isSharerOverlayVisible ? L("Stop Drawing") : L("Draw"))
                .accessibilityLabel(
                    appState.isSharerOverlayVisible
                        ? L("Stop drawing on screen")
                        : L("Draw on screen"))

                Button {
                    Task { await appState.toggleMic() }
                } label: {
                    Image(systemName: appState.isMicOn ? "mic.fill" : "mic.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(appState.isMicOn ? L("Mute Mic (⌃⌥M)") : L("Unmute Mic (⌃⌥M)"))
                .accessibilityLabel(appState.isMicOn ? L("Mute microphone") : L("Unmute microphone"))
                .accessibilityHint(L("Toggles voice chat with viewers"))

                Button {
                    appState.toggleSystemAudio()
                } label: {
                    Image(systemName: appState.isSystemAudioOn ? "speaker.wave.2.fill" : "speaker.slash")
                        .frame(maxWidth: .infinity)
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
                        ? L("Mute system audio")
                        : L("Share system audio")
                )
                .accessibilityHint(L("Shares your computer's audio with viewers"))

                Button {
                    Task { await appState.stopSharing(reason: "StopSharingButton") }
                } label: {
                    Text(L("Stop Sharing")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .layoutPriority(1)
                .accessibilityHint(L("Disconnects all viewers and ends the screen share"))
            }

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

/// Viewer roster shown inside the SharingCard — one row per connected viewer
/// with a leading health dot (green / yellow / orange) that reflects the
/// server's per-viewer loss attribution: `good`, `degraded` (packet loss this
/// window), or `throttled` (keyframe-only mode because that viewer's link was
/// isolating the session). Hostnames come from the netmap lookup in
/// `TailscaleScreenShareServer`; rows that haven't resolved yet (or whose peer
/// isn't in the netmap) fall back to the raw Tailscale IP, truncated to keep
/// the layout stable. Falls back to a single "No viewers yet" line when empty.
/// Each row carries a trailing ✕ that disconnects that viewer one-time —
/// nothing is remembered, so they can reconnect through the normal admission
/// gate (the persistent variant stays "Deny & Block" on the pending row).
private struct ViewersList: View {
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
                        Text(viewer.hostname ?? viewer.tailscaleIP)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
                        .accessibilityLabel(L("Disconnect \(viewer.hostname ?? viewer.tailscaleIP)"))
                    }
                }
            }
        }
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

/// One row per pending viewer with inline Accept / Deny split buttons.
/// The primary click acts once; each button's attached menu adds the
/// remembered variant — "Always Allow" / "Deny & Block" — which persists
/// the decision under the peer's StableNodeID so future HELLOs skip the
/// prompt (or are silently rejected). Shown in the SharingCard whenever
/// `requireViewerApproval` is on and at least one viewer is waiting for a
/// decision. Hostnames (and the StableNodeID the remembered variants
/// need) may take a moment to resolve via the netmap lookup; the row
/// falls back to the raw Tailscale IP in the gap, and a remembered-allow
/// peer may flash here briefly before auto-admission kicks in.
private struct PendingViewersList: View {
    @EnvironmentObject var appState: AppState
    let viewers: [PendingViewerInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewers) { viewer in
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Text(viewer.hostname ?? viewer.tailscaleIP)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Menu {
                        // Enabled even before the StableNodeID resolves: the
                        // intent is queued and persisted the moment it lands.
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
                    .accessibilityLabel(L("Deny \(viewer.hostname ?? viewer.tailscaleIP)"))
                    Menu {
                        // Enabled even before the StableNodeID resolves: the
                        // intent is queued and persisted the moment it lands.
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
                    .accessibilityLabel(L("Accept \(viewer.hostname ?? viewer.tailscaleIP)"))
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
}

/// One row per viewer asking for remote control, with inline Grant / Deny
/// buttons. Shown in the SharingCard whenever a viewer has requested control.
/// Granting revokes any current grantee (single-holder). Granting is refused
/// with an Accessibility prompt if the app lacks that permission.
private struct ControlRequestsList: View {
    @EnvironmentObject var appState: AppState
    let requests: [ControlRequestInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(requests) { request in
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
            }
            // Whole-Mac scope warning: keyboard input lands on the sharer's
            // frontmost app (not confined to the shared window/app), so the
            // sharer isn't surprised. Stated once at grant time.
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
private struct RemoteControlGranteeBanner: View {
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
            .accessibilityLabel(L("Stop remote control"))
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

/// Compact toggle for the "Require approval for new viewers" preference.
/// Backed by `AppState.requireViewerApproval` (persisted in UserDefaults
/// and propagated to the live server). Rendered inside the SharingCard
/// and the main window's idle share section (plus Settings) — the
/// popover's idle picker row deliberately omits it to stay lean.
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
                .help(L("Toggle mic (⌃⌥M)"))
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

/// Viewer-side remote-control control: request control, show the pending /
/// active state, and stop controlling. State comes from
/// `AppState.viewerControlState`; the sharer's Grant/Revoke drive the
/// transitions. Full input injection needs the sharer's Accessibility grant.
private struct RemoteControlViewerButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        switch appState.viewerControlState {
        case .none:
            // Only offer the request when the sharer advertised it can inject
            // input at all — otherwise the request is silently dropped.
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
                Label(L("Requesting control…"), systemImage: "hourglass")
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
                .accessibilityLabel(L("Stop controlling"))
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

/// Display picker shown when idle. A single button hands off to the macOS
/// native `SCContentSharingPicker` (display / window / single-app /
/// multi-app) running in the picker-helper subprocess. The OS owns the
/// permission flow too — the TCC prompt fires inside the helper on first
/// use, so the main process never preflights Screen Recording.
private struct DisplayPickerSection: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.anotherInstanceSharing {
                // Another Tailscreen instance on this Mac is currently
                // capturing. macOS's `replayd` only allows one SCStream
                // per bundle, so attempting another would fail with
                // -3805 — surface the constraint up-front instead of
                // letting the user discover it through a failed bring-up.
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.body)
                        .frame(width: 16, alignment: .center)
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
                            .frame(width: 16, alignment: .center)
                            .foregroundStyle(.secondary)
                        Text(L("Choose what to share…"))
                            .font(.body)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
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
                        .frame(width: 16, alignment: .center)
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(width: 16, height: 1)
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
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuRowHoverBackground(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }
}

/// Hover highlight shared by every clickable row in the menubar popover
/// and the main window's list rows — peer rows, the "Choose what to
/// share…" picker entry, the identity footer, and the trailing `MenuRow`
/// entries. The visual matches macOS Control Center / system menus: a
/// soft rounded fill that's clearly visible without competing with
/// selected/active states elsewhere. `quaternaryLabelColor` adapts to
/// light/dark mode and to the user's "Reduce transparency" setting
/// automatically.
struct MenuRowHoverBackground: View {
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: PopoverRadius.inner, style: .continuous)
            .fill(isHovered ? Color(nsColor: .quaternaryLabelColor) : Color.clear)
            .padding(.horizontal, 4)
    }
}
