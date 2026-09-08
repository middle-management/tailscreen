import SwiftCrossUI
import TailscreenL10n
import TailscreenProtocol

/// The pre-sign-in hub: one card per way in.
///
/// There are two and they are not variants of each other — the tailnet (sign
/// in once, then every Tailscreen shows up by name) and a share link (nothing
/// to sign into, works in both directions, guest approval mandatory). The
/// Windows app used to render a single sign-in card with the join affordance
/// hanging under it, beneath a sentence that described only the tailnet, so
/// the copy had already excluded what sat below it. A link-only share is a
/// whole mode of the app — no account on either end — not a footnote to
/// signing in. The macOS welcome pane makes the same split, card for card;
/// this is that layout in the shared chrome, so all three apps' empty states
/// read as one product.
///
/// One deliberate difference from macOS, forced by these hosts having no
/// second surface: where the mac pane points a running link-only share at the
/// menu bar, here the live `shareCard` renders **under** the two cards — its
/// link, roster and approvals have nowhere else to be. `shareCard` is
/// therefore nil while idle; the share-link card's own button is what starts
/// one.
public struct HubSignInPane: View {
    let title: String
    let subtitle: String
    /// The tailnet card's body copy: the pitch by default, or whatever went
    /// wrong — a failed bring-up, a saved sign-in that needs the browser
    /// again. The reason belongs on the card its button is on.
    let tailnetMessage: String
    let signInLabel: String
    let onSignIn: @MainActor @Sendable () -> Void
    /// Joining by link. Receives a parsed token — the field's own parse is
    /// `ShareLinkFormat`, the same one every host's copy buttons produce
    /// links with. Nil hides the field (previews, a host with no viewer).
    let onJoin: (@MainActor @Sendable (String) -> Void)?
    /// What the share-link card offers for the *sharing* half — the pinned
    /// `WelcomePaneDecision`, taken rather than re-derived so both hosts and
    /// the tests agree on one branch.
    let shareAction: WelcomePaneDecision.LinkShareAction
    let shareLabel: String
    let onShare: (@MainActor @Sendable () -> Void)?
    /// The live share's whole card, rendered under the two — see the note
    /// above. Nil while idle.
    let shareCard: ShareCard?

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
        shareCard: ShareCard? = nil
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
        self.shareCard = shareCard
    }

    public var body: some View {
        // Scrolling, because this pane is no longer just a button: a
        // link-only share renders its whole card here — preview, roster,
        // approvals — and an approval you cannot scroll to is one you cannot
        // answer.
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
                    onShare: onShare)
                if let shareCard {
                    shareCard
                }
            }
            .frame(maxWidth: HubStyle.contentMaxWidth)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Lane one: sign in, and what signing in buys — the screens list itself,
    /// which is the thing a link cannot give you.
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

/// Lane two: the no-account paths, both directions.
///
/// Joining is an inline field rather than a button that expands one — joining
/// always starts with a pasted token, and on a window that is otherwise empty
/// the extra click bought nothing. (The hub's own `HubJoinCard` keeps its
/// collapsed form: there the affordance sits beside a list of screens and
/// must not shout.) Sharing stays a button, because it mints a token instead
/// of taking one.
///
/// Its own view rather than a method on the pane so the paste field's
/// `@State` belongs to the card that owns it, and so a host can drop the
/// whole lane by passing neither handler.
struct HubShareLinkCard: View {
    let onJoin: (@MainActor @Sendable (String) -> Void)?
    let shareAction: WelcomePaneDecision.LinkShareAction
    let shareLabel: String
    let onShare: (@MainActor @Sendable () -> Void)?

    @State private var input = ""
    @State private var inputRejected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("A share link"))
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                // Said as a badge rather than a sentence: it is the one fact
                // that distinguishes this lane from the one above it, and it
                // is a property of the lane, not a step in it.
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
                    // secondaryText, matching every other failure note in
                    // this chrome — there is no danger token, and inventing
                    // one for a paste-validation line would out-shout real
                    // problems.
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
            // Where the mac pane names the menu bar, these hosts name the
            // card directly below: it is the same answer to "where is my
            // link", pointed at the surface each app actually has.
            Text(L("You're sharing via link — the link and your guests are on the card below."))
                .font(.caption)
                .foregroundColor(HubStyle.secondaryText)
        case .unavailable:
            EmptyView()
        }
    }

    /// Parse, then hand over a plausible bare token and nothing else. Real
    /// validation is the guest dial's; this only keeps obvious non-tokens out
    /// of a session attempt, with the inline line as the answer.
    private func join() {
        guard let onJoin else { return }
        guard let token = ShareLinkFormat.token(fromUserInput: input) else {
            inputRejected = true
            return
        }
        // Cleared before handing over: the session UI takes the window, and
        // coming back should land on an empty field rather than a stale one.
        input = ""
        inputRejected = false
        onJoin(token)
    }
}
