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
/// Two lines on its own row card: the person first (presence dot + full name
/// + connection health), their controls beneath, destructive control last.
/// One line was tried and the name lost: three buttons ate the width and the
/// hostname — the fact the sharer is actually looking for — truncated to a
/// few characters at the hub's default size. A ✕ adjacent to the name would
/// also be the easiest thing to hit by accident, and Disconnect is the only
/// control here whose effect the person on the other end notices immediately.
public struct HubViewerRowView: View {
    let viewer: HubViewerRow

    public init(viewer: HubViewerRow) {
        self.viewer = viewer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Green like the screen list's presence dot, and honestly so:
                // a row exists here only while this person is connected.
                Circle()
                    .fill(HubStyle.online)
                    .frame(width: 8, height: 8)
                Text(viewer.label)
                    .fontWeight(.bold)
                    .lineLimit(1)
                if let detail = viewer.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(HubStyle.secondaryText)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                // Only ever ONE remember-affordance per state, not two greyed
                // ones: with a standing decision the useful action is to undo
                // it, and with none the useful actions are to make one.
                switch viewer.remembered {
                case .none:
                    if let allow = viewer.onAlwaysAllow {
                        Button(L("Always Allow"), action: allow)
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
                Spacer()
            }
            if let status = statusLine {
                Text(status)
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: HubStyle.rowRadius).fill(HubStyle.rowFill))
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
