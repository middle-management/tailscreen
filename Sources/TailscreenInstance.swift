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
}
