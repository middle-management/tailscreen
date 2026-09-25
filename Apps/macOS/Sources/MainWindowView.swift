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
            // Deliberately the two flags, not `appState.nodePhase`: this app
            // renders a sign-in as a spinner on the card that started it,
            // where other hosts show a status pane for it. See `AppState.nodePhase`.
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
        // Title bar is hidden; header extends under it so traffic lights float over it.
        .ignoresSafeArea(edges: .top)
        .background(TitlebarConfigurator())
        .sheet(isPresented: $appState.joinSheetPresented) {
            JoinShareSheet()
        }
        // `tailscreen:` links land here with the token pre-filled.
        .onOpenURL { url in
            appState.handleOpenURL(url)
        }
        .onAppear {
            // Stash the scene-opening closure where AppKit callers (menu
            // items, the menubar popover) can invoke it.
            appState.openMainWindowAction = { openWindow(id: TailscreenApp.mainWindowID) }
        }
    }
}

/// One paste field for a bare token or `tailscreen:` link, the guest-consent
/// line, and Join. Reachable signed in or out. Pre-dial errors (non-token
/// input) render inline; post-dial errors use the normal connect-failure alert.
private struct JoinShareSheet: View {
    @EnvironmentObject var appState: AppState
    @State private var inputRejected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Join a shared screen"))
                .font(.headline)
            Text(L("Paste a share link or token from the person sharing their screen."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(L("tailscreen: link or token"), text: $appState.joinInput)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit { join() }
            if inputRejected {
                Text(L("That doesn't look like a share link or token."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(
                L(
                    "You'll join as a guest over an encrypted tunnel; the sharer has to approve you before you see anything."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Cancel")) {
                    appState.joinSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button(L("Join")) {
                    join()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    appState.joinInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func join() {
        inputRejected = !appState.joinShare(input: appState.joinInput)
    }
}

/// Hidden title text plus an **empty** unified-style `NSToolbar` — the
/// standard AppKit mechanism for a tall (~52pt) title-bar region with the
/// traffic lights vertically centered (no public title-bar-height API);
/// without it the lights hug the top-left corner while `HubHeader` centers,
/// reading as misaligned.
private struct TitlebarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Not in a window yet during make; configure next runloop turn and on
        // updates (cheap + idempotent).
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
            // No `showsBaselineSeparator = false` — deprecated/no-op since
            // macOS 15; unified style draws no separator.
            window.toolbar = NSToolbar(identifier: "TailscreenTitlebarSpacer")
        }
        window.toolbarStyle = .unified
    }
}

// MARK: - Header

/// Custom header standing in for the hidden title bar. Not a SwiftUI
/// `.toolbar`: those are visually thin here, and toolbar item labels drop
/// custom views (the monogram avatar rendered as an empty pill).
/// `WindowDragGesture` keeps it draggable like the title bar it replaces.
private struct HubHeader: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Tailscreen")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                if let profile = appState.tailscaleAuth.userProfile {
                    // Tailnet name disambiguates one login across several tailnets.
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

            // Outside the signed-in gate: joining by token needs no account.
            Button {
                appState.joinSheetPresented = true
            } label: {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Join a Share…"))
            .accessibilityLabel(L("Join a shared screen with a link or token"))

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
        // minHeight, not height: large text sizes must push the bar taller
        // rather than clip; 52 is the floor that centers the traffic lights.
        .frame(minHeight: 52)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .gesture(WindowDragGesture())
    }
}

/// Visible whenever there's something to act on: signed in, or signed out
/// with other profiles to switch back to. Hidden on a first-launch single
/// signed-out profile, where the welcome pane's CTA is the only action.
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

/// A real `NSMenu` because SwiftUI's `Menu` flattens custom row labels to
/// plain text — two-line rows need `NSMenuItem.attributedTitle` + `.image`.
/// Holding ⌥ swaps a non-active row for "Remove Account…" (native
/// alternate-item pattern).
private struct AccountMenuButton: NSViewRepresentable {
    let appState: AppState
    /// Observed so a landed avatar fetch re-runs `updateNSView` and swaps
    /// the monogram for the real picture.
    @ObservedObject private var avatars = AvatarStore.shared

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
            if let picture = avatars.avatar(for: profile.profilePicURL) {
                button.image = AvatarStore.circular(picture, size: 26)
            } else {
                button.image = MonogramAvatar.nsImage(name: profile.displayName, size: 26)
            }
        } else {
            // Signed out but other profiles exist: neutral glyph.
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
                // Real picture when its fetch has landed (kicked off here on
                // a miss, so the next open has it), else the monogram.
                if let picture = AvatarStore.shared.avatar(for: profile.profilePicURL) {
                    item.image = AvatarStore.circular(picture, size: 24)
                } else {
                    item.image = MonogramAvatar.nsImage(
                        name: profile.displayName.isEmpty ? profile.loginName : profile.displayName,
                        size: 24)
                }
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

        /// Login over tailnet (disambiguates — GitHub logins collide across
        /// orgs). Never-signed-in profiles get the placeholder only.
        private static func rowTitle(for profile: TailscreenProfile) -> NSAttributedString {
            guard profile.hasSignedIn else {
                return NSAttributedString(
                    string: L("New account"),
                    attributes: [
                        .font: NSFont.menuFont(ofSize: 0),
                        .foregroundColor: NSColor.labelColor
                    ])
            }
            let title = NSMutableAttributedString(
                string: profile.loginName,
                attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor.labelColor
                ])
            if !profile.tailnetName.isEmpty {
                title.append(
                    NSAttributedString(
                        string: "\n" + profile.tailnetName,
                        attributes: [
                            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                            .foregroundColor: NSColor.secondaryLabelColor
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

/// Shown while `AppState.switchProfile` tears one node down and restores the
/// next. Without it the gap renders the alarming signed-out welcome pane. The
/// header stays interactive above it as an escape hatch.
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
///
/// One card per way in: the tailnet (sign in once, every Tailscreen shows up
/// by name) and a share link (no sign-in, works both directions, guest
/// approval mandatory) — a link-only share is a whole mode of the app, not a
/// footnote to signing in.
private struct WelcomePane: View {
    @EnvironmentObject var appState: AppState

    /// Cached at type level to avoid decoding the PDF on every re-render.
    /// Marked template so `.foregroundStyle(.secondary)` applies — the PDF's
    /// baked-in black fill was invisible in dark mode.
    private static let brandImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "WelcomeIcon", withExtension: "pdf"),
            let img = NSImage(contentsOf: url)
        else {
            return nil
        }
        img.isTemplate = true
        return img
    }()

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            VStack(spacing: 7) {
                Group {
                    if let brand = Self.brandImage {
                        Image(nsImage: brand)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
                // Smaller than the 80 pt it was as the pane's only
                // ornament: it now shares the column with two cards.
                .frame(width: 52, height: 52)

                Text(L("Welcome to Tailscreen"))
                    .font(.system(.title2, design: .rounded, weight: .semibold))

                Text(L("Share a screen with your tailnet, or with anyone over a link."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TailnetSignInCard()
            ShareLinkCard()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

/// The welcome pane's card shell — the same rounded, tinted, hairlined box
/// `ShareStatusSection` uses in the hub, so the signed-out pane and the
/// signed-in one are visibly the same app.
private struct WelcomeCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 1)
        )
    }
}

/// Lane one: sign in and the tailnet's screens list itself.
private struct TailnetSignInCard: View {
    @EnvironmentObject var appState: AppState

    /// Substitutes the pitch with the last bring-up failure reason, so it
    /// lands on the card whose button retries it rather than only in a
    /// dismissed alert.
    private var bodyCopy: String {
        if let reason = appState.nodePhase.failureReason { return reason }
        return L(
            "Every Tailscreen on your tailnet, listed by name — connect with one click, no link to pass around."
        )
    }

    private var signInLabel: String {
        appState.nodePhase.hasFailed ? L("Try again") : L("Sign in with Tailscale")
    }

    var body: some View {
        WelcomeCard {
            Label {
                Text(L("Your tailnet"))
                    .font(.system(.headline, design: .rounded))
            } icon: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Color.accentColor)
            }

            Text(bodyCopy)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if appState.nodePhase == .startingNode {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("Signing in…"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 28)
                } else {
                    Button {
                        Task { await appState.initializeTailscaleAndLogin() }
                    } label: {
                        Text(signInLabel)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint(L("Opens Tailscale sign-in in your browser"))
                }
            }
            .padding(.top, 2)
        }
    }
}

/// Lane two: the no-account paths, both directions. Joining is inlined
/// (the sheet hop bought nothing here); sharing mints a token, so it stays a
/// button. Both share `AppState.joinInput` with `JoinShareSheet`.
private struct ShareLinkCard: View {
    @EnvironmentObject var appState: AppState
    @State private var inputRejected = false

    private var trimmedInput: String {
        appState.joinInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        WelcomeCard {
            HStack(spacing: 8) {
                Label {
                    Text(L("A share link"))
                        .font(.system(.headline, design: .rounded))
                } icon: {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(L("No account needed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }

            HStack(spacing: 8) {
                TextField(L("tailscreen: link or token"), text: $appState.joinInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit { join() }
                    .onChange(of: appState.joinInput) { _, _ in
                        inputRejected = false  // clear on edit, not on submit
                    }
                Button(L("Join")) {
                    join()
                }
                .disabled(trimmedInput.isEmpty)
                .accessibilityHint(
                    L("Joins a shared screen with a link or token, without signing in"))
            }

            if inputRejected {
                Text(L("That doesn't look like a share link or token."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            switch appState.welcomeLinkShareAction {
            case .offer:
                Button {
                    Task { await appState.presentNativePicker() }
                } label: {
                    Text(L("Share your screen via Link…"))
                        .frame(maxWidth: .infinity)
                }
                .accessibilityHint(
                    L("Shares your screen over a link, without signing in — you approve each guest"))
            case .sharingViaLink:
                Text(L("You're sharing via link — the link and your guests are in the menu bar."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .unavailable:
                EmptyView()
            }

            // A signed-out share failure comes back HERE, not to the hub —
            // without this the dismissed alert was the whole explanation.
            if let why = appState.sharingState.failureReason {
                Text(L("Share failed: \(why)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(L("Guests join over an encrypted tunnel, and the sharer approves every one."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func join() {
        guard !trimmedInput.isEmpty else { return }
        inputRejected = !appState.joinShare(input: appState.joinInput)
    }
}

// MARK: - Hub (authenticated)

/// One scrolling content column, Tailscale-style: share card up top, then
/// the screens list with its heading and search field.
private struct HubView: View {
    var body: some View {
        ScrollView {
            // So `PeerListSection` can keep the keyboard highlight scrolled
            // into view as up/down move it.
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 16) {
                    PendingRequestsBanner()
                    ShareStatusSection()
                    PeerListSection(scrollProxy: proxy)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Share section (window-side status + start)

/// The window's share module: a titled card with the primary action at
/// idle, and the full sharing view while a session is up — the same
/// components as the menubar popover's `SharingCard`, per CLAUDE.md. Only
/// deliberate difference: Stop Sharing sits in the status row here.
private struct ShareStatusSection: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        paneContent
            .recordsDiagnosticSurface(paneName)
    }

    /// Derived from the same pair `paneContent`'s switch branches on, kept
    /// beside it so the two can't drift.
    private var paneName: String {
        switch (appState.sharingState, appState.connectionState) {
        case (.sharing, _): return "Hub/Sharing"
        case (.starting, _): return "Hub/StartingShare"
        case (_, .viewing): return "Hub/Viewing"
        default: return "Hub/Idle"
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch (appState.sharingState, appState.connectionState) {
            case (.sharing, _):
                ActiveShareCard()
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
                // Secondary path back to a viewer window buried under other
                // apps. Small so Disconnect keeps the primary slot.
                Button {
                    appState.focusViewerWindow()
                } label: {
                    Label(L("Show Window"), systemImage: "macwindow")
                }
                .controlSize(.small)
                .accessibilityHint(L("Brings the viewer window to the front"))
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
                // A failed start says so above the retry button; the alert is
                // dismissed and gone.
                if let why = appState.sharingState.failureReason {
                    Text(L("Share failed: \(why)"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if appState.anotherInstanceSharing {
                    // replayd's one-SCStream-per-bundle constraint, said
                    // up-front rather than discovered via a failed bring-up.
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
        case (.sharing, _): return Color.green.opacity(0.12)
        case (_, .viewing): return Color.accentColor.opacity(0.10)
        default: return Color.secondary.opacity(0.06)
        }
    }
}

/// The window's live-share card: the same sharing view the menubar popover
/// shows. Its own view since it's by far the longest branch of
/// `ShareStatusSection`'s switch.
private struct ActiveShareCard: View {
    @EnvironmentObject var appState: AppState

    /// This card is as wide as the window, so it states a height and lets the
    /// thumbnail derive its width from the shared display's aspect. 120pt
    /// keeps the roster/link controls above the fold at the default window size.
    private static let previewHeight: CGFloat = 120

    private var viewersText: String {
        let count = appState.currentViewers.count
        if count == 0 { return L("No viewers yet") }
        return count == 1 ? L("1 viewer connected") : L("\(count) viewers connected")
    }

    /// Own line under the viewer count, not joined to it: the joined form
    /// wrapped mid-measurement at the default window width.
    private var resolutionText: String? {
        guard let res = appState.metadataService.currentMetadata?.screenResolution else {
            return nil
        }
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
                    Text(L("Sharing your screen"))
                        .font(.system(.headline, design: .rounded))
                    Text(viewersText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let resolutionText {
                        Text(verbatim: resolutionText)  // digits + × — nothing to translate
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button(L("Stop Sharing")) {
                    Task {
                        AppDiagnostics.action(
                            .actionShareStop, ["surface": .string("MainWindow")])
                        await appState.stopSharing(reason: "MainWindowStopButton")
                    }
                }
                .accessibilityHint(L("Disconnects all viewers and ends the screen share"))
            }
            if appState.notificationsDenied {
                NotificationsOffNotice()
            }
            // Decision surfaces, shared with the menubar popover — approvals
            // shouldn't require leaving the window.
            if !appState.pendingViewers.isEmpty {
                PendingViewersList(viewers: appState.pendingViewers)
            }
            if let grantee = appState.controlGrantee {
                RemoteControlGranteeBanner(grantee: grantee)
            }
            if !appState.controlRequests.isEmpty {
                ControlRequestsList(requests: appState.controlRequests)
            }
            if !appState.linkOffers.isEmpty {
                LinkOffersList(offers: appState.linkOffers)
            }
            SharePreviewThumbnail(height: Self.previewHeight)
            ShareSessionControls(style: .window)
            if !appState.currentViewers.isEmpty {
                Divider()
                ViewersList(viewers: appState.currentViewers)
            }
            // The approval toggle governs tailnet viewers; a guest-only
            // share has none (guest approval is mandatory regardless), so
            // showing it would be a switch wired to nothing.
            if !appState.isGuestOnlyShare {
                ApprovalToggle()
            }
            if appState.linkSharingEnabled {
                ShareViaLinkSection()
            }
            AudioDevicePickers()
        }
    }
}

// MARK: - Peer list

/// The tailnet screens list: a large heading, a search field, then
/// dot + name + IP rows (the Tailscale device-list idiom). Filter and
/// refresh live in the window toolbar.
///
/// Keyboard model: ⌘F focuses the search field; ↑/↓ move an accent
/// highlight through the visible rows (from the search field too,
/// Spotlight-style); Return acts on the highlighted row exactly like
/// clicking it; Esc collapses the expanded pane, then clears the search.
/// Only those four keys are claimed — ordinary typing stays with the
/// search field.
private struct PeerListSection: View {
    @EnvironmentObject var appState: AppState
    /// Suppresses the list's glide/expand animations when the user has
    /// asked the system to reduce motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Proxy for the hub's scroll column (owned by `HubView`), used to
    /// keep the keyboard highlight on screen as ↑/↓ move it.
    let scrollProxy: ScrollViewProxy
    @State private var didAutoDiscover = false
    @State private var searchText = ""
    /// Focus handle for the search field — ⌘F's target.
    @FocusState private var searchFieldFocused: Bool

    /// Peer whose inline detail pane is expanded, if any. Selection is a
    /// UI-only affordance — connecting moved from row-click into the
    /// pane's explicit View Screen button.
    @State private var selectedPeerID: String?

    /// Keyboard highlight — the ↑/↓ cursor through `visiblePeers`.
    /// Deliberately separate from `selectedPeerID` (the expanded pane)
    /// and from hover: arrows move it, Return acts on it, and it renders
    /// as an accent tint so it can't be mistaken for the gray hover.
    @State private var highlightedPeerID: String?

    /// The docs site's install page — the empty state's CTA target.
    private static let installPageURL = URL(string: "https://tailscreen.dev/install/")!

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
        // Glide between skeleton/list/empty, only after initial population
        // has settled (see `animateChanges`).
        .animation(listAnimation, value: appState.filteredPeers)
        .animation(listAnimation, value: appState.isDiscovering)
        .onAppear {
            guard !didAutoDiscover else { return }
            didAutoDiscover = true
            Task { await appState.discoverPeers() }
        }
        .onChange(of: appState.isDiscovering) { _, discovering in
            // Arm only after the first discovery's results rendered, so the
            // initial swap can't batch into an animated transaction.
            if !discovering { animateChanges = true }
        }
        .onChange(of: appState.filteredPeers.count) { _, count in
            if count > 0 { lastPeerRowCount = min(count, Self.maxSkeletonRows) }
        }
        // Handlers sit on the section so unhandled presses bubble up from
        // whichever descendant has focus; only these four keys are claimed.
        .onKeyPress(.downArrow) { moveHighlight(by: 1) }
        .onKeyPress(.upArrow) { moveHighlight(by: -1) }
        .onKeyPress(.return) { activateHighlight() }
        .onKeyPress(.escape) { collapseOrClearSearch() }
        .onChange(of: visiblePeers) { _, peers in
            // A highlight pointing at a now-hidden peer would make Return
            // act on something invisible.
            if let id = highlightedPeerID, !peers.contains(where: { $0.id == id }) {
                highlightedPeerID = nil
            }
        }
        .background(
            // Invisible ⌘F target: zero opacity (not `.hidden()`) keeps it in
            // the shortcut resolver's hierarchy; hit-testing off so it can't
            // swallow clicks.
            Button("") { searchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }

    /// Off until initial population has settled, and off under Reduce Motion.
    private var listAnimation: Animation? {
        guard animateChanges, !reduceMotion else { return nil }
        return .easeInOut(duration: 0.2)
    }

    /// Expanding kicks a one-peer share-status fetch so the pane shows the
    /// current share, not the last sweep's snapshot.
    private func toggleSelection(_ peer: TailscreenPeer) {
        let expanding = selectedPeerID != peer.id
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            selectedPeerID = expanding ? peer.id : nil
        }
        if expanding {
            Task { await appState.refreshShareStatus(for: peer) }
        }
    }

    /// Same gate as `PeerMenuRow.canConnect`.
    private func canConnect(_ peer: TailscreenPeer) -> Bool {
        peer.isOnline
            && !appState.sharingState.isLive
            && appState.connectionState == .idle
    }

    /// Clamped at the ends (no wrap — the AppKit list feel). No highlight
    /// yet: enter from the end the arrow moves away from.
    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        let peers = visiblePeers
        guard !peers.isEmpty else { return .ignored }
        let target: TailscreenPeer
        if let current = highlightedPeerID,
            let index = peers.firstIndex(where: { $0.id == current })
        {
            guard peers.indices.contains(index + delta) else { return .handled }
            target = peers[index + delta]
        } else {
            target = delta > 0 ? peers[0] : peers[peers.count - 1]
        }
        highlightedPeerID = target.id
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            scrollProxy.scrollTo(target.id)
        }
        return .handled
    }

    /// No highlight: leave the press alone, so a natively focused control
    /// still gets it.
    private func activateHighlight() -> KeyPress.Result {
        guard let id = highlightedPeerID,
            let peer = visiblePeers.first(where: { $0.id == id })
        else { return .ignored }
        if canConnect(peer) {
            Task { await appState.connectToPeer(peer) }
        } else {
            toggleSelection(peer)
        }
        return .handled
    }

    private func collapseOrClearSearch() -> KeyPress.Result {
        if selectedPeerID != nil {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                selectedPeerID = nil
            }
            return .handled
        }
        if !searchText.isEmpty {
            searchText = ""
            return .handled
        }
        return .ignored
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L("Search screens"), text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
            if !searchText.isEmpty {
                // Real always-visible button, not a hover reveal, for
                // keyboard/VoiceOver discoverability.
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Clear search"))
                .accessibilityLabel(L("Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.6))
        )
        .accessibilityElement(children: .contain)
    }

    /// `appState.filteredPeers` narrowed further by the transient search text.
    private var visiblePeers: [TailscreenPeer] {
        guard !searchText.isEmpty else { return appState.filteredPeers }
        return appState.filteredPeers.filter {
            $0.hostname.localizedCaseInsensitiveContains(searchText)
                || $0.dnsName.localizedCaseInsensitiveContains(searchText)
                || $0.tailscaleIP.contains(searchText)
        }
    }

    /// Clamped in case defaults hold junk or the tailnet shrank below one.
    private var skeletonRowCount: Int {
        max(1, min(lastPeerRowCount, Self.maxSkeletonRows))
    }

    /// Reads `NodeBringUpPhase.discovering` rather than re-deriving "nothing
    /// to list and no settled answer yet" from the two flags.
    private var showsLoadingSkeleton: Bool {
        appState.availablePeers.isEmpty && appState.nodePhase == .discovering
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
            VStack(alignment: .leading, spacing: 4) {
                Text(L("No Tailscreen screens found on your tailnet."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 28)
                Text(L("Screens appear here when their devices are running Tailscreen."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(L("Get Tailscreen for your other devices"), destination: Self.installPageURL)
                    .font(.caption)
            }
            .transition(.opacity)
        } else if appState.filteredPeers.isEmpty {
            // Filter hid everything — distinct from the search case below,
            // since the fix differs.
            Text(L("No screens match your filters."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minHeight: 28)
                .transition(.opacity)
        } else if visiblePeers.isEmpty {
            Text(L("No screens match your search."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minHeight: 28)
                .transition(.opacity)
        } else {
            VStack(spacing: 4) {
                ForEach(visiblePeers) { peer in
                    PeerMenuRow(
                        peer: peer,
                        isExpanded: selectedPeerID == peer.id,
                        isHighlighted: highlightedPeerID == peer.id,
                        onToggle: { toggleSelection(peer) },
                        onConnect: { Task { await appState.connectToPeer(peer) } }
                    )
                    .id(peer.id)  // anchor for scrollProxy.scrollTo
                    if selectedPeerID == peer.id {
                        PeerDetailView(peer: peer)
                            .transition(.opacity)
                    }
                }
            }
            // Tab stop so up/down work without first focusing the search field.
            .focusable()
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

/// Funnel button: hide-offline toggle + one toggle per known ACL tag (plus
/// Untagged while a tag filter is active). Writes go through
/// `appState.peerFilter` so its `didSet` persists every change.
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

    /// Mutates a copy and writes the whole struct back, so the `@Published`
    /// setter (and its persistence `didSet`) fires exactly once per toggle.
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

/// Mirrors `PeerMenuRow`'s geometry so skeleton->content is a fade with no
/// reflow. Pulses gently so the section reads "loading" rather than frozen.
private struct PeerRowSkeleton: View {
    /// Varies the fake-hostname width so a stack of skeletons looks like
    /// different names, not a repeated tile.
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .frame(minHeight: 48)  // matches PeerMenuRow's floor
        .opacity(pulsing ? 0.45 : 1.0)
        // Scoped `.animation(value:)`, not a global `withAnimation`, so the
        // repeat-forever curve can't leak onto the mounting transaction.
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(0.35),
            value: pulsing
        )
        .onAppear { pulsing = !reduceMotion }
        .accessibilityHidden(true)
    }
}

/// Clicking connects when the app is idle and the peer is online; otherwise
/// it toggles the detail pane (`PeerListSection`'s Return-on-highlight mirrors
/// this split). The trailing chevron is a real button that always toggles the
/// pane, reachable by keyboard/VoiceOver.
private struct PeerMenuRow: View {
    @EnvironmentObject var appState: AppState
    let peer: TailscreenPeer
    let isExpanded: Bool
    let isHighlighted: Bool
    let onToggle: () -> Void
    let onConnect: () -> Void
    @State private var isHovered = false

    private var canConnect: Bool {
        peer.isOnline
            && !appState.sharingState.isLive
            && appState.connectionState == .idle
    }

    private var shareInfo: TailscreenMetadata? {
        guard let info = appState.peerShareInfo[peer.id], info.isSharing else { return nil }
        return info
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if canConnect { onConnect() } else { onToggle() }
            } label: {
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
                            Text(peer.displayName)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let share = shareInfo {
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
                }
                .padding(.leading, 12)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("\(peer.displayName), \(peer.isOnline ? L("online") : L("offline"))"))
            .accessibilityHint(
                canConnect
                    ? L("Connects to view this device's screen")
                    : L("Shows details and actions"))

            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(isExpanded ? .degrees(90) : .degrees(0))
                    // minHeight (not maxHeight: .infinity) — inside the
                    // list's ScrollView an unbounded child can propose
                    // infinite height; this keeps the tap target matched
                    // to the row's floor and lets the HStack center it
                    // when the text lines grow.
                    .frame(width: 32)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Show details"))
            .accessibilityLabel(L("Show details"))
        }
        .opacity(peer.isOnline ? 1.0 : 0.7)
        .background(rowBackground)
        .onHover { isHovered = $0 }
    }

    /// Same slot as `MenuRowHoverBackground` (radius-6, 4pt inset), but an
    /// accent tint instead of hover gray — the keyboard cursor must read as
    /// its own state, not a parked mouse.
    @ViewBuilder
    private var rowBackground: some View {
        if isHighlighted {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .padding(.horizontal, 4)
        } else {
            MenuRowHoverBackground(isHovered: isHovered || isExpanded)
        }
    }
}

/// Live share (if any), View Screen / Ask to Share actions, and identity
/// facts (MagicDNS name, IP — both copyable — plus tags and last-seen).
private struct PeerDetailView: View {
    @EnvironmentObject var appState: AppState
    let peer: TailscreenPeer
    /// Scaled, not fixed: at large text sizes a 40pt column truncates labels.
    @ScaledMetric(relativeTo: .caption) private var labelColumnWidth: CGFloat = 40

    private var canConnect: Bool {
        peer.isOnline
            && !appState.sharingState.isLive
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
                    .help(L("Ask \(peer.displayName) to share their screen"))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                CopyableInfoRow(label: "DNS", value: dnsDisplay, labelColumnWidth: labelColumnWidth)
                CopyableInfoRow(
                    label: "IP", value: peer.tailscaleIP, labelColumnWidth: labelColumnWidth)
                if let v6 = peer.tailscaleIPs.first(where: { $0.contains(":") }) {
                    CopyableInfoRow(label: "IPv6", value: v6, labelColumnWidth: labelColumnWidth)
                }
                if let entry = rememberedEntry {
                    HStack(spacing: 6) {
                        Text(L("Access"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: labelColumnWidth, alignment: .leading)
                        Text(entry.policy == .allow ? L("Allowed") : L("Blocked"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(entry.policy == .allow ? Color.green : Color.red)
                        Spacer(minLength: 0)
                    }
                    .help(L("Remembered viewer decision — manage it in Settings → Viewers."))
                }
                if peer.isOnline, let route = routeText {
                    HStack(spacing: 6) {
                        Text(L("Route"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: labelColumnWidth, alignment: .leading)
                        if let quality = qualityColor {
                            Circle()
                                .fill(quality)
                                .frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                        }
                        Text(verbatim: route)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            // Quality dot is decorative; fold its meaning
                            // into the spoken label.
                            .accessibilityLabel(
                                qualityDescription.map { L("\(route), \($0)") } ?? route)
                        Spacer(minLength: 0)
                    }
                    .help(
                        L(
                            "Latency is measured over the current Tailscale path. Relayed connections usually switch to direct once traffic flows."
                        ))
                }
                if !peer.tags.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(L("Tags"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: labelColumnWidth, alignment: .leading)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
        .padding(.leading, 24)  // reads as the row's expansion, not a sibling
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// "Direct · ~23 ms" / "DERP (fra) · ~120 ms"; either half renders alone
    /// when the other is unknown.
    private var routeText: String? {
        var parts: [String] = []
        switch PeerRoute.from(curAddr: peer.curAddr, relay: peer.relay) {
        case .direct: parts.append(L("Direct"))
        case .relay(let region): parts.append(L("DERP (\(region))"))
        case .unknown: break
        }
        if let ms = appState.peerLatencyMs[peer.id] {
            parts.append(L("~\(ms) ms"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var qualityDescription: String? {
        guard let ms = appState.peerLatencyMs[peer.id] else { return nil }
        switch ConnectionQualityTier.forLatency(ms: ms) {
        case .good: return L("Good connection")
        case .fair: return L("Fair connection")
        case .poor: return L("Poor connection")
        }
    }

    /// nil (no dot) until a measurement lands.
    private var qualityColor: Color? {
        guard let ms = appState.peerLatencyMs[peer.id] else { return nil }
        switch ConnectionQualityTier.forLatency(ms: ms) {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .orange
        }
    }

    /// Resolution/codec are numbers/brand nouns — deliberately unlocalized.
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

    /// Keyed by StableNodeID — same as the admission gate, never wire-claimed
    /// identity.
    private var rememberedEntry: PeerAccessEntry? {
        guard let stableID = peer.stableID else { return nil }
        return appState.viewerAccessPolicies.entries.first { $0.stableID == stableID }
    }

    /// Only the IPN-watcher discovery path supplies this. Unparseable -> nil.
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
}

/// Its own view (not a builder func) because the post-copy confirmation
/// (icon flips to a checkmark briefly) is per-row state.
private struct CopyableInfoRow: View {
    let label: String
    let value: String
    let labelColumnWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingCopy = false
    /// Kept so a re-copy extends the confirmation instead of an old sleeper
    /// cutting the new one short.
    @State private var revertTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: label)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: labelColumnWidth, alignment: .leading)
            Text(verbatim: value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(value, forType: .string)
                confirmCopy()
            } label: {
                Image(systemName: confirmingCopy ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(
                        confirmingCopy ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(confirmingCopy ? L("Copied") : L("Copy"))
            .accessibilityLabel(confirmingCopy ? L("Copied") : L("Copy"))
            Spacer(minLength: 0)
        }
    }

    private func confirmCopy() {
        revertTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            confirmingCopy = true
        }
        revertTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                confirmingCopy = false
            }
        }
    }
}
