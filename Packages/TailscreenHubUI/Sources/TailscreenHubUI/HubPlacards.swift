import SwiftCrossUI
import TailscreenL10n

/// Where a viewing session is, for the placard shown before video arrives.
///
/// A chrome-side enum rather than either app's session state: the placard needs
/// to know which of five sentences to show and whether to spin, and giving it a
/// whole session model would tie a UI package to a transport.
public enum HubSessionPhase: Equatable, Sendable {
    case connecting
    case awaitingApproval
    case viewing
    case declined
    case ended
    case failed(String)
}

/// Centered placard for the session lifecycle before or around video —
/// connecting, awaiting the sharer's approval, declined, or ended.
///
/// Every one of these states is a wait with no picture, and a blank window is
/// the worst possible rendering of a wait: it is indistinguishable from a
/// crash. "Waiting for approval" in particular is a state the viewer can do
/// nothing about and must not mistake for a hang.
public struct SessionPlacard: View {
    let phase: HubSessionPhase
    let host: String

    public init(phase: HubSessionPhase, host: String) {
        self.phase = phase
        self.host = host
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
        case .connecting: return host.isEmpty ? L("Connecting…") : L("Connecting to \(host)…")
        case .awaitingApproval: return L("Waiting for approval")
        case .viewing: return ""
        case .declined: return L("The sharer declined your request")
        case .ended: return L("The share has ended")
        case .failed(let reason): return reason.isEmpty ? L("Connection failed") : reason
        }
    }

    private var detail: String? {
        switch phase {
        case .awaitingApproval: return L("The sharer needs to accept you as a viewer.")
        case .declined, .ended: return L("Returning to the screen list…")
        default: return nil
        }
    }
}
