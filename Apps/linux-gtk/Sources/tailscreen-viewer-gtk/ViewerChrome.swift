import SwiftCrossUI
import TailscreenProtocol
import TailscreenViewerGtk
import TailscreenViewerTsnet

// Hub-styled chrome for the GTK viewer, mirroring the macOS app's docked-window
// "hub" (MainWindowView): a thick header with the wordmark + a status subtitle,
// a centered content column, a rounded status/login card, and a "Screens" list
// of presence-dot + hostname + IP rows. swift-cross-ui is a SwiftUI *subset*
// (no SF Symbols, `Button` takes only a String label, no `.buttonStyle`), so the
// look is reproduced with primitives: `Circle`/`Capsule`/`RoundedRectangle`
// fills, translucent-gray tints that read on both light and dark GTK themes, and
// `.onTapGesture` for the rich clickable rows.

/// Shared design tokens. Translucent grays (not opaque colors) so cards/rows
/// read as subtle overlays on whatever the GTK theme paints behind them; primary
/// text is left uncolored so it follows the theme's foreground.
enum HubStyle {
    static let headerHeight = 52
    static let contentMaxWidth = 460.0
    static let cardRadius = 12.0
    static let rowRadius = 10.0

    static let secondaryText = Color(white: 0.5)
    static let tertiaryText = Color(white: 0.5, opacity: 0.7)
    static let barFill = Color(white: 0.5, opacity: 0.08)
    static let cardFill = Color(white: 0.5, opacity: 0.10)
    static let cardStroke = Color(white: 0.5, opacity: 0.22)
    static let rowFill = Color(white: 0.5, opacity: 0.10)
    static let rowFillSelected = Color(white: 0.5, opacity: 0.18)
    static let searchFill = Color(white: 0.5, opacity: 0.12)
    static let detailFill = Color(white: 0.5, opacity: 0.06)
    static let online = Color.green
    static let offline = Color(white: 0.5, opacity: 0.55)
    static let chipFill = Color(red: 0.2, green: 0.7, blue: 0.35, opacity: 0.18)
    static let chipText = Color(red: 0.13, green: 0.55, blue: 0.27)
}

extension View {
    /// The rounded, faintly-tinted, hairline-bordered card the hub uses for its
    /// status/login modules. Apply *after* the content's own padding.
    func hubCard(radius: Double = HubStyle.cardRadius) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius).fill(HubStyle.cardFill))
            .overlay {
                RoundedRectangle(cornerRadius: radius).stroke(HubStyle.cardStroke)
            }
    }
}

/// Thick header standing in for a title bar: the "Tailscreen" wordmark over a
/// status subtitle on the left, and (in the picker's picking phase) a Refresh
/// button or, while discovering, a spinner on the right.
struct ViewerHeader: View {
    let subtitle: String
    var showSpinner = false
    var onRefresh: (@MainActor @Sendable () -> Void)?
    /// Multi-account menu (nil ⇒ hidden). `accountName` labels the menu button;
    /// the menu lists `profiles` (active marked) + Add Account.
    var accountName: String?
    var profiles: [ViewerProfile] = []
    var activeProfileID = ""
    var onSelectProfile: (@MainActor @Sendable (String) -> Void)?
    var onAddAccount: (@MainActor @Sendable () -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Tailscreen")
                    .font(.headline)
                    .fontWeight(.bold)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if showSpinner {
                ProgressView()
            }
            if let onRefresh {
                Button("Refresh", action: onRefresh)
            }
            if let accountName, let onSelectProfile, let onAddAccount {
                Menu(accountName) {
                    ForEach(profiles, id: \.id) { profile in
                        Button((profile.id == activeProfileID ? "● " : "   ") + profile.name) {
                            onSelectProfile(profile.id)
                        }
                    }
                    Divider()
                    Button("Add Account…") { onAddAccount() }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Double(HubStyle.headerHeight))
        .frame(maxWidth: .infinity)
        .background(HubStyle.barFill)
    }
}

/// One tailnet screen: a presence dot, the hostname over its IP (or "Offline"),
/// and a disclosure chevron — the mac hub's `PeerMenuRow` idiom. Tapping toggles
/// the inline `SharerDetail` pane (swift-cross-ui `Button` can't host this rich
/// layout, so the whole row is a `.onTapGesture`).
struct SharerRow: View {
    let hostname: String
    let subtitle: String
    let isOnline: Bool
    let isExpanded: Bool
    /// The sharer's live share name when it's actively sharing (from the
    /// metadata sweep) — shown as a green capsule chip. Nil ⇒ not sharing /
    /// status unknown, no chip.
    let sharingName: String?
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isOnline ? HubStyle.online : HubStyle.offline)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hostname)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let sharingName {
                        Text(sharingName)
                            .font(.caption)
                            .foregroundColor(HubStyle.chipText)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(HubStyle.chipFill))
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(HubStyle.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Text(isExpanded ? "⌄" : "›")
                .foregroundColor(HubStyle.tertiaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 46.0)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: HubStyle.rowRadius)
                .fill(isExpanded ? HubStyle.rowFillSelected : HubStyle.rowFill))
        .onTapGesture { onTap() }
    }
}

/// The inline detail pane under an expanded `SharerRow` — the mac hub's
/// `PeerDetailView` idiom, pared to what the viewer knows about a discovered
/// sharer: the primary **View Screen** action plus its host / IP. Indented under
/// the row's text column so it reads as the row's expansion.
struct SharerDetail: View {
    let hostname: String
    let ip: String
    let isOnline: Bool
    /// "Sharing · 1920 × 1080 · HEVC" when the sharer is live, else nil.
    let sharingCaption: String?
    let onView: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sharingCaption {
                HStack(spacing: 6) {
                    Circle()
                        .fill(HubStyle.online)
                        .frame(width: 6, height: 6)
                    Text(sharingCaption)
                        .font(.caption)
                        .foregroundColor(HubStyle.chipText)
                        .lineLimit(1)
                    Spacer()
                }
            }
            if isOnline {
                Button("View Screen", action: onView)
            }
            VStack(alignment: .leading, spacing: 4) {
                detailRow(label: "Host", value: hostname)
                detailRow(label: "IP", value: ip)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(HubStyle.detailFill))
        .padding(.leading, 20)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(HubStyle.tertiaryText)
                .frame(width: 32, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelectionEnabled()
            Spacer()
        }
    }
}

/// Centered spinner + status line — the picker's pre-list phases (bringing the
/// node up, discovering, connecting) and the direct-connect placard.
struct HubStatusPane: View {
    let status: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(status)
                .font(.callout)
                .foregroundColor(HubStyle.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Interactive-login card: the sign-in prompt over the URL to open. Shown while
/// the tsnet node awaits browser login (`PickerModel.loginURL`).
struct HubLoginCard: View {
    let url: String
    var onOpen: (@MainActor @Sendable () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sign in to Tailscale")
                .font(.headline)
                .fontWeight(.semibold)
            Text("Open this URL in your browser to sign in:")
                .font(.caption)
                .foregroundColor(HubStyle.secondaryText)
            Text(url)
                .font(.callout)
                .textSelectionEnabled()
            if let onOpen {
                Button("Open in Browser", action: onOpen)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubCard()
    }
}

/// Centered placard for the session lifecycle before/around video — connecting,
/// awaiting the sharer's approval, declined, or ended — shown in place of (or
/// over) the video. Mirrors the mac viewer's connection placards.
struct SessionPlacard: View {
    let phase: ViewerUIState.SessionPhase
    let host: String

    var body: some View {
        VStack(spacing: 12) {
            if showsSpinner {
                ProgressView()
            }
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundColor(HubStyle.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var showsSpinner: Bool {
        switch phase {
        case .connecting, .awaitingApproval: return true
        default: return false
        }
    }

    private var title: String {
        switch phase {
        case .connecting: return host.isEmpty ? "Connecting…" : "Connecting to \(host)…"
        case .awaitingApproval: return "Waiting for approval"
        case .viewing: return ""
        case .declined: return "The sharer declined your request"
        case .ended: return "The share has ended"
        case .failed(let reason): return reason.isEmpty ? "Connection failed" : reason
        }
    }

    private var detail: String? {
        switch phase {
        case .awaitingApproval: return "The sharer needs to accept you as a viewer."
        case .declined, .ended: return "Returning to the screen list…"
        default: return nil
        }
    }
}

/// Annotation toolbar over the video (shown only when the sharer advertised
/// `ScreenShareCaps.annotations`): a Pen toggle, a row of color swatches, and
/// Undo / Clear. Strokes are drawn on the video and relayed to the sharer.
struct AnnotationToolbar: View {
    let penActive: Bool
    let colors: [Annotation.RGBA]
    let selectedColor: Int
    let onTogglePen: @MainActor @Sendable () -> Void
    let onSelectColor: @MainActor @Sendable (Int) -> Void
    let onUndo: @MainActor @Sendable () -> Void
    let onClear: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(penActive ? "✓ Pen" : "Pen", action: onTogglePen)
            ForEach(Array(colors.enumerated()), id: \.offset) { item in
                Circle()
                    .fill(Color(
                        red: item.element.r, green: item.element.g,
                        blue: item.element.b, opacity: item.element.a))
                    .frame(width: 18, height: 18)
                    .overlay {
                        Circle().stroke(
                            item.offset == selectedColor ? Color.white : Color(white: 0, opacity: 0),
                            style: StrokeStyle(width: 2))
                    }
                    .onTapGesture { onSelectColor(item.offset) }
            }
            Button("Undo", action: onUndo)
            Button("Clear", action: onClear)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .hubCard(radius: 10)
        .padding(12)
    }
}

/// Small translucent stats pill over the video (top-left): resolution + fps.
/// Toggleable. Network stats (bitrate/loss) need portable session counters —
/// a follow-up.
struct StatsHUD: View {
    let width: Int
    let height: Int
    let fps: Int

    var body: some View {
        Text("\(width)×\(height) · \(fps) fps")
            .font(.caption)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0, opacity: 0.55)))
    }
}

/// The picker's content column: optional login card, then either the "Screens"
/// list (picking phase) or a centered status pane (node bring-up / discovery /
/// connecting). Values are passed in so reactivity stays anchored to the App's
/// observed state.
struct PickerContent: View {
    let statusLine: String
    let isPicking: Bool
    let sharers: [DiscoveredSharer]
    let shareInfo: [String: TailscreenMetadata]
    let loginURL: String?
    let onSelect: @MainActor @Sendable (DiscoveredSharer) -> Void
    var onOpenLogin: (@MainActor @Sendable () -> Void)?

    /// Transient search text narrowing the list (the mac hub's search field).
    @State private var searchText = ""
    /// The row whose inline detail pane is open, if any.
    @State private var expandedID: String?

    init(
        statusLine: String,
        isPicking: Bool,
        sharers: [DiscoveredSharer],
        shareInfo: [String: TailscreenMetadata],
        loginURL: String?,
        autoExpandFirst: Bool = false,
        onSelect: @escaping @MainActor @Sendable (DiscoveredSharer) -> Void,
        onOpenLogin: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.statusLine = statusLine
        self.isPicking = isPicking
        self.sharers = sharers
        self.shareInfo = shareInfo
        self.loginURL = loginURL
        self.onSelect = onSelect
        self.onOpenLogin = onOpenLogin
        // Preview/screenshot affordance: open the first row's detail pane so the
        // expanded state is visible without a click.
        _expandedID = State(wrappedValue: autoExpandFirst ? sharers.first?.id : nil)
    }

    /// The green chip label for a row: the sharer's share name (or a generic
    /// "Sharing") when it's actively sharing, else nil (no chip).
    private func sharingName(_ sharer: DiscoveredSharer) -> String? {
        guard let meta = shareInfo[sharer.id], meta.isSharing else { return nil }
        return meta.shareName.isEmpty ? "Sharing" : meta.shareName
    }

    /// The detail-pane caption: "Sharing · 1920 × 1080 · HEVC", or nil.
    private func sharingCaption(_ sharer: DiscoveredSharer) -> String? {
        guard let meta = shareInfo[sharer.id], meta.isSharing else { return nil }
        var caption = meta.shareName.isEmpty ? "Sharing" : meta.shareName
        caption += " · \(meta.screenResolution.width) × \(meta.screenResolution.height)"
        if let codec = meta.videoCodec {
            caption += " · \(codec == .hevc ? "HEVC" : "H.264")"
        }
        return caption
    }

    /// `sharers` narrowed by the search text (hostname or IP substring).
    private var visibleSharers: [DiscoveredSharer] {
        guard !searchText.isEmpty else { return sharers }
        let query = searchText.lowercased()
        return sharers.filter {
            $0.hostname.lowercased().contains(query) || $0.tailscaleIP.contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let loginURL {
                    HubLoginCard(url: loginURL, onOpen: onOpenLogin)
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
        if sharers.isEmpty {
            Text("No Tailscreen screens found on your tailnet.")
                .font(.callout)
                .foregroundColor(HubStyle.secondaryText)
                .padding(8)
        } else if visibleSharers.isEmpty {
            Text("No screens match your search.")
                .font(.callout)
                .foregroundColor(HubStyle.secondaryText)
                .padding(8)
        } else {
            VStack(spacing: 6) {
                ForEach(visibleSharers, id: \.id) { sharer in
                    SharerRow(
                        hostname: sharer.hostname,
                        subtitle: sharer.isOnline ? sharer.tailscaleIP : "Offline",
                        isOnline: sharer.isOnline,
                        isExpanded: expandedID == sharer.id,
                        sharingName: sharingName(sharer),
                        onTap: { expandedID = (expandedID == sharer.id) ? nil : sharer.id })
                    if expandedID == sharer.id {
                        SharerDetail(
                            hostname: sharer.hostname,
                            ip: sharer.tailscaleIP,
                            isOnline: sharer.isOnline,
                            sharingCaption: sharingCaption(sharer),
                            onView: { onSelect(sharer) })
                    }
                }
            }
        }
    }
}

/// The remote-control toolbar, pinned to the bottom over live video. Restyled as
/// a floating pill: the Request/Release button and, if control was declined, the
/// reason. Shown only when the sharer advertised `.remoteControl`.
struct RemoteControlBar: View {
    let buttonLabel: String
    let declinedReason: String?
    let onToggle: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(buttonLabel, action: onToggle)
            if let declinedReason {
                Text("Control declined: \(declinedReason)")
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .hubCard(radius: 10)
        .padding(12)
    }
}
