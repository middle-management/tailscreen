import SwiftCrossUI
import TailscreenL10n

/// One signed-in account, for the header's account menu.
///
/// Deliberately not either app's profile type: the chrome needs a name and a
/// way to say which one was picked, and nothing else. Keeping it that way is
/// what stops a UI package from acquiring an opinion about where state
/// directories live.
public struct HubAccount: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Header bar: the session status on the left, and on the right a spinner
/// while something is in flight, a Refresh button, and the account menu.
///
/// No "Tailscreen" wordmark here, deliberately. The macOS app hides its native
/// title bar, so its hub header doubles as one and carries the wordmark; both
/// swift-cross-ui hosts keep their native title bars — which already say
/// "Tailscreen" — and repeating it directly underneath read as redundant (it
/// did, on the first Windows desktop build). The header is ordinary content
/// with a fixed height, which is also why every optional below hides its
/// control rather than disabling it: a quiet header reads as chrome, a header
/// full of dead buttons does not.
public struct ViewerHeader: View {
    let subtitle: String
    var showSpinner = false
    /// The peer-list filter menu (nil ⇒ hidden — a host with no list to filter,
    /// or a surface that is not showing one right now).
    var filter: HubFilter?
    var onRefresh: (@MainActor @Sendable () -> Void)?
    /// One more header button, for whatever this app's header needs that the
    /// other's does not — Sign out, on a build with no account menu to hang it
    /// inside. Hidden when nil.
    var secondaryAction: HubAction?
    /// Multi-account menu (nil ⇒ hidden). `accountName` labels the menu button;
    /// the menu lists `accounts` (active marked) + Add Account.
    var accountName: String?
    var accounts: [HubAccount] = []
    var activeAccountID = ""
    var onSelectAccount: (@MainActor @Sendable (String) -> Void)?
    var onAddAccount: (@MainActor @Sendable () -> Void)?

    public init(
        subtitle: String,
        showSpinner: Bool = false,
        filter: HubFilter? = nil,
        onRefresh: (@MainActor @Sendable () -> Void)? = nil,
        secondaryAction: HubAction? = nil,
        accountName: String? = nil,
        accounts: [HubAccount] = [],
        activeAccountID: String = "",
        onSelectAccount: (@MainActor @Sendable (String) -> Void)? = nil,
        onAddAccount: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.subtitle = subtitle
        self.showSpinner = showSpinner
        self.filter = filter
        self.onRefresh = onRefresh
        self.secondaryAction = secondaryAction
        self.accountName = accountName
        self.accounts = accounts
        self.activeAccountID = activeAccountID
        self.onSelectAccount = onSelectAccount
        self.onAddAccount = onAddAccount
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text(subtitle)
                .font(.body)
                .foregroundColor(HubStyle.secondaryText)
                .lineLimit(1)
            Spacer()
            if showSpinner {
                ProgressView()
            }
            // Filter sits before Refresh, mirroring the macOS header's order
            // (filter, refresh, account): both act on the list below, and the
            // one that changes what the list *means* reads first.
            if let filter {
                HubFilterMenu(model: filter)
            }
            if let onRefresh {
                Button(L("Refresh"), action: onRefresh)
            }
            if let secondaryAction {
                Button(secondaryAction.label, action: secondaryAction.perform)
            }
            if let accountName, let onSelectAccount, let onAddAccount {
                Menu(accountName) {
                    ForEach(accounts, id: \.id) { account in
                        Button((account.id == activeAccountID ? "● " : "   ") + account.name) {
                            onSelectAccount(account.id)
                        }
                    }
                    Divider()
                    Button(L("Add Account…")) { onAddAccount() }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Double(HubStyle.headerHeight))
        .frame(maxWidth: .infinity)
        .background(HubStyle.barFill)
    }
}
