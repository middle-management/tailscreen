import SwiftCrossUI
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

    public init(
        id: String, hostname: String, tailscaleIP: String, isOnline: Bool,
        sharingName: String? = nil, sharingCaption: String? = nil
    ) {
        self.id = id
        self.hostname = hostname
        self.tailscaleIP = tailscaleIP
        self.isOnline = isOnline
        self.sharingName = sharingName
        self.sharingCaption = sharingCaption
    }

    /// Build a row from a discovered machine plus whatever the metadata sweep
    /// found out about it.
    ///
    /// The chip and caption are derived here rather than at each call site so
    /// the two apps cannot disagree about what "sharing" looks like — the exact
    /// drift this package exists to prevent.
    public init(
        id: String, hostname: String, tailscaleIP: String, isOnline: Bool,
        metadata: TailscreenMetadata?
    ) {
        var name: String?
        var caption: String?
        if let metadata, metadata.isSharing {
            let label = metadata.shareName.isEmpty ? "Sharing" : metadata.shareName
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
            sharingName: name, sharingCaption: caption)
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
                .fill(isExpanded ? HubStyle.rowFillSelected : HubStyle.rowFill))
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

    public init(
        hostname: String, ip: String, isOnline: Bool, sharingCaption: String?,
        onView: @escaping @MainActor @Sendable () -> Void
    ) {
        self.hostname = hostname
        self.ip = ip
        self.isOnline = isOnline
        self.sharingCaption = sharingCaption
        self.onView = onView
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
