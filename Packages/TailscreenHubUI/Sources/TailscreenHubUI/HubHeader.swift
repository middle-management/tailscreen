import SwiftCrossUI

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

/// Thick header standing in for a title bar: the "Tailscreen" wordmark over a
/// status subtitle on the left, and on the right a spinner while something is
/// in flight, a Refresh button, and the account menu.
///
/// The macOS app gets this region for free by hiding its title bar and
/// attaching an empty toolbar so the traffic lights stay centered. Neither GTK
/// nor WinUI has that trick available through swift-cross-ui, so the header is
/// ordinary content with a fixed height — which is also why every optional
/// below hides its control rather than disabling it: an empty header reads as
/// a title bar, a header full of dead buttons does not.
public struct ViewerHeader: View {
    let subtitle: String
    var showSpinner = false
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
            VStack(alignment: .leading, spacing: 1) {
                Text("Tailscreen")
                    .font(.headline)
                    .fontWeight(.bold)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(HubStyle.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if showSpinner {
                ProgressView()
            }
            if let onRefresh {
                Button("Refresh", action: onRefresh)
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
                    Button("Add Account…") { onAddAccount() }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Double(HubStyle.headerHeight))
        .frame(maxWidth: .infinity)
        .background(HubStyle.barFill)
    }
}
