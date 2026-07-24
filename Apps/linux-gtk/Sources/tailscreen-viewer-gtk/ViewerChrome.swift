import SwiftCrossUI
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
    static let online = Color.green
    static let offline = Color(white: 0.5, opacity: 0.55)
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
        }
        .padding(.horizontal, 16)
        .frame(height: HubStyle.headerHeight)
        .frame(maxWidth: .infinity)
        .background(HubStyle.barFill)
    }
}

/// One tailnet screen: a presence dot, the hostname over its IP (or "Offline"),
/// and a chevron — the mac hub's `PeerMenuRow` idiom. The whole row is tappable
/// (swift-cross-ui `Button` can't host this layout).
struct SharerRow: View {
    let hostname: String
    let subtitle: String
    let isOnline: Bool
    let onTap: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isOnline ? HubStyle.online : HubStyle.offline)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(hostname)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(HubStyle.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Text("›")
                .foregroundColor(HubStyle.tertiaryText)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: HubStyle.rowRadius).fill(HubStyle.rowFill))
        .onTapGesture { onTap() }
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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubCard()
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
    let loginURL: String?
    let onSelect: @MainActor @Sendable (DiscoveredSharer) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let loginURL {
                    HubLoginCard(url: loginURL)
                }
                if isPicking {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Screens")
                            .font(.title2)
                            .fontWeight(.bold)
                        if sharers.isEmpty {
                            Text("No Tailscreen screens found on your tailnet.")
                                .font(.callout)
                                .foregroundColor(HubStyle.secondaryText)
                                .padding(8)
                        } else {
                            VStack(spacing: 6) {
                                ForEach(sharers, id: \.id) { sharer in
                                    SharerRow(
                                        hostname: sharer.hostname,
                                        subtitle: sharer.isOnline ? sharer.tailscaleIP : "Offline",
                                        isOnline: sharer.isOnline,
                                        onTap: { onSelect(sharer) })
                                }
                            }
                        }
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
