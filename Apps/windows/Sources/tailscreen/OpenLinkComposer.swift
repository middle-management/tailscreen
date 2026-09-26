import SwiftCrossUI
import TailscreenHubUI
import TailscreenL10n

/// The viewer's "Open link on sharer" affordance: a collapsed button that
/// expands into a URL field + Send/Cancel, in the same shape `HubJoinCard`
/// uses for pasting a share link — local `@State` for the draft/error/sent
/// flags, since none of it needs to outlive this view (a fresh session
/// already resets `WindowsViewerInteraction`'s own state).
///
/// Validation lives in `onSend` (`WindowsViewerInteraction.sendLink(_:)`),
/// not here — one place decides what the sharer would accept.
struct OpenLinkComposer: View {
    /// Trims and validates, sends if acceptable. Returns whether it sent.
    let onSend: (String) -> Bool

    @State private var expanded = false
    @State private var input = ""
    @State private var error: String?
    @State private var justSent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if expanded {
                Text(L("Open a Link on the Sharer"))
                    .font(.headline)
                    .fontWeight(.semibold)
                Text(L("The sharer sees the whole link and chooses whether to open it."))
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                TextField(L("https://…"), text: $input)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(HubStyle.searchFill))
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(HubStyle.secondaryText)
                }
                HStack(spacing: 8) {
                    Button(L("Send")) {
                        if onSend(input) {
                            expanded = false
                            input = ""
                            error = nil
                            justSent = true
                        } else {
                            error = L(
                                "That isn't a link the sharer can open. Use a full http:// or https:// address with no spaces."
                            )
                        }
                    }
                    Button(L("Cancel")) {
                        expanded = false
                        input = ""
                        error = nil
                    }
                }
            } else {
                Button(L("Open Link on Sharer…")) {
                    expanded = true
                    input = ""
                    error = nil
                    justSent = false
                }
                if justSent {
                    Text(L("Link sent. The sharer decides whether to open it."))
                        .font(.caption)
                        .foregroundColor(HubStyle.secondaryText)
                }
            }
        }
    }
}
