import SwiftCrossUI
import TailscreenL10n
import TailscreenProtocol

/// One machine in the Screens list. A view model, not a transport type —
/// `DiscoveredSharer` lives in `TailscreenViewerTsnet`, which pulls
/// libtailscale, and this package draws rectangles and needs no Go archive.
public struct HubScreen: Identifiable, Sendable {
    public let id: String
    public let hostname: String
    public let tailscaleIP: String
    public let isOnline: Bool
    /// The sharer's live share name, when actively sharing — the green chip.
    /// Nil covers both "not sharing" and "asked, no answer" — deliberately
    /// drawn the same, since claiming idle when the truth is unknown is worse.
    public let sharingName: String?
    /// "robert's Screen · 1920 × 1080 · HEVC", for the expanded detail pane.
    public let sharingCaption: String?
    /// The path this peer's traffic takes, for the detail pane's Route line.
    public let route: PeerRoute
    /// Round-trip time of the last successful metadata probe, in ms. Nil
    /// means no probe has completed — never "fast".
    public let latencyMs: Int?
    /// Tailscale ACL tags, straight off the netmap.
    public let tags: [String]

    /// The row's second line: a status, not the tailnet IP (which lives in the
    /// expanded detail pane, where it's actually actionable). Sharing isn't
    /// repeated here — it already has the green chip.
    public var statusLine: String { isOnline ? L("Online") : L("Offline") }

    /// The row's title: `hostname` without the `tailscreen-` marker every
    /// installation carries, so it doesn't push the distinguishing part out of
    /// a truncated row. The detail pane's Host line keeps the real hostname.
    public var displayName: String {
        TailscreenInstance.displayName(fromHostname: hostname)
    }

    public init(
        id: String, hostname: String, tailscaleIP: String, isOnline: Bool,
        sharingName: String? = nil, sharingCaption: String? = nil,
        route: PeerRoute = .unknown, latencyMs: Int? = nil, tags: [String] = []
    ) {
        self.id = id
        self.hostname = hostname
        self.tailscaleIP = tailscaleIP
        self.isOnline = isOnline
        self.sharingName = sharingName
        self.sharingCaption = sharingCaption
        self.route = route
        self.latencyMs = latencyMs
        self.tags = tags
    }

    /// Build a row from a discovered machine plus whatever the metadata sweep
    /// found out about it. Chip and caption derived here so the two apps
    /// can't disagree about what "sharing" looks like.
    public init(
        id: String, hostname: String, tailscaleIP: String, isOnline: Bool,
        metadata: TailscreenMetadata?,
        route: PeerRoute = .unknown, latencyMs: Int? = nil, tags: [String] = []
    ) {
        var name: String?
        var caption: String?
        if let metadata, metadata.isSharing {
            let label = metadata.shareName.isEmpty ? L("Sharing") : metadata.shareName
            name = label
            var text =
                label + " · \(metadata.screenResolution.width) × \(metadata.screenResolution.height)"
            if let codec = metadata.videoCodec {
                text += " · \(codec == .hevc ? "HEVC" : "H.264")"
            }
            caption = text
        }
        self.init(
            id: id, hostname: hostname, tailscaleIP: tailscaleIP, isOnline: isOnline,
            sharingName: name, sharingCaption: caption,
            route: route, latencyMs: latencyMs, tags: tags)
    }
}

/// One tailnet screen: a presence dot, the hostname over its IP (or
/// "Offline"), and a disclosure chevron — the macOS hub's `PeerMenuRow` idiom.
/// Tapping toggles the inline `SharerDetail` pane.
///
/// The whole row is a tap target, not a `Button` (which takes only a String
/// label). The primary action is a real button inside the detail pane, for
/// keyboard/screen-reader users.
public struct SharerRow: View {
    /// `HubScreen.displayName` — hostname minus the `tailscreen-` marker.
    let name: String
    let subtitle: String
    let isOnline: Bool
    let isExpanded: Bool
    let sharingName: String?
    let onTap: () -> Void

    public init(
        name: String, subtitle: String, isOnline: Bool, isExpanded: Bool,
        sharingName: String?, onTap: @escaping () -> Void
    ) {
        self.name = name
        self.subtitle = subtitle
        self.isOnline = isOnline
        self.isExpanded = isExpanded
        self.sharingName = sharingName
        self.onTap = onTap
    }

    public var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isOnline ? HubStyle.online : HubStyle.offline)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
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
                .fill(isExpanded ? HubStyle.rowFillSelected : HubStyle.rowFill)
        )
        .onTapGesture { onTap() }
    }
}

/// The inline detail pane under an expanded `SharerRow` — the macOS hub's
/// `PeerDetailView` idiom: the primary View Screen action plus host and IP.
/// Indented under the row's text column so it reads as the row's expansion.
public struct SharerDetail: View {
    let hostname: String
    let ip: String
    let isOnline: Bool
    let sharingCaption: String?
    let onView: @MainActor @Sendable () -> Void
    /// Connection facts shown in the macOS hub's peer-detail pane. Defaulted
    /// so a host or preview that hasn't wired them renders as before.
    let route: PeerRoute
    let latencyMs: Int?
    let tags: [String]
    /// Ask this peer to start sharing. Nil ⇒ absent, never present-and-inert.
    /// Hosts pass nil while the local node is down or this machine is already
    /// busy sharing or watching.
    let onAskToShare: (@MainActor @Sendable () -> Void)?
    /// Set while an ask to this peer is outstanding — the request parks up to
    /// two minutes, so without this the button looks inert and gets pressed again.
    let isAsking: Bool
    /// How the last ask to this peer ended. Shown beside a live Ask button,
    /// not instead of it — a silent revert to resting state is
    /// indistinguishable from an ask that never left.
    let askNote: String?

    public init(
        hostname: String, ip: String, isOnline: Bool, sharingCaption: String?,
        onView: @escaping @MainActor @Sendable () -> Void,
        route: PeerRoute = .unknown,
        latencyMs: Int? = nil,
        tags: [String] = [],
        onAskToShare: (@MainActor @Sendable () -> Void)? = nil,
        isAsking: Bool = false,
        askNote: String? = nil
    ) {
        self.hostname = hostname
        self.ip = ip
        self.isOnline = isOnline
        self.sharingCaption = sharingCaption
        self.onView = onView
        self.route = route
        self.latencyMs = latencyMs
        self.tags = tags
        self.onAskToShare = onAskToShare
        self.isAsking = isAsking
        self.askNote = askNote
    }

    public var body: some View {
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
                HStack(spacing: 8) {
                    Button(L("View Screen"), action: onView)
                    if isAsking {
                        // A word, not a spinner — no indeterminate progress control on both backends.
                        Text(L("Asked — waiting for a reply"))
                            .font(.caption)
                            .foregroundColor(HubStyle.secondaryText)
                    } else if let onAskToShare {
                        Button(L("Ask to Share"), action: onAskToShare)
                    }
                }
                if let askNote, !isAsking {
                    Text(askNote)
                        .font(.caption)
                        .foregroundColor(HubStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                detailRow(label: L("Host"), value: hostname)
                detailRow(label: L("IP"), value: ip)
                if let routeLine {
                    detailRow(label: L("Route"), value: routeLine)
                }
                if !tags.isEmpty {
                    // Stripped of the `tag:` prefix, which every tag carries.
                    detailRow(
                        label: L("Tags"),
                        value: tags.map { $0.hasPrefix("tag:") ? String($0.dropFirst(4)) : $0 }
                            .joined(separator: ", "))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(HubStyle.detailFill))
        .padding(.leading, 20)
    }

    /// The Route line: path first, then how far away it feels. Nil is a real
    /// state (unknown), not a placeholder — never guessed as "Direct".
    /// Latency's tier is spelled out in words (macOS uses a coloured dot;
    /// this package has no tooltip to hide colour-only status in).
    private var routeLine: String? {
        var parts: [String] = []
        switch route {
        case .direct: parts.append(L("Direct"))
        case .relay(let region): parts.append(L("Relayed via \(region.uppercased())"))
        case .unknown: break
        }
        if let latencyMs {
            let tier: String
            switch ConnectionQualityTier.forLatency(ms: latencyMs) {
            case .good: tier = L("good")
            case .fair: tier = L("fair")
            case .poor: tier = L("slow")
            }
            parts.append(L("\(latencyMs) ms (\(tier))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
