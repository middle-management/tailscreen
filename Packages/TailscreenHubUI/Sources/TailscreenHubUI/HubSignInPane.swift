import SwiftCrossUI
import TailscreenL10n
import TailscreenProtocol

/// The pre-sign-in hub: one card per way in — the tailnet (sign in once, see
/// every Tailscreen by name) and a share link (no sign-in, both directions,
/// mandatory guest approval), not variants of each other. Matches the macOS
/// welcome pane's split, card for card.
///
/// Difference from macOS: a running link-only share doesn't appear here at
/// all — the host swaps this pane for the sharing view outright. `shareNote`
/// is what a *failed* start says, beside the retry button.
public struct HubSignInPane: View {
    let title: String
    let subtitle: String
    /// The tailnet card's body copy: the pitch by default, or whatever went
    /// wrong (failed bring-up, sign-in needing the browser again).
    let tailnetMessage: String
    let signInLabel: String
    let onSignIn: @MainActor @Sendable () -> Void
    /// Joining by link. Receives a token parsed via `ShareLinkFormat`. Nil
    /// hides the field.
    let onJoin: (@MainActor @Sendable (String) -> Void)?
    /// What the share-link card offers for sharing — the pinned
    /// `WelcomePaneDecision`, not re-derived, so hosts and tests agree.
    let shareAction: WelcomePaneDecision.LinkShareAction
    let shareLabel: String
    let onShare: (@MainActor @Sendable () -> Void)?
    /// Why the last share attempt failed, if it did. Rendered under the retry button.
    let shareNote: String?

    public init(
        title: String = L("Welcome to Tailscreen"),
        subtitle: String = L("Share a screen with your tailnet, or with anyone over a link."),
        tailnetMessage: String = L(
            "Every Tailscreen on your tailnet, listed by name — connect with one click, no link to pass around."
        ),
        signInLabel: String,
        onSignIn: @escaping @MainActor @Sendable () -> Void,
        onJoin: (@MainActor @Sendable (String) -> Void)? = nil,
        shareAction: WelcomePaneDecision.LinkShareAction = .unavailable,
        shareLabel: String = L("Share your screen via Link…"),
        onShare: (@MainActor @Sendable () -> Void)? = nil,
        shareNote: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tailnetMessage = tailnetMessage
        self.signInLabel = signInLabel
        self.onSignIn = onSignIn
        self.onJoin = onJoin
        self.shareAction = shareAction
        self.shareLabel = shareLabel
        self.onShare = onShare
        self.shareNote = shareNote
    }

    public var body: some View {
        // Scrolling: two cards plus a paste field outgrow a short window.
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundColor(HubStyle.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                tailnetCard
                HubShareLinkCard(
                    onJoin: onJoin,
                    shareAction: shareAction,
                    shareLabel: shareLabel,
                    onShare: onShare,
                    shareNote: shareNote)
            }
            .frame(maxWidth: HubStyle.contentMaxWidth)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Lane one: sign in, and what it buys — the screens list a link can't give you.
    private var tailnetCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Your tailnet"))
                .font(.headline)
                .fontWeight(.semibold)
            Text(tailnetMessage)
                .font(.callout)
                .foregroundColor(HubStyle.secondaryText)
            Button(signInLabel, action: onSignIn)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubCard()
    }
}

/// Lane two: the no-account paths, both directions. Joining is an inline
/// field, not a collapsed button like `HubJoinCard` — an otherwise empty
/// window gains nothing from the extra click. Sharing stays a button, since
/// it mints a token rather than taking one.
///
/// Its own view, not a method on the pane, so the paste field's `@State`
/// belongs to the card that owns it.
struct HubShareLinkCard: View {
    let onJoin: (@MainActor @Sendable (String) -> Void)?
    let shareAction: WelcomePaneDecision.LinkShareAction
    let shareLabel: String
    let onShare: (@MainActor @Sendable () -> Void)?
    let shareNote: String?

    @State private var input = ""
    @State private var inputRejected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("A share link"))
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                // A badge, not a sentence: a property of this lane, not a step in it.
                Text(L("No account needed"))
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(HubStyle.searchFill))
            }
            if onJoin != nil {
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
                Button(L("Join"), action: join)
            }
            shareCluster
            Text(L("Guests join over an encrypted tunnel, and the sharer approves every one."))
                .font(.caption)
                .foregroundColor(HubStyle.tertiaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hubCard()
    }

    /// The sharing half, as the pinned decision says — never re-derived here.
    @ViewBuilder private var shareCluster: some View {
        switch shareAction {
        case .offer:
            if let onShare {
                Button(shareLabel, action: onShare)
            }
        case .sharingViaLink:
            // Points at the card below, where these hosts (unlike macOS's menu bar) keep the link.
            Text(L("You're sharing via link — the link and your guests are on the card below."))
                .font(.caption)
                .foregroundColor(HubStyle.secondaryText)
        case .unavailable:
            EmptyView()
        }
        if let shareNote {
            Text(shareNote)
                .font(.caption)
                .foregroundColor(HubStyle.secondaryText)
        }
    }

    /// Parse and hand over a plausible bare token. Real validation is the
    /// guest dial's; this only screens out obvious non-tokens.
    private func join() {
        guard let onJoin else { return }
        guard let token = ShareLinkFormat.token(fromUserInput: input) else {
            inputRejected = true
            return
        }
        // Cleared before handing over, so returning finds an empty field.
        input = ""
        inputRejected = false
        onJoin(token)
    }
}
