// Share-by-token link formatting: the one place the `tailscreen:` join
// URL shape and the token's user-visible handling live, shared by every
// host's "Copy Link" button and "Join a Share" paste field so a link one
// app produces is always a string another app parses.
//
// The token itself is opaque to Swift — a "tc"-prefixed base64url blob
// minted by the guest node (see the guest package in libtailscale); it is
// deliberately never decoded here. Base64url means the token is URL-safe
// verbatim, so the link needs no percent-encoding.

import Foundation

public enum ShareLinkFormat {
    /// The URL scheme the macOS app registers (CFBundleURLTypes) and the
    /// join sheet accepts. Linux/Windows registration is tracked in the
    /// platform matrix.
    public static let scheme = "tailscreen"

    /// The join URL for a token: `tailscreen://join?token=tc…`. What
    /// "Copy Link" puts on the clipboard.
    public static func link(token: String) -> String {
        "\(scheme)://join?token=\(token)"
    }

    /// Extract a share token from whatever a user pasted: a bare token, a
    /// join URL (with or without the `//`), or either with surrounding
    /// whitespace. Returns nil when the input holds no plausible token —
    /// the join sheet's "that doesn't look like a share link" state.
    public static func token(fromUserInput input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isPlausibleToken(trimmed) { return trimmed }
        // URL forms. `URLComponents` handles both `tailscreen://join?…`
        // (host "join") and `tailscreen:join?…` (path "join").
        guard let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == scheme
        else { return nil }
        let token = components.queryItems?.first { $0.name == "token" }?.value
        guard let token, isPlausibleToken(token) else { return nil }
        return token
    }

    /// A token is "tc" + base64url — checked shallowly (prefix, charset,
    /// non-trivial length). Real validation happens when the guest node
    /// decodes it; this only gates obvious non-tokens out of the UI early.
    static func isPlausibleToken(_ candidate: String) -> Bool {
        guard candidate.count > 10, candidate.hasPrefix("tc") else { return false }
        let base64url = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return candidate.dropFirst(2).unicodeScalars.allSatisfy { base64url.contains($0) }
    }

    /// Short display form of a guest's node public key — the roster's
    /// stand-in for a hostname, since guests have none: "9c8d…4f21"
    /// (first/last 4 of the hex), with any "nodekey:" prefix dropped.
    /// Returns the input unshortened when it's too short to elide.
    public static func keyFingerprint(_ nodeKey: String) -> String {
        let hex =
            nodeKey.hasPrefix("nodekey:")
            ? String(nodeKey.dropFirst("nodekey:".count)) : nodeKey
        guard hex.count > 8 else { return hex }
        return "\(hex.prefix(4))…\(hex.suffix(4))"
    }
}
