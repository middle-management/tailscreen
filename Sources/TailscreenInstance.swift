import Foundation

/// Per-process naming knobs so two Tailscreen instances can coexist on one machine
/// during local testing. Set `TAILSCREEN_INSTANCE=1` in one shell and `TAILSCREEN_INSTANCE=2`
/// in another before launching the app; each instance gets its own tailnet
/// identity (separate state dir + distinct hostname) and they see each other
/// as peers.
enum TailscreenInstance {
    /// Value of the TAILSCREEN_INSTANCE env var, trimmed; empty when unset.
    static var id: String {
        let raw = ProcessInfo.processInfo.environment["TAILSCREEN_INSTANCE"] ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Appended to every state-dir basename (server/client/auth) so two
    /// processes never share a `tailscaled.state` and therefore never share
    /// a machine key.
    static var stateSuffix: String {
        id.isEmpty ? "" : "-\(id)"
    }

    /// Appended to hostnames so the tailnet shows two visibly distinct nodes.
    static var hostnameSuffix: String {
        id.isEmpty ? "" : "-\(id)"
    }

    /// Override the Tailscale control plane URL — point Tailscreen at a
    /// self-hosted headscale (or other tsnet-compatible) instance instead of
    /// `controlplane.tailscale.com`. Returns nil when unset so callers fall
    /// through to `kDefaultControlURL`.
    static var controlURLOverride: String? {
        let raw = ProcessInfo.processInfo.environment["TAILSCREEN_TS_CONTROL_URL"] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Pre-shared Tailscale auth key for unattended sign-in. Useful with
    /// headscale, kiosks, or any setup where the interactive browser-login
    /// flow isn't viable. nil falls through to interactive login.
    static var authKey: String? {
        let raw = ProcessInfo.processInfo.environment["TAILSCREEN_TS_AUTHKEY"] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
