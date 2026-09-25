import SwiftCrossUI
import TailscreenL10n

/// The hub's content column: an optional login card, an optional share card,
/// then either the "Screens" list or a centered status pane.
///
/// Constrained to `HubStyle.contentMaxWidth` and centered, like the macOS
/// window — otherwise a maximized window stretches every row into an
/// unreadable ribbon.
public struct PickerContent: View {
    let statusLine: String
    /// True once discovery has settled and there is a list to show; false while
    /// the node is coming up, discovering, or connecting.
    let isPicking: Bool
    /// The first peer list is being built right now — render placeholder rows
    /// rather than a status line. Distinct from `!isPicking`, also true while
    /// the node is still coming up.
    var isDiscovering = false
    let screens: [HubScreen]
    let loginURL: String?
    /// Handed the tapped screen's `id`, which the host resolves back to
    /// whatever it discovered.
    let onSelect: @MainActor @Sendable (String) -> Void
    /// Ask the tapped screen's machine to start sharing. Nil ⇒ no host support
    /// (or nothing to ask through right now), and no button on any row.
    var onAskToShare: (@MainActor @Sendable (String) -> Void)?
    /// Screen ids with an outstanding ask. A set, not a single id, since
    /// nothing stops asking two machines at once.
    var askingIDs: Set<String> = []
    /// How the last ask to each screen ended, by screen id.
    var askNotes: [String: String] = [:]
    var onOpenLogin: (@MainActor @Sendable () -> Void)?
    /// The sharing half of the hub, when this host can share. `nil` renders a
    /// viewer-only hub — a build with no capture backend, or a screenshot.
    var shareCard: ShareCard?
    /// The share-by-token way in, when this host wires it. Rendered in every
    /// phase, including before sign-in, since joining by token needs no
    /// Tailscale account.
    var joinCard: HubJoinCard?
    /// What to say when discovery found nothing.
    var emptyMessage = L("No Tailscreen screens found on your tailnet.")
    /// A way out of the empty state, when the host has one (the macOS hub's
    /// install link). Nil renders the message by itself.
    var emptyAction: HubAction?
    /// How many discovered screens the host's `PeerListFilter` removed before
    /// handing `screens` over — for the footnote under the list, so filtered
    /// rows don't read as a broken discovery. `screens` is already filtered;
    /// this chrome never filters anything itself.
    var hiddenByFilter = 0

    /// Transient search text narrowing the list (the macOS hub's search field).
    @State private var searchText = ""
    /// The row whose inline detail pane is open, if any.
    @State private var expandedID: String?

    public init(
        statusLine: String,
        isPicking: Bool,
        isDiscovering: Bool = false,
        screens: [HubScreen],
        loginURL: String?,
        autoExpandFirst: Bool = false,
        emptyMessage: String = L("No Tailscreen screens found on your tailnet."),
        emptyAction: HubAction? = nil,
        hiddenByFilter: Int = 0,
        askingIDs: Set<String> = [],
        askNotes: [String: String] = [:],
        onSelect: @escaping @MainActor @Sendable (String) -> Void,
        onAskToShare: (@MainActor @Sendable (String) -> Void)? = nil,
        onOpenLogin: (@MainActor @Sendable () -> Void)? = nil,
        shareCard: ShareCard? = nil,
        joinCard: HubJoinCard? = nil
    ) {
        self.statusLine = statusLine
        self.isPicking = isPicking
        self.isDiscovering = isDiscovering
        self.screens = screens
        self.loginURL = loginURL
        self.emptyMessage = emptyMessage
        self.emptyAction = emptyAction
        self.hiddenByFilter = hiddenByFilter
        self.askingIDs = askingIDs
        self.askNotes = askNotes
        self.onSelect = onSelect
        self.onAskToShare = onAskToShare
        self.onOpenLogin = onOpenLogin
        self.shareCard = shareCard
        self.joinCard = joinCard
        // Preview/screenshot affordance: expand the first row with no click.
        _expandedID = State(wrappedValue: autoExpandFirst ? screens.first?.id : nil)
    }

    /// `screens` narrowed by the search text (hostname or IP substring).
    private var visibleScreens: [HubScreen] {
        guard !searchText.isEmpty else { return screens }
        let query = searchText.lowercased()
        return screens.filter {
            $0.hostname.lowercased().contains(query) || $0.tailscaleIP.contains(query)
        }
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let loginURL {
                    HubLoginCard(url: loginURL, onOpen: onOpenLogin)
                }
                if let shareCard {
                    shareCard
                }
                if let joinCard {
                    joinCard
                }
                if isPicking {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("Screens"))
                            .font(.title2)
                            .fontWeight(.bold)
                        TextField(L("Search screens"), text: $searchText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8).fill(HubStyle.searchFill))
                        listContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if isDiscovering {
                    HubScreenSkeleton()
                } else {
                    HubStatusPane(status: statusLine)
                }
            }
            .frame(maxWidth: HubStyle.contentMaxWidth)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The per-row ask action, or nil for a machine already sharing (View
    /// Screen is the useful action there). `sharingName == nil` also covers
    /// "asked, no reply yet" — offering the ask there errs toward a redundant
    /// banner rather than a feature that silently isn't there.
    ///
    /// A method, not an inline ternary: an optional closure from a
    /// conditional nested in `flatMap` is a shape swift-cross-ui's result
    /// builder fails to typecheck with a useless diagnostic.
    private func askAction(for screen: HubScreen) -> (@MainActor @Sendable () -> Void)? {
        guard let onAskToShare, screen.sharingName == nil else { return nil }
        let id = screen.id
        return { onAskToShare(id) }
    }

    @ViewBuilder private var listContent: some View {
        if screens.isEmpty && hiddenByFilter > 0 {
            // Filter hid every match; "none found" would misdirect debugging.
            Text(L("No screens match your filters."))
                .font(.callout)
                .foregroundColor(HubStyle.secondaryText)
                .padding(8)
        } else if screens.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundColor(HubStyle.secondaryText)
                if let emptyAction {
                    Button(emptyAction.label, action: emptyAction.perform)
                }
            }
            .padding(8)
        } else if visibleScreens.isEmpty {
            Text(L("No screens match your search."))
                .font(.callout)
                .foregroundColor(HubStyle.secondaryText)
                .padding(8)
        } else {
            VStack(spacing: 6) {
                ForEach(visibleScreens, id: \.id) { screen in
                    SharerRow(
                        name: screen.displayName,
                        subtitle: screen.statusLine,
                        isOnline: screen.isOnline,
                        isExpanded: expandedID == screen.id,
                        sharingName: screen.sharingName,
                        onTap: { expandedID = (expandedID == screen.id) ? nil : screen.id })
                    if expandedID == screen.id {
                        SharerDetail(
                            hostname: screen.hostname,
                            ip: screen.tailscaleIP,
                            isOnline: screen.isOnline,
                            sharingCaption: screen.sharingCaption,
                            onView: { onSelect(screen.id) },
                            route: screen.route,
                            latencyMs: screen.latencyMs,
                            tags: screen.tags,
                            onAskToShare: askAction(for: screen),
                            isAsking: askingIDs.contains(screen.id),
                            askNote: askNotes[screen.id])
                    }
                }
                if hiddenByFilter > 0 && searchText.isEmpty {
                    Text(L("\(hiddenByFilter) hidden by filters"))
                        .font(.caption)
                        .foregroundColor(HubStyle.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
