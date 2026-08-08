import SwiftCrossUI
import TailscreenL10n
import TailscreenProtocol

/// One machine in the Screens list.
///
/// A view model, not a transport type: `DiscoveredSharer` lives in
/// `TailscreenViewerTsnet`, which pulls TailscaleKit and therefore libtailscale,
/// and a package that only draws rectangles has no business needing a Go
/// archive to compile. Each app maps its own discovery result into this.
public struct HubScreen: Identifiable, Sendable {
    public let id: String
    public let hostname: String
    public let tailscaleIP: String
    public let isOnline: Bool
    /// The sharer's live share name, when it is actively sharing — the green
    /// chip. Nil covers both "not sharing" and "we asked and got no answer",
    /// which are deliberately drawn the same: claiming a machine is idle when
    /// the truth is that it did not reply would be worse than saying nothing.
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

    /// The row's second line.
    ///
    /// Deliberately a STATUS and not the tailnet IP, which is what these rows
    /// used to show while online. macOS puts a status word here and the address
    /// in the expanded detail pane — which is the right split, because that is
    /// where the address is actually actionable (selectable, next to the rest
    /// of the connection facts). A bare `100.122.40.62` on the resting list
    /// reads as debug output, and it is the one line that never changes when
    /// the thing you are watching for — whether the machine is reachable — does.
    ///
    /// Sharing is not repeated here: it already has the green chip, and saying
    /// it twice in one row costs a line and adds nothing.
    public var statusLine: String { isOnline ? L("Online") : L("Offline") }

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
    /// found out about it.
    ///
    /// The chip and caption are derived here rather than at each call site so
    /// the two apps cannot disagree about what "sharing" looks like — the exact
    /// drift this package exists to prevent.
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

/// One tailnet screen: a presence dot, the hostname over its IP (or "Offline"),
/// and a disclosure chevron — the macOS hub's `PeerMenuRow` idiom. Tapping
/// toggles the inline `SharerDetail` pane.
///
/// The whole row is a tap target rather than a `Button` because swift-cross-ui's
/// `Button` takes a String label and cannot host this layout. The primary
/// action inside the detail pane IS a real button, which is what keyboard and
/// screen-reader users reach — the same reason the macOS peer rows use
/// always-visible controls instead of hover affordances.
public struct SharerRow: View {
    let hostname: String
    let subtitle: String
    let isOnline: Bool
    let isExpanded: Bool
    let sharingName: String?
    let onTap: () -> Void

    public init(
        hostname: String, subtitle: String, isOnline: Bool, isExpanded: Bool,
        sharingName: String?, onTap: @escaping () -> Void
    ) {
        self.hostname = hostname
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
                .fill(isExpanded ? HubStyle.rowFillSelected : HubStyle.rowFill)
        )
        .onTapGesture { onTap() }
    }
}

/// The inline detail pane under an expanded `SharerRow` — the macOS hub's
/// `PeerDetailView` idiom, pared to what a client knows about a discovered
/// machine: the primary **View Screen** action plus its host and IP. Indented
/// under the row's text column so it reads as the row's expansion.
public struct SharerDetail: View {
    let hostname: String
    let ip: String
    let isOnline: Bool
    let sharingCaption: String?
    let onView: @MainActor @Sendable () -> Void
    /// The connection facts the macOS hub's peer-detail pane shows: which
    /// path traffic takes, how far away it feels, and what the tailnet says
    /// this machine is. Defaulted so a host that has not wired them yet — or
    /// a preview — renders the pane exactly as before.
    let route: PeerRoute
    let latencyMs: Int?
    let tags: [String]
    /// Ask this peer to start sharing. Nil ⇒ the button is absent, never
    /// present-and-inert — the same convention the roster row's optional
    /// actions follow, and for the same reason: a control that is visible but
    /// does nothing teaches people to distrust every control near it.
    ///
    /// Hosts pass nil while the local node is down (there is nothing to ask
    /// through) or while this machine is already busy sharing or watching.
    let onAskToShare: (@MainActor @Sendable () -> Void)?
    /// Set while an ask to this peer is outstanding. The request parks for up
    /// to two minutes waiting for a person to walk back to their desk, so
    /// without this the button looks like it did nothing and gets pressed
    /// again — which on the far side is a second banner row, not a faster
    /// answer.
    let isAsking: Bool
    /// How the last ask to this peer ended.
    ///
    /// Shown *beside* a live Ask button rather than instead of it: a decline
    /// that silently reverted the row to its resting state is indistinguishable
    /// from an ask that never left, and the honest answer — somebody said no —
    /// is one a person deserves to see before deciding whether to ask again.
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
                        // A word, not a spinner: swift-cross-ui has no
                        // indeterminate progress control on both backends, and
                        // the fact that matters is "they have been asked", not
                        // that something is animating.
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
                    // Stripped of the `tag:` prefix, which every tag carries
                    // and none of them distinguish.
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

    /// The Route line: path first, then how far away it feels.
    ///
    /// Nil while nothing is known — which is a real state, not a placeholder.
    /// The status seed may not have run, or this peer may never have been
    /// contacted, and "Direct" printed on a guess would be worse than a line
    /// that is not there.
    ///
    /// Latency is joined into the SAME line rather than given its own, and the
    /// tier is spelled out in words beside the number. On macOS this is a
    /// coloured dot, which is exactly the thing that page's accessibility rule
    /// forbids on its own: status that reads as colour has to also be readable
    /// as text, and swift-cross-ui has no tooltip to hide it in.
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
