import Foundation

/// What must never reach a diagnostics bundle, removed at the moment of
/// recording rather than at the moment of export.
///
/// ## The line this draws
///
/// A diagnostics bundle is made to be **handed to somebody** — that is the
/// whole feature. So the question is not "is this private?" but "does handing
/// this over give the recipient something they did not already have?"
///
/// **Capabilities are redacted.** A share token (`tc…`), a tailnet auth key,
/// an interactive login URL: anyone holding one of these can *join the share*
/// or *act as the node*. They are bearer credentials — possession is
/// permission — and a bundle pasted into a chat or attached to a public issue
/// hands that permission to everyone who reads it. There is no troubleshooting
/// question these answer that a fingerprint does not answer just as well, so
/// they are replaced by one.
///
/// **Identifiers are kept.** Tailnet IPs (100.64/10), device names, peer
/// hostnames, node-key fingerprints. These are what make a bundle legible —
/// "which of the three viewers went black" is unanswerable without them, and
/// merging two sides depends on each naming the other. They are also not
/// secrets in the capability sense: a tailnet IP grants nothing to somebody
/// outside the tailnet, and inside it they were already visible. What the
/// feature owes the user here is not redaction but **disclosure** — the export
/// says plainly that the bundle names their devices, so the decision to share
/// it is informed. See ``DiagnosticsBundle/Header/contentNotice``.
///
/// ## Why scrubbing is defence in depth, not the mechanism
///
/// The primary defence is that no call site records a secret: nothing in the
/// instrumentation passes a token or a key to ``DiagnosticsRecorder``. But
/// free-text fields — a caught error's description, a log line captured by
/// ``DiagnosticsLogSink``, a URL in a failure message — are written by code
/// that has no idea it is feeding a recorder, and that is exactly how a
/// credential leaks into a log. So every string value is scrubbed on the way
/// in, unconditionally, and the cost is paid on a path that only runs while
/// recording is on.
///
/// Scrubbing on the way **in** rather than on the way out is deliberate: an
/// unredacted recorder is one forgotten export path away from a leak, and
/// there is no use for the raw value in between.
public enum DiagnosticsRedaction {

    /// What a redacted value is replaced with, when there is nothing
    /// meaningful to keep.
    public static let placeholder = "<redacted>"

    /// Scrub every string value in a field set.
    ///
    /// Keys are left alone: they come from the instrumentation, never from
    /// user or peer data, and a scrubbed key would break the joins the whole
    /// format is for.
    public static func scrub(_ fields: [String: DiagnosticValue]) -> [String: DiagnosticValue] {
        // The common case is a field set with no strings in it at all, or with
        // strings that need nothing done, and it must not pay for a copy.
        // `var scrubbed = fields` does not copy: Swift dictionaries are
        // copy-on-write, so the buffer is shared until the first mutation —
        // which only happens when something actually needed redacting.
        var scrubbed = fields
        var changed = false
        for (key, value) in fields {
            guard case .string(let text) = value else { continue }
            let clean = scrub(text)
            guard clean != text else { continue }
            scrubbed[key] = .string(clean)
            changed = true
        }
        return changed ? scrubbed : fields
    }

    /// Scrub one free-text string.
    ///
    /// Word-wise rather than by regular expression: the things being looked
    /// for are whole opaque blobs, they are always whitespace- or
    /// punctuation-delimited in practice, and a scanner that cannot
    /// catastrophically backtrack is the right thing to put on a path that
    /// runs inside a lock.
    public static func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // Cheap pre-filter. A token needs "tc", a key needs "-auth", and a
        // login URL needs "://" — a string with none of them cannot contain
        // any of the three, and that is nearly every string recorded.
        let lowered = text.lowercased()
        guard lowered.contains("tc") || lowered.contains("key") || lowered.contains("://") else {
            return text
        }

        var out = ""
        out.reserveCapacity(text.count)
        var word = ""

        func flush() {
            guard !word.isEmpty else { return }
            out += redactWord(word)
            word.removeAll(keepingCapacity: true)
        }

        for character in text {
            // Split on whitespace only. Punctuation is *inside* the things
            // being matched — `://`, `-`, `_`, `=` all occur within a URL,
            // an auth key and a base64url token — so splitting on it would
            // shred the very blobs this is looking for.
            if character.isWhitespace {
                flush()
                out.append(character)
            } else {
                word.append(character)
            }
        }
        flush()
        return out
    }

    /// Decide one whitespace-delimited word's fate.
    private static func redactWord(_ word: String) -> String {
        // Strip trailing sentence punctuation so "…token=tcABC." matches, and
        // put it back after. Leading punctuation is left attached: it never
        // precedes one of these blobs, and stripping it would need the same
        // care for no gain.
        let trailing = word.suffix(while: { ".,;:!?)]}\"'".contains($0) })
        let core = String(word.dropLast(trailing.count))
        guard !core.isEmpty else { return word }

        if let replacement = redactCore(core) {
            return replacement + trailing
        }
        return word
    }

    /// The three shapes, in the order they are cheapest to rule out.
    private static func redactCore(_ core: String) -> String? {
        // 1. An interactive login URL. Tailscale's is
        //    `https://login.tailscale.com/a/<secret>`, and a self-hosted
        //    control server's is the same shape on another host — so the
        //    scheme-and-path shape is matched rather than the hostname, which
        //    is exactly the case a hostname allowlist would miss. The origin
        //    is KEPT: which control server was used is a real troubleshooting
        //    answer ("they were on a headscale"), and it is not the secret.
        if let scheme = core.range(of: "://") {
            let afterScheme = core[scheme.upperBound...]
            if let slash = afterScheme.firstIndex(of: "/") {
                let origin = core[core.startIndex..<slash]
                let path = afterScheme[slash...]
                // A bare origin or a short, obviously-non-secret path (the
                // docs links this app shows the user) stays whole.
                if path.count > 8 && !isWellKnownPublicPath(String(path)) {
                    return "\(origin)/\(placeholder)"
                }
            }
            return nil
        }

        // 2. A share token. Fingerprinted rather than dropped: the fingerprint
        //    is what makes a merged bundle joinable — the sharer minted this
        //    link and the guest joined with it, and "the same link" is the
        //    fact being established. It is a truncated hash, so it identifies
        //    without admitting.
        if ShareLinkFormat.isPlausibleToken(core) {
            return "tc:\(fingerprint(core))"
        }

        // 3. A tailnet auth key: `tskey-auth-…`, `tskey-client-…`, and the
        //    bare `tskey-…` older forms. Prefix kept (which kind of key was
        //    used is diagnostic), secret dropped.
        let lowered = core.lowercased()
        if lowered.hasPrefix("tskey-") {
            let parts = core.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 2 {
                return "\(parts[0])-\(parts[1])-\(placeholder)"
            }
            return placeholder
        }

        return nil
    }

    /// Links the app itself puts in front of the user — docs, the project
    /// page, the web viewer's base. Redacting these would be pure noise, and
    /// they carry nothing.
    private static func isWellKnownPublicPath(_ path: String) -> Bool {
        let publicPrefixes = ["/docs", "/install", "/troubleshooting", "/usage", "/next"]
        return publicPrefixes.contains { path.hasPrefix($0) }
    }

    /// A short, stable, one-way fingerprint of a secret.
    ///
    /// FNV-1a, not a cryptographic hash: this tier is Foundation-only (no
    /// CryptoKit on Linux) and the requirement is *linkability*, not
    /// resistance to a determined attacker. Twelve hex digits of a 64-bit hash
    /// distinguishes the handful of tokens a session ever sees, and the
    /// pre-image it protects is a 200-bit random blob — a hash collision is
    /// not the interesting attack, and neither is inversion.
    public static func fingerprint(_ secret: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in secret.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(format: "%012llx", hash & 0xffff_ffff_ffff)
    }
}

extension StringProtocol {
    /// Trailing run of characters satisfying `predicate`.
    fileprivate func suffix(while predicate: (Character) -> Bool) -> String {
        String(reversed().prefix(while: predicate).reversed())
    }
}
