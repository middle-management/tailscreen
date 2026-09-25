import SwiftCrossUI
import TailscreenL10n
import TailscreenProtocol

/// The viewer's way into a share-by-token session: a collapsed "Join a
/// Share…" affordance that expands into a paste field + Join.
///
/// Shared because both swift-cross-ui hosts need it and neither has a sheet
/// to put it in; on Windows it sits above sign-in, since joining by token
/// needs no Tailscale account.
///
/// Parsing happens here via `ShareLinkFormat`, the same parser every host's
/// copy buttons produce links with — `onJoin` receives only a plausible bare
/// token. Real validation is the guest dial's; this only screens out obvious
/// non-tokens.
public struct HubJoinCard: View {
    /// Called with the parsed token when Join is pressed on valid input.
    let onJoin: @MainActor @Sendable (String) -> Void

    @State private var expanded = false
    @State private var input = ""
    @State private var inputRejected = false

    public init(onJoin: @escaping @MainActor @Sendable (String) -> Void) {
        self.onJoin = onJoin
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if expanded {
                Text(L("Join a shared screen"))
                    .font(.headline)
                    .fontWeight(.semibold)
                Text(L("Paste a share link or token from the person sharing their screen."))
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                TextField(L("tailscreen: link or token"), text: $input)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(HubStyle.searchFill))
                if inputRejected {
                    // secondaryText, not a danger colour this chrome has none of.
                    Text(L("That doesn't look like a share link or token."))
                        .font(.caption)
                        .foregroundColor(HubStyle.secondaryText)
                }
                Text(
                    L(
                        "You'll join as a guest over an encrypted tunnel; the sharer has to approve you before you see anything."
                    )
                )
                .font(.caption)
                .foregroundColor(HubStyle.secondaryText)
                HStack(spacing: 8) {
                    Button(L("Join")) {
                        guard let token = ShareLinkFormat.token(fromUserInput: input) else {
                            inputRejected = true
                            return
                        }
                        // Collapse before handing over so returning doesn't land on a half-filled form.
                        expanded = false
                        input = ""
                        inputRejected = false
                        onJoin(token)
                    }
                    Button(L("Cancel")) {
                        expanded = false
                        input = ""
                        inputRejected = false
                    }
                }
            } else {
                Button(L("Join a Share…")) { expanded = true }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubCard()
    }
}
