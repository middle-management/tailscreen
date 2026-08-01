import SwiftCrossUI

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
    var onOpenLogin: (@MainActor @Sendable () -> Void)?
    /// The sharing half of the hub, when this host can share. `nil` renders a
    /// viewer-only hub — a build with no capture backend, or a screenshot.
    var shareCard: ShareCard?
    /// What to say when discovery found nothing. Both apps mean the same thing
    /// and neither should have to guess at the wording.
    var emptyMessage = "No Tailscreen screens found on your tailnet."

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
        emptyMessage: String = "No Tailscreen screens found on your tailnet.",
        onSelect: @escaping @MainActor @Sendable (String) -> Void,
        onOpenLogin: (@MainActor @Sendable () -> Void)? = nil,
        shareCard: ShareCard? = nil
    ) {
        self.statusLine = statusLine
        self.isPicking = isPicking
        self.screens = screens
        self.loginURL = loginURL
        self.emptyMessage = emptyMessage
        self.onSelect = onSelect
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
                        Text("Screens")
                            .font(.title2)
                            .fontWeight(.bold)
                        TextField("Search screens", text: $searchText)
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

    @ViewBuilder private var listContent: some View {
        if screens.isEmpty {
            Text(emptyMessage)
                .font(.callout)
                .foregroundColor(HubStyle.secondaryText)
                .padding(8)
        } else if visibleScreens.isEmpty {
            Text("No screens match your search.")
                .font(.callout)
                .foregroundColor(HubStyle.secondaryText)
                .padding(8)
        } else {
            VStack(spacing: 6) {
                ForEach(visibleScreens, id: \.id) { screen in
                    SharerRow(
                        hostname: screen.hostname,
                        subtitle: screen.isOnline ? screen.tailscaleIP : "Offline",
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
                            onView: { onSelect(screen.id) })
                    }
                }
            }
        }
    }
}
