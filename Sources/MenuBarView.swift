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
            WelcomeView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                PendingRequestsBanner()
                StatusSection()
                DevicesSection()
                IdentityFooter()
                Divider().padding(.vertical, 4)
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

                Text(L("Welcome to Tailscreen"))
                    .font(.title3.weight(.semibold))

                Text(L("Sign in with Tailscale to share and view screens with your peers."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)

                Group {
                    if appState.tailscaleAuth.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("Signing in…"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 28)
                    } else {
                        Button {
                            Task { await appState.initializeTailscaleAndLogin() }
                        } label: {
                            Text(L("Sign in with Tailscale"))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityHint(L("Opens Tailscale sign-in in your browser"))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
            .padding(.vertical, 16)

            Divider().padding(.vertical, 4)

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

/// Renders one orange card per incoming request-to-share at the top of
/// the menubar popover. Share routes through `presentNativePicker` —
/// the same path the menubar's own "Start sharing" button uses — so
/// the picker-helper subprocess + TCC handshake always runs.
private struct PendingRequestsBanner: View {
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
private struct ViewersList: View {
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

/// Compact toggle for the "Require approval for new viewers" preference.
/// Backed by `AppState.requireViewerApproval` (persisted in UserDefaults
/// and propagated to the live server). Rendered inside both the
/// SharingCard and the idle DisplayPickerSection so the user can flip it
/// from either context.
private struct ApprovalToggle: View {
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
            SectionHeader(title: L("SHARE"))
                .padding(.top, 2)

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

                ApprovalToggle()
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Devices section

private struct DevicesSection: View {
    @EnvironmentObject var appState: AppState
    @State private var didAutoDiscover = false

    /// Off until the initial seed has landed. The popover-open moment
    /// already has motion of its own (the window materializing), and
    /// animating the first skeleton → list swap on top of it reads as
    /// jitter — so the initial population snaps into place, and only
    /// changes that happen while the user is actually looking (IPN
    /// updates, manual refreshes) animate. Resets every open because
    /// `MenuBarView` re-ids its subtree on appear.
    @State private var animateChanges = false

    /// Row count the list settled on last time, persisted across launches.
    /// While discovery is still seeding, the skeleton reserves this many
    /// row-heights so the popover opens at (almost certainly) its final
    /// size and the list fades in in place, instead of a one-line spinner
    /// snapping to an N-row list.
    @AppStorage("menuLastPeerRowCount") private var lastPeerRowCount = 1

    private static let maxRows = 6
    private static let rowHeight: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L("AVAILABLE SCREENS"))
                    .font(.caption2.weight(.semibold))
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
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 14)
                    }
                }
                .buttonStyle(.plain)
                .disabled(appState.isDiscovering)
                .help(L("Refresh screens"))
                .accessibilityLabel(L("Refresh available screens"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)

            content
        }
        .padding(.bottom, 4)
        // Glide between skeleton → list → empty (and between row counts as
        // IPN updates trickle in) instead of snapping the popover height —
        // but only after the initial population has settled (see
        // `animateChanges`).
        .animation(
            animateChanges ? .easeInOut(duration: 0.2) : nil,
            value: appState.availablePeers
        )
        .animation(
            animateChanges ? .easeInOut(duration: 0.2) : nil,
            value: appState.isDiscovering
        )
        .onAppear {
            guard !didAutoDiscover else { return }
            didAutoDiscover = true
            Task { await appState.discoverPeers() }
        }
        .onChange(of: appState.isDiscovering) { _, discovering in
            // Arm the animations only after the render that showed the
            // first discovery's results. Setting this in the same
            // MainActor turn as the population (e.g. right after
            // `discoverPeers()` returns) can batch both writes into one
            // SwiftUI transaction, which animates the initial swap after
            // all. `onChange` runs after the view updated for the change.
            if !discovering { animateChanges = true }
        }
        .onChange(of: appState.availablePeers.count) { _, count in
            if count > 0 { lastPeerRowCount = min(count, Self.maxRows) }
        }
    }

    /// Skeleton row count: last settled count, clamped in case defaults
    /// hold junk or the tailnet shrank below one.
    private var skeletonRowCount: Int {
        max(1, min(lastPeerRowCount, Self.maxRows))
    }

    /// Show the skeleton while there is nothing to list *and* no settled
    /// answer yet — a discovery pass is in flight, or the popover's first
    /// frame rendered before `onAppear` could kick one off (gating on
    /// `isDiscovering` alone flashed "No Tailscreen devices" for that
    /// first frame). `hasCompletedInitialDiscovery` is the process-wide
    /// "we have a real answer" signal.
    private var showsLoadingSkeleton: Bool {
        appState.availablePeers.isEmpty
            && (appState.isDiscovering || !appState.hasCompletedInitialDiscovery)
    }

    @ViewBuilder
    private var content: some View {
        if showsLoadingSkeleton {
            VStack(spacing: 0) {
                ForEach(0..<skeletonRowCount, id: \.self) { index in
                    PeerRowSkeleton(index: index)
                }
            }
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Looking for screens…"))
        } else if appState.availablePeers.isEmpty {
            Text(L("No Tailscreen devices on your tailnet"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(height: 28)
                .padding(.horizontal, 14)
                .transition(.opacity)
        } else {
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
                height: Self.rowHeight
                    * CGFloat(min(appState.availablePeers.count, Self.maxRows))
            )
            .transition(.opacity)
        }
    }
}

/// Placeholder mirroring `PeerMenuRow`'s geometry (same height, icon slot,
/// and horizontal padding) shown while the peer list is seeding. Matching
/// the real row's layout means the fade from skeleton to content happens
/// in place with no reflow. The name bar pulses gently so the section
/// reads as "loading" rather than frozen.
private struct PeerRowSkeleton: View {
    /// Row position — used to vary the fake-hostname width so a stack of
    /// skeletons looks like a list of different names, not a repeated tile.
    let index: Int
    @State private var pulsing = false

    private static let widthFractions: [CGFloat] = [1.0, 0.72, 0.86, 0.64, 0.9, 0.78]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.body)
                .frame(width: 16, alignment: .center)
                .foregroundStyle(.quaternary)

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor))
                .frame(
                    width: 130 * Self.widthFractions[index % Self.widthFractions.count],
                    height: 10)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .opacity(pulsing ? 0.45 : 1.0)
        // Scoped `.animation(value:)`, NOT a global `withAnimation` in
        // onAppear: the skeleton mounts in the same transaction as the
        // popover's id-swap on open, and `withAnimation` there leaks the
        // repeat-forever curve onto that whole swap — observed as two
        // full popover trees slowly crossfading. The delay keeps the
        // placeholder fully static through a fast seed (the common case);
        // visible pulsing before an almost immediate swap reads as
        // flicker, not as loading.
        .animation(
            .easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(0.35),
            value: pulsing
        )
        .onAppear { pulsing = true }
        .accessibilityHidden(true)
    }
}

private struct PeerMenuRow: View {
    @EnvironmentObject var appState: AppState
    let peer: TailscreenPeer
    let onConnect: () -> Void
    @State private var isHovered = false

    private var canRequestShare: Bool {
        // The peer list is only rendered when sharing/connection state is
        // idle (the SharingCard / ViewingCard / ConnectingCard own the
        // popover otherwise), so a finer check here is redundant — but
        // belt-and-suspenders keeps the hand-wave hidden if the row ever
        // gets shown from a different surface.
        peer.isOnline
            && appState.sharingState == .idle
            && appState.connectionState == .idle
    }

    // Whole-row button. MenuBarExtra(.window) dismisses its popover on any
    // click that doesn't hit an interactive control; making the row itself
    // the button avoids gaps falling through to the popover.
    var body: some View {
        ZStack {
            Button(action: onConnect) {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .font(.body)
                        .frame(width: 16, alignment: .center)
                        .foregroundStyle(peer.isOnline ? .secondary : .tertiary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 1) {
                        // The status dot lives on the hostname line, not in
                        // the outer HStack — there it would center against
                        // the whole two-line block on offline rows and
                        // float between the name and the "Offline" caption,
                        // at a visibly different height than on single-line
                        // online rows.
                        HStack(spacing: 6) {
                            Text(peer.hostname)
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Circle()
                                .fill(
                                    peer.isOnline
                                        ? Color.green : Color(nsColor: .tertiaryLabelColor)
                                )
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        if !peer.isOnline {
                            Text(L("Offline"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer(minLength: 0)

                    // Reserve space the trailing buttons will occupy so
                    // hover-driven appearance doesn't shift the row.
                    Color.clear.frame(width: trailingReservedWidth, height: 1)
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!peer.isOnline)
            .opacity(peer.isOnline ? 1.0 : 0.55)
            .background(MenuRowHoverBackground(isHovered: isHovered && peer.isOnline))
            .accessibilityLabel(L("\(peer.hostname), \(peer.isOnline ? L("online") : L("offline"))"))
            .accessibilityHint(peer.isOnline ? L("Connects to view this device's screen") : "")

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if isHovered && canRequestShare {
                    Button {
                        Task { await appState.requestToShare(from: peer) }
                    } label: {
                        Image(systemName: "hand.wave")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Ask \(peer.hostname) to share their screen"))
                    .accessibilityLabel(L("Request \(peer.hostname) to share"))
                }
                if isHovered && peer.isOnline {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.trailing, 10)
            .allowsHitTesting(isHovered && canRequestShare)
        }
        .onHover { isHovered = $0 }
    }

    /// Width carved out at the right of the row so the (visually-overlaid)
    /// hand-wave button + chevron don't make the hostname appear to shift
    /// when hover begins/ends.
    private var trailingReservedWidth: CGFloat {
        switch (canRequestShare, peer.isOnline) {
        case (true, _): return 36  // hand-wave + chevron
        case (_, true): return 14  // chevron only
        default: return 0
        }
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
                            Text(isHovered ? L("Sign out") : profile.displayName)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(
                                isHovered
                                    ? L("End your Tailscale session")
                                    : profile.loginName
                            )
                            .font(.subheadline)
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
                .background(MenuRowHoverBackground(isHovered: isHovered))
                .onHover { isHovered = $0 }
                .help(L("Sign out of Tailscale"))
                .accessibilityLabel(L("Sign out of Tailscale, signed in as \(profile.displayName)"))
            }
        }
    }
}

// MARK: - Small section header label

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
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

/// Hover highlight shared by every clickable row in the menubar popover —
/// peer rows, the "Choose what to share…" picker entry, the identity
/// footer, and the trailing `MenuRow` entries. The visual matches macOS
/// Control Center / system menus: a soft rounded fill that's clearly
/// visible without competing with selected/active states elsewhere in
/// the popover. `quaternaryLabelColor` adapts to light/dark mode and to
/// the user's "Reduce transparency" setting automatically.
private struct MenuRowHoverBackground: View {
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: PopoverRadius.inner, style: .continuous)
            .fill(isHovered ? Color(nsColor: .quaternaryLabelColor) : Color.clear)
            .padding(.horizontal, 4)
    }
}
