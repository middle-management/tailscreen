import SwiftCrossUI
import TailscreenL10n

/// One person watching this screen, with the sharer's controls for them.
/// Rendered inside `ShareCard`, and public so a host can place it elsewhere —
/// macOS learned the hard way that keeping the roster confined to one surface
/// (its menubar popover) leaves no other path to drop a viewer.
///
/// Two lines on its own row card: person first (dot + name + health), then
/// controls, destructive control last. A one-line layout was tried and lost
/// the name: three buttons truncated the hostname to a few characters.
public struct HubViewerRowView: View {
    let viewer: HubViewerRow

    public init(viewer: HubViewerRow) {
        self.viewer = viewer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Coloured by link health, not presence — always-connected would carry no information.
                Circle()
                    .fill(viewer.health.dotColor)
                    .frame(width: 8, height: 8)
                Text(viewer.label)
                    .fontWeight(.bold)
                    .lineLimit(1)
                if viewer.isGuest {
                    HubGuestChip()
                }
                Spacer()
            }
            // Spelled out, never colour alone, and only when there's something to say.
            if let note = viewer.health.note {
                Text(note)
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
            }
            HStack(spacing: 6) {
                // One remember-affordance per state: with a decision, undo it; with none, make one.
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
                    // A word, not a bare ✕: a lone glyph beside words reads as decoration, not a control.
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

    /// The standing decision, or that one is waiting to be recorded. Guests
    /// never show one — nothing to report. The deferred case exists because
    /// the store is StableNodeID-keyed, which arrives a moment after the
    /// connection does; saying so beats a button that looks inert.
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

/// The share-by-token guest badge — a small purple capsule beside the name,
/// on roster rows and approval prompts alike, so the sharer can tell at a
/// glance which kind of viewer they are deciding about. Matches the macOS
/// roster's badge (and reuses its catalog keys).
public struct HubGuestChip: View {
    public init() {}

    public var body: some View {
        Text(L("Guest"))
            .font(.caption)
            .fontWeight(.bold)
            .foregroundColor(HubStyle.guestChipText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(HubStyle.guestChipFill))
    }
}
