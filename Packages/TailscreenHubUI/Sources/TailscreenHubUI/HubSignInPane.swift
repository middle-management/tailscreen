import SwiftCrossUI
import TailscreenL10n

/// The pre-sign-in hub: what this app is for, the one button that signs in,
/// and — beside it, never behind it — the two things that need no Tailscale
/// account at all.
///
/// A card rather than a bare button because this is the first thing anyone
/// sees and "Tailscreen" over a lone control says nothing about what pressing
/// it does. On failure the same card carries the reason and says "Try again",
/// which keeps the error where the retry is.
///
/// The two accountless paths are the point of the pane, and both are the
/// macOS welcome pane's: **Join a Share…** takes a link somebody sent you,
/// and the share card mints one of your own — a link-only share, no sign-in
/// anywhere in the picture. Gating either behind the sign-in button would put
/// an account in front of the paths that exist precisely because someone
/// hasn't got one.
///
/// Shared between the two swift-cross-ui hosts: the Windows app has shown
/// this pane since its port (as its own `SignInPane`), and the GTK app now
/// shows it instead of bringing a node up unasked at launch.
public struct HubSignInPane: View {
    let title: String
    let message: String
    let buttonLabel: String
    let onSignIn: @MainActor @Sendable () -> Void
    /// A live or offerable share, rendered under the sign-in card. While
    /// idle this is the "share via link" way in; while a link-only share is
    /// running it is the whole sharing view — preview, roster, approvals,
    /// the link — because signed out there is no other surface it could be
    /// on. Nil renders nothing (a host that cannot share, or a preview).
    let shareCard: ShareCard?
    /// The share-by-token way in. Nil renders nothing.
    let joinCard: HubJoinCard?

    public init(
        title: String = L("Welcome to Tailscreen"),
        message: String,
        buttonLabel: String,
        onSignIn: @escaping @MainActor @Sendable () -> Void,
        shareCard: ShareCard? = nil,
        joinCard: HubJoinCard? = nil
    ) {
        self.title = title
        self.message = message
        self.buttonLabel = buttonLabel
        self.onSignIn = onSignIn
        self.shareCard = shareCard
        self.joinCard = joinCard
    }

    public var body: some View {
        // Scrolling, because this pane is no longer just a button: a
        // link-only share renders its whole card here — preview, roster,
        // approvals — and an approval you cannot scroll to is one you
        // cannot answer.
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 12) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text(message)
                        .font(.callout)
                        .foregroundColor(HubStyle.secondaryText)
                        .multilineTextAlignment(.center)
                    Button(buttonLabel, action: onSignIn)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .center)
                .hubCard()
                if let shareCard {
                    shareCard
                }
                if let joinCard {
                    joinCard
                }
            }
            .frame(maxWidth: HubStyle.contentMaxWidth)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
