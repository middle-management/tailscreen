import SwiftCrossUI
import TailscreenL10n

/// The hub's content column: an optional login card, an optional share card,
/// then either the "Screens" list or a centered status pane.
///
/// Constrained to `HubStyle.contentMaxWidth` and centered, like the macOS
/// window: the hub is a single column, and letting it stretch across a
/// maximized window turns every row into an unreadable ribbon with the IP a
/// foot away from the hostname it belongs to.
public struct PickerContent: View {
    let statusLine: String
    /// True once discovery has settled and there is a list to show; false while
    /// the node is coming up, discovering, or connecting.
    let isPicking: Bool
    let screens: [HubScreen]
    let loginURL: String?
    /// Handed the tapped screen's `id`, which the host resolves back to
    /// whatever it discovered.
    let onSelect: @MainActor @Sendable (String) -> Void
    /// Ask the tapped screen's machine to start sharing. Nil ⇒ no host support
    /// (or nothing to ask through right now), and no button on any row.
    var onAskToShare: (@MainActor @Sendable (String) -> Void)?
    /// Screen ids with an outstanding ask. A set rather than a single id
    /// because nothing stops a person asking two machines — and a flag that
    /// assumed one would show the second ask's state on the first row.
    var askingIDs: Set<String> = []
    /// How the last ask to each screen ended, by screen id.
    var askNotes: [String: String] = [:]
    var onOpenLogin: (@MainActor @Sendable () -> Void)?
    /// The sharing half of the hub, when this host can share. `nil` renders a
    /// viewer-only hub — a build with no capture backend, or a screenshot.
    var shareCard: ShareCard?
    /// What to say when discovery found nothing. Both apps mean the same thing
    /// and neither should have to guess at the wording.
    var emptyMessage = L("No Tailscreen screens found on your tailnet.")
    /// A way OUT of the empty state, when the host has one — the macOS hub's
    /// install link. Every machine that could appear in an empty list is one
    /// that doesn't run Tailscreen yet, so the message alone is a dead end.
    /// Nil renders the message by itself.
    var emptyAction: HubAction?
    /// How many discovered screens the host's `PeerListFilter` removed before
    /// handing `screens` over. Purely for the footnote under the list: rows that
    /// vanish with no explanation read as a broken discovery, which is the
    /// complaint the macOS hub's identical line answers. `screens` stays the
    /// already-filtered projection — this chrome never filters anything itself.
    var hiddenByFilter = 0

    /// Transient search text narrowing the list (the macOS hub's search field).
    @State private var searchText = ""
    /// The row whose inline detail pane is open, if any.
    @State private var expandedID: String?

    public init(
        statusLine: String,
        isPicking: Bool,
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
        shareCard: ShareCard? = nil
    ) {
        self.statusLine = statusLine
        self.isPicking = isPicking
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
        // Preview/screenshot affordance: open the first row's detail pane so the
        // expanded state is visible without a click.
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

    /// The per-row ask action, or nil when asking this machine makes no sense.
    ///
    /// Withheld from a machine that is ALREADY sharing: the useful action
    /// there is View Screen, and "ask them to do the thing they are doing" is
    /// a banner on somebody's desk for nothing. Note this keys on
    /// `sharingName`, which is nil both for "not sharing" and for "we asked
    /// and got no reply" — offering the ask in the unknown case is the right
    /// way round, because the cost of a redundant ask is one dismissed banner
    /// while the cost of hiding it is a feature that silently isn't there.
    ///
    /// A method rather than an inline ternary because the expression form —
    /// an optional closure produced by a conditional inside a `flatMap` — is
    /// one swift-cross-ui's result builder cannot typecheck, and it fails as
    /// "failed to produce diagnostic for expression" pointing at the whole
    /// property rather than at anything real.
    private func askAction(for screen: HubScreen) -> (@MainActor @Sendable () -> Void)? {
        guard let onAskToShare, screen.sharingName == nil else { return nil }
        let id = screen.id
        return { onAskToShare(id) }
    }

    @ViewBuilder private var listContent: some View {
        if screens.isEmpty && hiddenByFilter > 0 {
            // Machines were found and the filter hid all of them. Saying "none
            // found" here would send someone debugging their tailnet over a
            // toggle they set.
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
