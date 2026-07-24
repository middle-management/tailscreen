import Foundation
import TailscaleKit
import TailscreenProtocol

/// Manages Tailscale authentication state and user profile.
///
/// Platform-portable (TailscreenTransport): the one host-specific step —
/// opening the interactive-login URL in a browser — is delegated to
/// ``onOpenAuthURL`` (the mac app wires it to `NSWorkspace`; a Linux host
/// would use `xdg-open` or just display the URL).
@MainActor
public class TailscaleAuth: ObservableObject {
    @Published public var isAuthenticated = false
    @Published public var userProfile: TailscaleUserProfile?
    @Published public var authURL: String?
    @Published public var isLoading = false

    /// Called with the interactive-login URL when the flow needs the user
    /// to visit their identity provider. Host-app policy — same pattern as
    /// `TailscaleIPNWatcher.onBrowseToURL`. When unset, the URL is still
    /// published via ``authURL`` so a UI can render it.
    public var onOpenAuthURL: ((URL) -> Void)?

    public init() {}

    private var localAPIClient: LocalAPIClient?
    private let logger = TSLogger()

    /// Checks authentication status and fetches user profile
    public func checkAuthStatus(node: TailscaleNode) async {
        // Don't set isLoading here - it interferes with login flow UI
        // isLoading should only be true during active login attempts

        do {
            let client = LocalAPIClient(localNode: node, logger: logger)
            self.localAPIClient = client

            // Get current profile
            let profile = try await client.currentProfile()

            if !profile.isNullUser() {
                // User is logged in
                self.userProfile = TailscaleUserProfile(
                    displayName: profile.UserProfile.DisplayName,
                    loginName: profile.UserProfile.LoginName,
                    profilePicURL: profile.UserProfile.ProfilePicURL,
                    tailnetName: profile.NetworkProfile?.DomainName ?? ""
                )
                self.isAuthenticated = true
                logger.log("✓ Authenticated as \(profile.UserProfile.DisplayName)")
                logger.log("✓ Set isAuthenticated = true, isLoading will be set to false")
            } else {
                // No user logged in
                self.isAuthenticated = false
                self.userProfile = nil
                logger.log("ℹ️ Not authenticated")
            }
        } catch {
            logger.log("❌ Failed to check auth status: \(error)")
            self.isAuthenticated = false
            self.userProfile = nil
        }
    }

    /// Initiates interactive login flow
    public func login(node: TailscaleNode) async throws {
        guard !isLoading else {
            logger.log("⚠️ Login already in progress")
            return
        }
        isLoading = true
        defer {
            isLoading = false
            logger.log("🔧 Login flow complete, isLoading = false")
        }

        let client = LocalAPIClient(localNode: node, logger: logger)
        self.localAPIClient = client

        // First check if already authenticated
        logger.log("🔧 Checking if already authenticated...")
        do {
            let profile = try await client.currentProfile()
            if !profile.isNullUser() {
                // Already authenticated!
                self.userProfile = TailscaleUserProfile(
                    displayName: profile.UserProfile.DisplayName,
                    loginName: profile.UserProfile.LoginName,
                    profilePicURL: profile.UserProfile.ProfilePicURL,
                    tailnetName: profile.NetworkProfile?.DomainName ?? ""
                )
                self.isAuthenticated = true
                logger.log("✓ Already authenticated as \(profile.UserProfile.DisplayName)")
                return
            }
        } catch {
            logger.log("⚠️ Not authenticated yet, will start login flow")
        }

        // Not authenticated, start interactive login
        logger.log("🔧 Starting interactive login...")
        try await client.startLoginInteractive()
        logger.log("🔧 Interactive login started, waiting for auth URL...")

        // Poll for the auth URL to appear in backend status
        var authURL = ""
        for attempt in 1...10 {
            try await Task.sleep(for: .seconds(1))

            logger.log("🔧 Fetching backend status (attempt \(attempt))...")
            do {
                // Add timeout to prevent hanging
                let status = try await withTimeout(seconds: 3) {
                    try await client.backendStatus()
                }

                logger.log("🔧 Backend status - BackendState: '\(status.BackendState)'")
                logger.log(
                    "🔧 Auth URL from status: '\(status.AuthURL)' (isEmpty: \(status.AuthURL.isEmpty))"
                )

                if !status.AuthURL.isEmpty {
                    authURL = status.AuthURL
                    break
                }
            } catch {
                logger.log("⚠️ Failed to fetch backend status: \(error)")
            }
        }

        if !authURL.isEmpty {
            self.authURL = authURL
            logger.log("🔗 Auth URL: \(authURL)")

            // Hand the URL to the host app to open (browser policy is
            // host-specific — see onOpenAuthURL).
            if let url = URL(string: authURL) {
                logger.log("✅ Opening auth URL: \(url)")
                onOpenAuthURL?(url)
            } else {
                logger.log("❌ Failed to create URL from: \(authURL)")
            }
        } else {
            logger.log("⚠️ Auth URL is empty after polling!")
        }

        // Poll for authentication completion
        logger.log("🔧 Starting to poll for authentication...")
        try await pollForAuth(client: client, node: node)
    }

    /// Signs out the current user
    public func signOut() async throws {
        guard let client = localAPIClient else {
            throw TailscaleAuthError.notInitialized
        }

        isLoading = true
        defer { isLoading = false }

        try await client.logout()

        self.isAuthenticated = false
        self.userProfile = nil
        self.authURL = nil

        logger.log("✓ Signed out")
    }

    /// Polls for authentication completion
    private func pollForAuth(
        client: LocalAPIClient, node: TailscaleNode, maxAttempts: Int = 30
    ) async throws {
        for attempt in 1...maxAttempts {
            try await Task.sleep(for: .seconds(2))

            do {
                let profile = try await client.currentProfile()

                if !profile.isNullUser() {
                    // Authentication successful!
                    self.userProfile = TailscaleUserProfile(
                        displayName: profile.UserProfile.DisplayName,
                        loginName: profile.UserProfile.LoginName,
                        profilePicURL: profile.UserProfile.ProfilePicURL,
                        tailnetName: profile.NetworkProfile?.DomainName ?? ""
                    )
                    self.isAuthenticated = true
                    self.authURL = nil
                    logger.log("✓ Authentication successful!")
                    return
                }
            } catch {
                logger.log("⏳ Polling for auth... attempt \(attempt)/\(maxAttempts)")
            }
        }

        throw TailscaleAuthError.authTimeout
    }
}

/// User profile information from Tailscale
public struct TailscaleUserProfile: Sendable {
    public let displayName: String
    public let loginName: String
    public let profilePicURL: String?
    /// Tailnet (organization) name from the login profile's
    /// `NetworkProfile.DomainName`, e.g. "example.com" or "slaskis.github".
    /// This is what tells two logins apart when the login name itself is
    /// identical — a GitHub identity used across several orgs yields the
    /// same `loginName` on every tailnet. Empty when the backend didn't
    /// report one.
    public let tailnetName: String

    public init(
        displayName: String, loginName: String, profilePicURL: String?,
        tailnetName: String = ""
    ) {
        self.displayName = displayName
        self.loginName = loginName
        self.profilePicURL = profilePicURL
        self.tailnetName = tailnetName
    }
}

public enum TailscaleAuthError: Error, LocalizedError {
    case notInitialized
    case authTimeout

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Authentication client not initialized"
        case .authTimeout:
            return "Authentication timed out. Please try again."
        }
    }
}

// MARK: - Logger Implementation

private struct TSLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[Auth] \(message)")
    }
}
