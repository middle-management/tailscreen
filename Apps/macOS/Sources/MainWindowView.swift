import AppKit
import SwiftUI

/// Root view of the docked main window — the app's hub. Discovery (the peer
/// list), sign-in, incoming share requests, and identity live here; the
/// menubar popover stays focused on the *sharing session*: status cards,
/// start/stop, viewer approvals, and control requests.
///
/// Layout follows the Tailscale mac app's lead (minus the sidebar — we have
/// exactly one section, so a sidebar would be empty chrome): a hidden title
/// bar whose toolbar carries the app identity on the left and
/// filter / refresh / account on the right, over a single clean content
/// column — share card, a large "Screens" heading with search, and
/// dot + name + IP peer rows.
struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HubHeader()
            Divider()
            if appState.isSwitchingProfile {
                ProfileSwitchingPane()
            } else if appState.tailscaleAuth.isAuthenticated {
                HubView()
            } else {
                WelcomePane()
            }
        }
        .frame(minWidth: 340, minHeight: 460)
        .background(Color(nsColor: .textBackgroundColor))
        // The window's title bar is hidden (see the `Window` scene) and the
        // header extends under it, so the traffic lights float over the
        // header like Tailscale's app.
        .ignoresSafeArea(edges: .top)
        .background(TitlebarConfigurator())
        .onAppear {
            // Environment actions are only reachable from view context, so
            // stash the scene-opening closure where AppKit callers (menu
            // items, the menubar popover) can invoke it.
            appState.openMainWindowAction = { openWindow(id: TailscreenApp.mainWindowID) }
        }
    }
}

/// Configures the hosting `NSWindow` for the thick-header look: hidden
/// title text plus an **empty** unified-style `NSToolbar`. That empty
/// toolbar is the standard AppKit mechanism for a tall (~52pt) title-bar
/// region with the traffic lights **vertically centered** in it — there
/// is no public title-bar-height API, and without it the lights hug the
/// window's top-left corner while `HubHeader`'s content centers, reading
/// as misaligned. The toolbar carries no items (our header is ordinary
/// SwiftUI content underneath the transparent title bar), so SwiftUI's
/// toolbar item quirks don't apply.
private struct TitlebarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view isn't in a window yet during make; configure on the
        // next runloop turn, and again on updates (cheap + idempotent).
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.configure(nsView.window)
    }

    @MainActor
    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if window.toolbar == nil {
            // No `showsBaselineSeparator = false` — deprecated (and a
            // no-op) since macOS 15; unified style draws no separator.
            window.toolbar = NSToolbar(identifier: "TailscreenTitlebarSpacer")
        }
        window.toolbarStyle = .unified
    }
}

// MARK: - Header

/// Thick custom header standing in for the title bar (which is hidden):
/// app identity — wordmark + tailnet login — on the left, clear of the
/// floating traffic lights, and the list controls + account menu on the
/// right. A custom bar instead of a SwiftUI `.toolbar` for two reasons:
/// toolbars on a hidden-title-bar window are visually thin, and macOS
/// toolbar item labels drop custom views (the monogram avatar rendered as
/// an empty pill there). `WindowDragGesture` keeps the strip draggable
/// like the title bar it replaces.
private struct HubHeader: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Tailscreen")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                if let profile = appState.tailscaleAuth.userProfile {
                    // Prefer the tailnet (org) name, like Tailscale's own
                    // title bar — it's the distinguishing fact when the
                    // same login is used across several tailnets.
                    Text(
                        verbatim: profile.tailnetName.isEmpty
                            ? profile.loginName : profile.tailnetName
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if appState.tailscaleAuth.isAuthenticated {
                PeerFilterMenu()

                Button {
                    Task { await appState.discoverPeers() }
                } label: {
                    Group {
                        if appState.isDiscovering {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(appState.isDiscovering)
                .help(L("Refresh screens"))
                .accessibilityLabel(L("Refresh available screens"))

            }

            AccountMenu()
        }
        // Clear the traffic lights, which float over the header's left edge.
        .padding(.leading, 84)
        .padding(.trailing, 16)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .gesture(WindowDragGesture())
    }
}

/// The header's account control: the profile list (Tailscale-style
/// multi-account), Add Account…, Settings, and Sign out. Visible whenever
/// there's something to act on: signed in, or signed out with other
/// profiles to switch back to. A first-launch single signed-out profile
/// hides it — the welcome pane's CTA is the only sensible action then.
private struct AccountMenu: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.tailscaleAuth.userProfile != nil || appState.profileStore.profiles.count > 1 {
            AccountMenuButton(appState: appState)
                .frame(width: 28, height: 28)
                .help(L("Account"))
        }
    }
}

/// AppKit-backed account button + menu. A real `NSMenu` because SwiftUI's
/// `Menu` flattens custom row labels to plain text — Tailscale-style
/// two-line rows (avatar, login over tailnet, checkmark on the active
/// account) need `NSMenuItem.attributedTitle` + `.image`. Row semantics
/// mirror Tailscale's: clicking a row switches to that account; holding ⌥
/// swaps a non-active row for "Remove Account…" (the native alternate-item
/// pattern).
private struct AccountMenuButton: NSViewRepresentable {
    let appState: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setAccessibilityLabel(L("Account"))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.appState = appState
        if let profile = appState.tailscaleAuth.userProfile {
            button.image = MonogramAvatar.nsImage(name: profile.displayName, size: 26)
        } else {
            // Signed out but other profiles exist: neutral glyph, the
            // menu is the way back in.
            let symbol = NSImage(
                systemSymbolName: "person.crop.circle", accessibilityDescription: L("Account"))
            button.image = symbol?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var appState: AppState?

        @objc func showMenu(_ sender: NSButton) {
            guard let appState else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false

            for profile in appState.profileStore.profiles {
                let isActive = profile.id == appState.profileStore.activeProfileID
                let item = NSMenuItem(
                    title: profile.hasSignedIn ? profile.menuTitle : L("New account"),
                    action: #selector(switchToAccount(_:)),
                    keyEquivalent: "")
                item.target = self
                item.attributedTitle = Self.rowTitle(for: profile)
                item.image = MonogramAvatar.nsImage(
                    name: profile.displayName.isEmpty ? profile.loginName : profile.displayName,
                    size: 24)
                item.state = isActive ? .on : .off
                item.representedObject = profile.id
                menu.addItem(item)

                if !isActive {
                    // ⌥ swaps the row for its destructive counterpart.
                    let remove = NSMenuItem(
                        title: L("Remove Account…"),
                        action: #selector(removeAccount(_:)),
                        keyEquivalent: "")
                    remove.target = self
                    remove.isAlternate = true
                    remove.keyEquivalentModifierMask = .option
                    remove.representedObject = profile.id
                    menu.addItem(remove)
                }
            }

            menu.addItem(.separator())
            let add = NSMenuItem(
                title: L("Add Account…"), action: #selector(addAccount(_:)), keyEquivalent: "")
            add.target = self
            menu.addItem(add)

            menu.addItem(.separator())
            let settings = NSMenuItem(
                title: L("Settings…"), action: #selector(openSettings(_:)), keyEquivalent: "")
            settings.target = self
            menu.addItem(settings)

            if appState.tailscaleAuth.isAuthenticated {
                menu.addItem(.separator())
                let signOut = NSMenuItem(
                    title: L("Sign out"), action: #selector(performSignOut(_:)), keyEquivalent: "")
                signOut.target = self
                menu.addItem(signOut)
            }

            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 6),
                in: sender)
        }

        /// Two-line row: login (menu font) over tailnet (small, secondary).
        /// The tailnet line is the disambiguator — GitHub logins collide
        /// across orgs. Never-signed-in profiles get the placeholder only.
        private static func rowTitle(for profile: TailscreenProfile) -> NSAttributedString {
            guard profile.hasSignedIn else {
                return NSAttributedString(
                    string: L("New account"),
                    attributes: [
                        .font: NSFont.menuFont(ofSize: 0),
                        .foregroundColor: NSColor.labelColor,
                    ])
            }
            let title = NSMutableAttributedString(
                string: profile.loginName,
                attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor.labelColor,
                ])
            if !profile.tailnetName.isEmpty {
                title.append(
                    NSAttributedString(
                        string: "\n" + profile.tailnetName,
                        attributes: [
                            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                            .foregroundColor: NSColor.secondaryLabelColor,
                        ]))
            }
            return title
        }

        @objc private func switchToAccount(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID, let appState else { return }
            Task { await appState.switchProfile(to: id) }
        }

        @objc private func removeAccount(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID, let appState,
                let profile = appState.profileStore.profiles.first(where: { $0.id == id })
            else { return }
            appState.confirmRemoveProfile(profile)
        }

        @objc private func addAccount(_ sender: NSMenuItem) {
            guard let appState else { return }
            Task { await appState.addAccountAndSignIn() }
        }

        @objc private func openSettings(_ sender: NSMenuItem) {
            appState?.presentSettings()
        }

        @objc private func performSignOut(_ sender: NSMenuItem) {
            guard let appState else { return }
            Task { await appState.signOut() }
        }
    }
}

// MARK: - Profile switching

/// Interstitial shown while `AppState.switchProfile` tears one node down
/// and silently restores the next profile's session. Without it the gap
/// renders the signed-out welcome pane — alarming when the target
/// profile is, in fact, still logged in. The header stays interactive
/// above this pane, so the account menu remains an escape hatch.
private struct ProfileSwitchingPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(switchingText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var switchingText: String {
        let target = appState.profileStore.activeProfile
        return target.hasSignedIn
            ? L("Switching to \(target.menuTitle)…")
            : L("Switching accounts…")
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
                .font(.system(.title2, design: .rounded, weight: .semibold))

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

/// One scrolling content column, Tailscale-style: share card up top, then
/// the screens list with its heading and search field.
private struct HubView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PendingRequestsBanner()
                ShareStatusSection()
                PeerListSection()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Share section (window-side status + start)

/// The window's share module: a titled card with the primary action at
/// idle, and a compact status row while a session is up. Detailed session
/// controls (mic, audio devices, viewer approvals, remote-control requests)
/// deliberately stay in the menubar popover — the sharer tool — so this
/// section stays a status surface with just the primary action.
private struct ShareStatusSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch (appState.sharingState, appState.connectionState) {
            case (.active, _):
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Sharing your screen"))
                            .font(.system(.headline, design: .rounded))
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
                            .font(.system(.headline, design: .rounded))
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
                            .font(.system(.headline, design: .rounded))
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
                        .font(.system(.headline, design: .rounded))
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
                    // Just the action + its one option — a heading here
                    // ("Share your screen") only restated what the button
                    // already says.
                    Button {
                        Task { await appState.presentNativePicker() }
                    } label: {
                        Label(L("Choose what to share…"), systemImage: "macwindow.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    ApprovalToggle()
                        .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 1)
        )
    }

    private var backgroundTint: Color {
        switch (appState.sharingState, appState.connectionState) {
        case (.active, _): return Color.green.opacity(0.12)
        case (_, .viewing): return Color.accentColor.opacity(0.10)
        default: return Color.secondary.opacity(0.06)
        }
    }

    private var viewersText: String {
        let count = appState.currentViewers.count
        if count == 0 { return L("No viewers yet") }
        return count == 1 ? L("1 viewer connected") : L("\(count) viewers connected")
    }
}

// MARK: - Peer list

/// The tailnet screens list: a large heading, a search field, then
/// dot + name + IP rows (the Tailscale device-list idiom). Filter and
/// refresh live in the window toolbar.
private struct PeerListSection: View {
    @EnvironmentObject var appState: AppState
    @State private var didAutoDiscover = false
    @State private var searchText = ""

    /// Peer whose inline detail pane is expanded, if any. Selection is a
    /// UI-only affordance — connecting moved from row-click into the
    /// pane's explicit View Screen button.
    @State private var selectedPeerID: String?

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
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Screens"))
                .font(.system(.title2, design: .rounded, weight: .bold))
                .padding(.top, 6)

            searchField

            content
        }
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

    /// Expand/collapse a peer's detail pane. Expanding kicks a one-peer
    /// share-status fetch so the pane shows the peer's *current* share,
    /// not the last sweep's snapshot.
    private func toggleSelection(_ peer: TailscreenPeer) {
        let expanding = selectedPeerID != peer.id
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedPeerID = expanding ? peer.id : nil
        }
        if expanding {
            Task { await appState.refreshShareStatus(for: peer) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L("Search screens"), text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.6))
        )
        .accessibilityElement(children: .contain)
    }

    /// `appState.filteredPeers` (the persisted filter axes) narrowed
    /// further by the transient search text.
    private var visiblePeers: [TailscreenPeer] {
        guard !searchText.isEmpty else { return appState.filteredPeers }
        return appState.filteredPeers.filter {
            $0.hostname.localizedCaseInsensitiveContains(searchText)
                || $0.dnsName.localizedCaseInsensitiveContains(searchText)
                || $0.tailscaleIP.contains(searchText)
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
                .transition(.opacity)
        } else if visiblePeers.isEmpty {
            // Devices exist but the filter/search hides them all — say so
            // rather than showing the misleading "no devices" empty state.
            Text(L("No screens match your filters"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(height: 28)
                .transition(.opacity)
        } else {
            VStack(spacing: 2) {
                ForEach(visiblePeers) { peer in
                    PeerMenuRow(peer: peer, isExpanded: selectedPeerID == peer.id) {
                        toggleSelection(peer)
                    }
                    if selectedPeerID == peer.id {
                        PeerDetailView(peer: peer)
                            .transition(.opacity)
                    }
                }
            }
            .transition(.opacity)

            let hidden = appState.availablePeers.count - appState.filteredPeers.count
            if hidden > 0 && searchText.isEmpty {
                Text(L("\(hidden) hidden by filters"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
/// Lives in the main window's toolbar.
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
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(
                appState.peerFilter.isActive
                    ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
            )
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
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

/// Placeholder mirroring `PeerMenuRow`'s geometry (same two-line height,
/// dot slot, and padding) shown while the peer list is seeding. Matching
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
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: .quaternaryLabelColor))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .frame(
                        width: 120 * Self.widthFractions[index % Self.widthFractions.count],
                        height: 10)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.6))
                    .frame(width: 90, height: 8)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
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

/// One screens-list row: presence dot + hostname (+ green sharing chip)
/// over the peer's Tailscale IP — the Tailscale device-row idiom.
/// Clicking toggles the inline `PeerDetailView`; the actions (View
/// Screen, Ask to Share) live there as real buttons instead of the old
/// hover-only affordances, which keyboard and VoiceOver users could
/// never reach.
private struct PeerMenuRow: View {
    @EnvironmentObject var appState: AppState
    let peer: TailscreenPeer
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var isHovered = false

    private var shareInfo: TailscreenMetadata? {
        guard let info = appState.peerShareInfo[peer.id], info.isSharing else { return nil }
        return info
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Circle()
                    .fill(
                        peer.isOnline
                            ? Color.green : Color(nsColor: .tertiaryLabelColor)
                    )
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(peer.hostname)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let share = shareInfo {
                            // Fetched share status (`.metadataResponse`) —
                            // the share name is peer data, shown as-is
                            // (parser-clamped); fall back to a generic
                            // caption when the peer didn't name its share.
                            Text(share.shareName.isEmpty ? L("Sharing") : share.shareName)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                        }
                    }
                    Text(peer.isOnline ? peer.tailscaleIP : L("Offline"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(isExpanded ? .degrees(90) : .degrees(0))
                    .opacity(isHovered || isExpanded ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(peer.isOnline ? 1.0 : 0.7)
        .background(MenuRowHoverBackground(isHovered: isHovered || isExpanded))
        .onHover { isHovered = $0 }
        .accessibilityLabel(L("\(peer.hostname), \(peer.isOnline ? L("online") : L("offline"))"))
        .accessibilityHint(L("Shows details and actions"))
    }
}

/// Inline detail pane under a selected peer row: the live share (if any)
/// with its resolution/codec, the primary View Screen / Ask to Share
/// actions, and identity facts (MagicDNS name, IP — both copyable — plus
/// ACL tags and, for offline peers, last-seen).
private struct PeerDetailView: View {
    @EnvironmentObject var appState: AppState
    let peer: TailscreenPeer

    /// Connecting out is only offered while the app is fully idle —
    /// mirroring what the menubar popover allowed before the list moved
    /// here (the status cards owned the popover otherwise).
    private var canConnect: Bool {
        peer.isOnline
            && appState.sharingState == .idle
            && appState.connectionState == .idle
    }

    private var shareInfo: TailscreenMetadata? {
        guard let info = appState.peerShareInfo[peer.id], info.isSharing else { return nil }
        return info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let share = shareInfo {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(share.shareName.isEmpty ? L("Sharing") : share.shareName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: shareCaption(share))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            if peer.isOnline {
                HStack(spacing: 8) {
                    Button {
                        Task { await appState.connectToPeer(peer) }
                    } label: {
                        Label(L("View Screen"), systemImage: "display")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canConnect)
                    .accessibilityHint(L("Connects to view this device's screen"))

                    Button {
                        Task { await appState.requestToShare(from: peer) }
                    } label: {
                        Label(L("Ask to Share"), systemImage: "hand.wave")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canConnect)
                    .help(L("Ask \(peer.hostname) to share their screen"))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                infoRow(label: "DNS", value: dnsDisplay)
                infoRow(label: "IP", value: peer.tailscaleIP)
                if !peer.tags.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(L("Tags"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 34, alignment: .leading)
                        ForEach(peer.tags, id: \.self) { tag in
                            Text(PeerListFilter.displayName(forTag: tag))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary.opacity(0.6)))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if !peer.isOnline, let seen = lastSeenDisplay {
                    Text(L("Last seen \(seen)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
        // Indent under the row's text column so the pane reads as the
        // row's expansion, not a sibling.
        .padding(.leading, 24)
        .padding(.bottom, 4)
    }

    /// "3456 × 2234 · HEVC" — resolution and codec are numbers/brand nouns,
    /// deliberately unlocalized.
    private func shareCaption(_ share: TailscreenMetadata) -> String {
        var caption = "\(share.screenResolution.width) × \(share.screenResolution.height)"
        if let codec = share.videoCodec {
            caption += " · \(codec == .hevc ? "HEVC" : "H.264")"
        }
        return caption
    }

    /// MagicDNS name without the FQDN's trailing dot.
    private var dnsDisplay: String {
        peer.dnsName.hasSuffix(".") ? String(peer.dnsName.dropLast()) : peer.dnsName
    }

    /// Relative last-seen for offline peers, when the netmap supplied one
    /// (only the IPN-watcher discovery path does). Unparseable → omitted.
    private var lastSeenDisplay: String? {
        guard let raw = peer.lastSeen else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = iso.date(from: raw)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime]
            date = iso.date(from: raw)
        }
        guard let date else { return nil }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    /// Caption label + selectable monospaced value + a copy button.
    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
            Text(verbatim: value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Copy"))
            .accessibilityLabel(L("Copy"))
            Spacer(minLength: 0)
        }
    }
}
