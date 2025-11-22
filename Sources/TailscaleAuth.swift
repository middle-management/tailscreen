import Foundation
import TailscaleKit
import AppKit

/// Manages Tailscale authentication state and user profile
@MainActor
class TailscaleAuth: ObservableObject {
    @Published var isAuthenticated = false
    @Published var userProfile: TailscaleUserProfile?
    @Published var authURL: String?
    @Published var isLoading = false

    private var localAPIClient: LocalAPIClient?
    private let logger = TSLogger()

    /// Checks authentication status and fetches user profile
    func checkAuthStatus(node: TailscaleNode) async {
        isLoading = true
        defer { isLoading = false }

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
                    profilePicURL: profile.UserProfile.ProfilePicURL
                )
                self.isAuthenticated = true
                logger.log("✓ Authenticated as \(profile.UserProfile.DisplayName)")
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
    func login(node: TailscaleNode) async throws {
        isLoading = true
        defer { isLoading = false }

        let client = LocalAPIClient(localNode: node, logger: logger)
        self.localAPIClient = client

        // Start interactive login
        try await client.startLoginInteractive()

        // Get the backend status which should contain auth URL
        let status = try await client.backendStatus()

        if let authURL = status.AuthURL, !authURL.isEmpty {
            self.authURL = authURL
            logger.log("🔗 Auth URL: \(authURL)")

            // Open auth URL in browser
            if let url = URL(string: authURL) {
                NSWorkspace.shared.open(url)
            }
        }

        // Poll for authentication completion
        try await pollForAuth(client: client, node: node)
    }

    /// Signs out the current user
    func signOut() async throws {
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
    private func pollForAuth(client: LocalAPIClient, node: TailscaleNode, maxAttempts: Int = 30) async throws {
        for attempt in 1...maxAttempts {
            try await Task.sleep(for: .seconds(2))

            do {
                let profile = try await client.currentProfile()

                if !profile.isNullUser() {
                    // Authentication successful!
                    self.userProfile = TailscaleUserProfile(
                        displayName: profile.UserProfile.DisplayName,
                        loginName: profile.UserProfile.LoginName,
                        profilePicURL: profile.UserProfile.ProfilePicURL
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
struct TailscaleUserProfile: Sendable {
    let displayName: String
    let loginName: String
    let profilePicURL: String?
}

enum TailscaleAuthError: Error, LocalizedError {
    case notInitialized
    case authTimeout

    var errorDescription: String? {
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
    var logFileHandle: Int32? = nil

    func log(_ message: String) {
        print("[Auth] \(message)")
    }
}
