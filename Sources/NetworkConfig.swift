import Foundation

/// Centralized network configuration for Tailscreen.
///
/// CLAUDE.md flags the port literal as a known pitfall: changing it required
/// touching the server, client, peer discovery, metadata service, and tests.
/// Route every call site through this enum so a port change is a one-liner.
enum NetworkConfig {
    /// Tailscreen's well-known port — used for both TCP (presence beacon,
    /// annotations, metadata) and UDP (RTP video + audio).
    static let tailscreenPort: UInt16 = 7447
}
