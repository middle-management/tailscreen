import SwiftCrossUI
import TailscreenL10n

/// One person watching this screen, with the sharer's controls for them.
///
/// Rendered inside `ShareCard`, and public so a host can place it anywhere
/// else it has — which is the lesson macOS learned the expensive way: its
/// viewer roster lived only in the menubar popover, which made *dropping a
/// viewer* the one sharer action with no path outside that one surface. On
/// Linux and Windows there is only the hub window, so this is that surface;
/// keeping the row public means a second one costs nothing.
///
/// The layout puts the label first and the destructive control last, with the
/// remember-decisions between them. A ✕ adjacent to the name would be the
/// easiest thing to hit by accident, and it is the only control here whose
/// effect the person on the other end notices immediately.
public struct HubViewerRowView: View {
    let viewer: HubViewerRow

    public init(viewer: HubViewerRow) {
        self.viewer = viewer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("• \(viewer.label)")
                    .font(.caption)
                    .lineLimit(1)
                if let detail = viewer.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(HubStyle.secondaryText)
                }
                Spacer()
                // Only ever ONE remember-affordance per state, not two greyed
                // ones: with a standing decision the useful action is to undo
                // it, and with none the useful actions are to make one.
                switch viewer.remembered {
                case .none:
                    if let allow = viewer.onAlwaysAllow {
                        Button(L("Always allow"), action: allow)
                    }
                    if let block = viewer.onDenyAndBlock {
                        Button(L("Block"), action: block)
                    }
                case .allowed, .blocked:
                    if let forget = viewer.onForget {
                        Button(L("Forget"), action: forget)
                    }
                }
                if let kick = viewer.onKick {
                    // The label is a word, not a bare ✕. swift-cross-ui renders
                    // buttons as text on both backends, and a lone glyph in a
                    // row of words reads as decoration rather than a control —
                    // and this is the control whose accidental press is felt on
                    // another machine.
                    Button(L("Disconnect"), action: kick)
                }
            }
            if let status = statusLine {
                Text(status)
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
            }
        }
    }

    /// The standing decision, or the fact that one is waiting to be recorded.
    ///
    /// The deferred case exists because the persistent store is keyed by
    /// Tailscale StableNodeID, which arrives from the sharer's own netmap
    /// lookup a moment after the connection does. Saying so beats a button
    /// that appears to do nothing — and beats hiding the button, which would
    /// make it absent exactly when a sharer reaches for it.
    private var statusLine: String? {
        if viewer.rememberIsDeferred {
            return L("Will apply once this peer is identified")
        }
        switch viewer.remembered {
        case .none: return nil
        case .allowed: return L("Always allowed")
        case .blocked: return L("Blocked")
        }
    }
}
