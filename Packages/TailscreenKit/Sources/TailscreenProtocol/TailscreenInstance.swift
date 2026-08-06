import Foundation

/// Per-process naming knobs so two Tailscreen instances can coexist on one machine
/// during local testing. Set `TAILSCREEN_INSTANCE=1` in one shell and `TAILSCREEN_INSTANCE=2`
/// in another before launching the app; each instance gets its own tailnet
/// identity (separate state dir + distinct hostname) and they see each other
/// as peers.
public enum TailscreenInstance {
    /// Value of the TAILSCREEN_INSTANCE env var, trimmed; empty when unset.
    public static var id: String {
        let raw = ProcessInfo.processInfo.environment["TAILSCREEN_INSTANCE"] ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Appended to every state-dir basename (server/client/auth) so two
    /// processes never share a `tailscaled.state` and therefore never share
    /// a machine key.
    public static var stateSuffix: String {
        id.isEmpty ? "" : "-\(id)"
    }

    /// Appended to hostnames so the tailnet shows two visibly distinct nodes.
    public static var hostnameSuffix: String {
        id.isEmpty ? "" : "-\(id)"
    }

    /// Override the Tailscale control plane URL — point Tailscreen at a
    /// self-hosted headscale (or other tsnet-compatible) instance instead of
    /// `controlplane.tailscale.com`. Returns nil when unset so callers fall
    /// through to `kDefaultControlURL`.
    public static var controlURLOverride: String? {
        let raw = ProcessInfo.processInfo.environment["TAILSCREEN_TS_CONTROL_URL"] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Pre-shared Tailscale auth key for unattended sign-in. Useful with
    /// headscale, kiosks, or any setup where the interactive browser-login
    /// flow isn't viable. nil falls through to interactive login.
    public static var authKey: String? {
        let raw = ProcessInfo.processInfo.environment["TAILSCREEN_TS_AUTHKEY"] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Hostname prefix every Tailscreen *instance* node registers under in
    /// the tailnet (see `AppState.getOrCreateNode`). The peer-discovery
    /// path filters the IPN peer list by this prefix to decide which
    /// tailnet machines are Tailscreen installations.
    public static let serverHostnamePrefix = "tailscreen-"

    /// Hostname prefix that ephemeral *viewer* nodes use (see
    /// `TailscaleScreenShareClient`). Excluded from the discovery list so
    /// short-lived client identities don't show up as connectable
    /// instances.
    public static let clientHostnamePrefix = "tailscreen-client-"

    /// Hostname prefix the portable viewer (`Packages/TailscreenLinuxBackends`) registers its
    /// ephemeral tsnet node under. Deliberately built on `clientHostnamePrefix`
    /// so `isTailscreenServerHostname` excludes it — a transient viewer must not
    /// appear as a connectable screen in peer discovery. (`TailscreenInstanceTests`
    /// pins the `clientHostnamePrefix`-prefix invariant this relies on.)
    public static let viewerHostnamePrefix = clientHostnamePrefix + "viewer-"

    /// True when `hostname` looks like a long-lived Tailscreen instance —
    /// i.e. an installation that can host or accept shares, not a
    /// transient viewer node.
    public static func isTailscreenServerHostname(_ hostname: String) -> Bool {
        hostname.hasPrefix(serverHostnamePrefix) && !hostname.hasPrefix(clientHostnamePrefix)
    }

    /// Sanitize a machine name into a tailnet-legal node label.
    ///
    /// tsnet hostnames are DNS labels: `[a-z0-9-]` only, no leading or
    /// trailing hyphen, bounded length. Anything else is rejected or silently
    /// mangled by the control plane. This is the ONE implementation both
    /// swift-cross-ui hosts feed into `NodeRole.shareCapable(name:)` — it
    /// used to exist per-app, and the Windows copy neither trimmed hyphens
    /// nor capped length, so a `COMPUTERNAME` of `-lab-box` registered an
    /// illegal label.
    ///
    /// Strictly ASCII: `isLetter` would admit `é` or `漢`, which are just as
    /// illegal in a DNS label as `_`. Non-ASCII maps to `-` like any other
    /// disallowed scalar, so word boundaries survive ("Robert's PC" →
    /// "robert-s-pc"). The 48-char cap leaves room for
    /// `serverHostnamePrefix` under DNS's 63-char label limit, and the trim
    /// runs after the cap too, so a name cut at a hyphen stays legal.
    public static func nodeLabel(from raw: String, fallback: String) -> String {
        let mapped = raw.lowercased().map { ch -> Character in
            ("a"..."z").contains(ch) || ("0"..."9").contains(ch) ? ch : "-"
        }
        let hyphens = CharacterSet(charactersIn: "-")
        let trimmed = String(mapped).trimmingCharacters(in: hyphens)
        let capped = String(trimmed.prefix(48)).trimmingCharacters(in: hyphens)
        return capped.isEmpty ? fallback : capped
    }
}
