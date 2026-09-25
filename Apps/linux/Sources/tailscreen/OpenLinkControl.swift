import SwiftCrossUI
import TailscreenHubUI
import TailscreenL10n

/// "Open Link on Sharer…": a button that reveals an inline composer, never an
/// auto-open (TS-LNK-010 — the sharer's own click is the only thing that ever
/// opens anything). Shown only when the sharer advertised `ScreenShareCaps
/// .openLink` (`ui.openLinkAvailable`).
struct OpenLinkControl: View {
    let isOpen: Bool
    let text: Binding<String>
    let error: String?
    let sent: Bool
    let onOpen: @MainActor @Sendable () -> Void
    let onSend: @MainActor @Sendable () -> Void
    let onCancel: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isOpen {
                Text(L("Open a Link on the Sharer"))
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                HStack(spacing: 8) {
                    TextField(L("https://…"), text: text)
                    Button(L("Send"), action: onSend)
                    Button(L("Cancel"), action: onCancel)
                }
                Text(L("The sharer sees the whole link and chooses whether to open it."))
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                if let error {
                    // HubStyle has no "danger" tone (nothing else needs one);
                    // a plain red reads clearly enough for a one-line inline
                    // validation error.
                    Text(error)
                        .font(.caption)
                        .foregroundColor(Color(red: 0.8, green: 0.2, blue: 0.2))
                }
            } else {
                Button(L("Open Link on Sharer…"), action: onOpen)
                if sent {
                    Text(L("Link sent. The sharer decides whether to open it."))
                        .font(.caption)
                        .foregroundColor(HubStyle.secondaryText)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .hubCard(radius: 10)
    }
}
