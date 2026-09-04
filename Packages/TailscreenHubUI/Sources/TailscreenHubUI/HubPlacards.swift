import SwiftCrossUI
import TailscreenL10n

import enum TailscreenProtocol.ViewerSessionEndReason
import enum TailscreenProtocol.ViewerSessionPhase

/// Where a viewing session is, for the placard shown before video arrives.
///
/// The list lives in the dependency-free protocol tier alongside the end
/// reasons. The chrome still imports no transport; it and both swift-cross-ui
/// hosts now name one lifecycle instead of maintaining identical enums.
public typealias HubSessionPhase = ViewerSessionPhase

/// Why an ended session ended — the presentation-side mirror of the portable
/// `ViewerCloseReason`, with the deny byte already split by admission context
/// (declined at the gate vs kicked mid-watch), which is the host's call.
///
/// The list itself now lives in the dependency-free tier as
/// `ViewerSessionEndReason`, so the chrome, the GTK app's `ViewerUIState` and
/// the macOS viewer share ONE set of endings instead of three copies that had
/// to be kept in step by hand. This package still depends on no viewer tier —
/// `TailscreenProtocol` is the edge it already had — and the name stays
/// because it is what every call site in the chrome reads as.
public typealias HubSessionEndReason = ViewerSessionEndReason

/// Centered placard for the session lifecycle before or around video —
/// connecting, awaiting the sharer's approval, or ended/failed with the reason.
///
/// Every one of these states is a wait with no picture, and a blank window is
/// the worst possible rendering of a wait: it is indistinguishable from a
/// crash. "Waiting for approval" in particular is a state the viewer can do
/// nothing about and must not mistake for a hang.
///
/// The action slots are optional so each host offers only what it can honor:
/// `onCancel` renders on the connecting/pending phases (ending the dial),
/// `onReconnect` / `onBack` on the ended and failed ones. A host with no list
/// to go back to (the GTK direct-host CLI) passes `onBack: nil` and the button
/// simply is not there.
public struct SessionPlacard: View {
    let phase: HubSessionPhase
    let host: String
    var onReconnect: (@MainActor @Sendable () -> Void)?
    var onBack: (@MainActor @Sendable () -> Void)?
    var onCancel: (@MainActor @Sendable () -> Void)?

    public init(
        phase: HubSessionPhase,
        host: String,
        onReconnect: (@MainActor @Sendable () -> Void)? = nil,
        onBack: (@MainActor @Sendable () -> Void)? = nil,
        onCancel: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.phase = phase
        self.host = host
        self.onReconnect = onReconnect
        self.onBack = onBack
        self.onCancel = onCancel
    }

    public var body: some View {
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
            actionRow
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// The phase's buttons, each present only when the host wired it. Plain
    /// `Button`s — swift-cross-ui has no `buttonStyle`, and native chrome is
    /// the design here anyway.
    @ViewBuilder private var actionRow: some View {
        switch phase {
        case .connecting, .awaitingApproval:
            if let onCancel {
                Button(L("Cancel"), action: onCancel)
            }
        case .ended, .failed:
            if onReconnect != nil || onBack != nil {
                HStack(spacing: 8) {
                    if let onReconnect {
                        Button(L("Reconnect"), action: onReconnect)
                    }
                    if let onBack {
                        Button(L("Back to screens"), action: onBack)
                    }
                }
            }
        case .viewing:
            EmptyView()
        }
    }

    private var showsSpinner: Bool {
        switch phase {
        case .connecting, .awaitingApproval: return true
        default: return false
        }
    }

    /// The peer's name for the ended sentences, with the macOS viewer's same
    /// defensive fallback for a host string that never got filled in.
    private var peerName: String {
        host.isEmpty ? L("peer") : host
    }

    private var title: String {
        switch phase {
        case .connecting: return host.isEmpty ? L("Connecting…") : L("Connecting to \(host)…")
        case .awaitingApproval: return L("Waiting for approval")
        case .viewing: return ""
        case .ended(let reason):
            // The deny-flavored titles reuse the macOS viewer's wording so the
            // same ending never tells a different story per platform.
            switch reason {
            case .sharerStopped, .timedOut, .connectionLost: return L("Session Ended")
            case .declined: return L("Connection Declined")
            case .disconnectedBySharer: return L("Disconnected by Sharer")
            }
        case .failed(let reason): return reason.isEmpty ? L("Connection failed") : reason
        }
    }

    private var detail: String? {
        switch phase {
        case .awaitingApproval: return L("The sharer needs to accept you as a viewer.")
        case .ended(let reason):
            let name = peerName
            switch reason {
            case .sharerStopped: return L("\(name) stopped sharing their screen.")
            case .timedOut: return L("The connection to \(name) went quiet and timed out.")
            case .connectionLost: return L("The connection to \(name) was lost.")
            case .declined: return L("The sharer declined your request to view their screen.")
            case .disconnectedBySharer: return L("The sharer disconnected you from their screen share.")
            }
        default: return nil
        }
    }
}
