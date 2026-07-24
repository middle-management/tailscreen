import AppKit
import SwiftUI

/// Corner radius for the main window's card surfaces — mirrors the popover's
/// `PopoverRadius` tiers so the two surfaces stay visually coherent.
private enum HubRadius {
    static let card: CGFloat = 10
}

/// Root view of the docked main window — the app's hub. Discovery (the peer
/// list), sign-in, incoming share requests, and identity live here; the
/// menubar popover stays focused on the *sharing session*: status cards,
/// start/stop, viewer approvals, and control requests.
///
/// The window is a regular SwiftUI `Window` scene (see `TailscreenApp`), so
/// the app behaves like a normal Mac citizen: Dock icon, ⌘Tab, menu bar,
/// full keyboard/VoiceOver reachability without hunting for a popover.
struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if appState.tailscaleAuth.isAuthenticated {
                HubView()
            } else {
                WelcomePane()
            }
        }
        .frame(minWidth: 320, minHeight: 460)
        .onAppear {
            // Environment actions are only reachable from view context, so
            // stash the scene-opening closure where AppKit callers (menu
            // items, the menubar popover) can invoke it.
            appState.openMainWindowAction = { openWindow(id: TailscreenApp.mainWindowID) }
        }
    }
}

// MARK: - Welcome / sign-in

/// Window-sized welcome pane shown until Tailscale sign-in completes.
private struct WelcomePane: View {
    @EnvironmentObject var appState: AppState

    /// The brand artwork (display + stand variant) loaded from the
    /// SwiftPM resource bundle. Cached at type level so we don't decode
    /// the PDF on every re-render.
    private static let brandImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "WelcomeIcon", withExtension: "pdf") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

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
            .frame(width: 80, height: 80)

            Text(L("Welcome to Tailscreen"))
                .font(.title2.weight(.semibold))

            Text(L("Sign in with Tailscale to share and view screens with your peers."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

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
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Hub (authenticated)

private struct HubView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PendingRequestsBanner()
                .padding(.top, 10)
            ShareStatusSection()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            // The peer list absorbs all remaining height (its own frame is
            // greedy) so the identity footer stays pinned to the bottom in
            // every list state — skeleton, empty, and populated alike.
            PeerListSection()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            IdentityFooter()
                .padding(.bottom, 6)
        }
    }
}

// MARK: - Share section (window-side status + start)

/// The window's share module: a prominent "Choose what to share…" button at
/// idle, and a compact status row while a session is up. Detailed session
/// controls (mic, audio devices, viewer approvals, remote-control requests)
/// deliberately stay in the menubar popover — the sharer tool — so this
/// section stays a status surface with just the primary action.
private struct ShareStatusSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch (appState.sharingState, appState.connectionState) {
            case (.active, _):
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Sharing your screen"))
                            .font(.headline)
                        Text(viewersText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(L("Stop Sharing")) {
                        Task { await appState.stopSharing(reason: "MainWindowStopButton") }
                    }
                    .accessibilityHint(L("Disconnects all viewers and ends the screen share"))
                }
                Text(L("Viewer approvals and sharing controls live in the menu bar icon."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case (.starting, _):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
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
            case (_, .viewing):
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
                    Spacer(minLength: 8)
                    Button(L("Disconnect")) {
                        Task { await appState.disconnect() }
                    }
                    .accessibilityHint(L("Closes the viewer window and ends this session"))
                }
            case (_, .connecting):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(appState.connectedHostname.map { L("Connecting to \($0)…") } ?? L("Connecting…"))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            default:
                if appState.anotherInstanceSharing {
                    // Same replayd one-SCStream-per-bundle constraint the
                    // popover surfaces — say it up-front instead of letting
                    // the user discover it through a failed bring-up.
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
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
                    .opacity(0.8)
                } else {
                    Button {
                        Task { await appState.presentNativePicker() }
                    } label: {
                        Label(L("Choose what to share…"), systemImage: "macwindow.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    ApprovalToggle()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: HubRadius.card, style: .continuous)
                .fill(backgroundTint)
        )
    }

    private var backgroundTint: Color {
        switch (appState.sharingState, appState.connectionState) {
        case (.active, _): return Color.green.opacity(0.12)
        case (_, .viewing): return Color.accentColor.opacity(0.12)
        default: return Color.secondary.opacity(0.08)
        }
    }

    private var viewersText: String {
        let count = appState.currentViewers.count
        if count == 0 { return L("No viewers yet") }
        return count == 1 ? L("1 viewer connected") : L("\(count) viewers connected")
    }
}

// MARK: - Peer list

/// The tailnet peer list ("Available screens"), moved here from the menubar
/// popover when the docked window became the app's hub. Unlike the popover
/// variant it isn't row-capped — the scroll area takes whatever height the
/// window gives it.
private struct PeerListSection: View {
    @EnvironmentObject var appState: AppState
    @State private var didAutoDiscover = false

    /// Off until the initial seed has landed: the initial population snaps
    /// into place, and only changes that happen while the user is actually
    /// looking (IPN updates, manual refreshes) animate.
    @State private var animateChanges = false

    /// Row count the list settled on last time, persisted across launches.
    /// While discovery is still seeding, the skeleton reserves this many
    /// row-heights so the list fades in in place instead of a one-line
    /// spinner snapping to an N-row list. (Key name predates the move from
    /// the menubar popover — kept so existing defaults carry over.)
    @AppStorage("menuLastPeerRowCount") private var lastPeerRowCount = 1

    private static let maxSkeletonRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L("AVAILABLE SCREENS"))
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)

                Spacer()

                PeerFilterMenu()

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
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)

            content
        }
        .padding(.bottom, 4)
        // Glide between skeleton → list → empty (and between row counts as
        // IPN updates trickle in) — but only after the initial population
        // has settled (see `animateChanges`).
        .animation(
            animateChanges ? .easeInOut(duration: 0.2) : nil,
            value: appState.filteredPeers
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
            // first discovery's results — `onChange` runs after the view
            // updated for the change, so the initial swap can't batch into
            // an animated transaction.
            if !discovering { animateChanges = true }
        }
        .onChange(of: appState.filteredPeers.count) { _, count in
            if count > 0 { lastPeerRowCount = min(count, Self.maxSkeletonRows) }
        }
    }

    /// Skeleton row count: last settled count, clamped in case defaults
    /// hold junk or the tailnet shrank below one.
    private var skeletonRowCount: Int {
        max(1, min(lastPeerRowCount, Self.maxSkeletonRows))
    }

    /// Show the skeleton while there is nothing to list *and* no settled
    /// answer yet — a discovery pass is in flight, or the first frame
    /// rendered before `onAppear` could kick one off.
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
                .padding(.horizontal, 16)
                .transition(.opacity)
        } else if appState.filteredPeers.isEmpty {
            // Devices exist but the filter hides them all — say so rather
            // than showing the misleading "no devices" empty state.
            Text(L("No screens match your filters"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(height: 28)
                .padding(.horizontal, 16)
                .transition(.opacity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(appState.filteredPeers) { peer in
                        PeerMenuRow(peer: peer) {
                            Task { await appState.connectToPeer(peer) }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.opacity)

            let hidden = appState.availablePeers.count - appState.filteredPeers.count
            if hidden > 0 {
                Text(L("\(hidden) hidden by filters"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
    }
}

/// Header affordance for `PeerListFilter`: a funnel button whose menu
/// carries the hide-offline toggle and one toggle per known ACL tag (plus
/// the explicit Untagged bucket while a tag filter is active). Writes go
/// through `appState.peerFilter` so its `didSet` persists every change.
private struct PeerFilterMenu: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            Toggle(
                L("Hide offline devices"),
                isOn: binding(
                    get: { $0.hideOffline },
                    set: { $0.hideOffline = $1 }))

            Toggle(
                L("Only screens being shared"),
                isOn: binding(
                    get: { $0.onlySharing },
                    set: { $0.onlySharing = $1 }))

            let tags = appState.knownPeerTags
            if !tags.isEmpty {
                Section(L("Filter by Tag")) {
                    ForEach(tags, id: \.self) { tag in
                        Toggle(
                            PeerListFilter.displayName(forTag: tag),
                            isOn: binding(
                                get: { $0.selectedTags.contains(tag) },
                                set: { filter, isOn in
                                    if isOn {
                                        filter.selectedTags.insert(tag)
                                    } else {
                                        filter.selectedTags.remove(tag)
                                    }
                                }))
                    }
                    if !appState.peerFilter.selectedTags.isEmpty {
                        Toggle(
                            L("Untagged"),
                            isOn: binding(
                                get: { $0.includeUntagged },
                                set: { $0.includeUntagged = $1 }))
                    }
                }
            }

            if appState.peerFilter.isActive {
                Divider()
                Button(L("Clear Filters")) { appState.peerFilter = .default }
            }
        } label: {
            Image(
                systemName: appState.peerFilter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(
                appState.peerFilter.isActive
                    ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)
            )
            .frame(width: 14, height: 14)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Filter screens"))
        .accessibilityLabel(L("Filter available screens"))
    }

    /// Binding into `appState.peerFilter` that mutates a copy and writes
    /// the whole struct back, so the `@Published` setter (and its
    /// persistence `didSet`) fires exactly once per toggle.
    private func binding<T>(
        get: @escaping (PeerListFilter) -> T,
        set: @escaping (inout PeerListFilter, T) -> Void
    ) -> Binding<T> {
        Binding(
            get: { get(appState.peerFilter) },
            set: { newValue in
                var filter = appState.peerFilter
                set(&filter, newValue)
                appState.peerFilter = filter
            }
        )
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
        .padding(.horizontal, 12)
        .frame(height: 36)
        .opacity(pulsing ? 0.45 : 1.0)
        // Scoped `.animation(value:)`, NOT a global `withAnimation` in
        // onAppear, so the repeat-forever curve can't leak onto the
        // mounting transaction. The delay keeps the placeholder fully
        // static through a fast seed (the common case).
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

    /// Connecting out is only offered while the app is fully idle —
    /// mirroring what the menubar popover allowed before the list moved
    /// here (the status cards owned the popover otherwise). The list stays
    /// *visible* during a session for reference; rows just don't connect.
    private var canConnect: Bool {
        peer.isOnline
            && appState.sharingState == .idle
            && appState.connectionState == .idle
    }

    private var canRequestShare: Bool {
        peer.isOnline
            && appState.sharingState == .idle
            && appState.connectionState == .idle
    }

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
                        } else if let share = appState.peerShareInfo[peer.id], share.isSharing {
                            // Fetched share status (`.metadataResponse`) —
                            // the share name is peer data, shown as-is
                            // (parser-clamped); fall back to a generic
                            // caption when the peer didn't name its share.
                            Text(share.shareName.isEmpty ? L("Sharing") : share.shareName)
                                .font(.caption)
                                .foregroundStyle(.green)
                                .lineLimit(1)
                                .truncationMode(.tail)
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
            .disabled(!canConnect)
            .opacity(peer.isOnline ? 1.0 : 0.55)
            .background(MenuRowHoverBackground(isHovered: isHovered && canConnect))
            .accessibilityLabel(L("\(peer.hostname), \(peer.isOnline ? L("online") : L("offline"))"))
            .accessibilityHint(canConnect ? L("Connects to view this device's screen") : "")

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
                if isHovered && canConnect {
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
        switch (canRequestShare, canConnect) {
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
                    .padding(.horizontal, 12)
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
