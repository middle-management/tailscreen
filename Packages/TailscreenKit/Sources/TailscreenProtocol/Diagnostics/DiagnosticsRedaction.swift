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

    /// The three shapes, applied in SEQUENCE — one value can carry more than
    /// one credential.
    ///
    /// Returning on the first match is what this did, and
    /// `token=tc…&authKey=tskey-auth-…` is the shape that made it a leak: the
    /// token was fingerprinted, the function returned, and the auth key rode
    /// out untouched. Each step now sees what the previous one left, so the
    /// guarantee is about the value rather than about whichever credential
    /// happened to appear first.
    private static func redactCore(_ core: String) -> String? {
        var value = core
        var changed = false

        // 1. Share tokens, FIRST and anywhere in the word.
        //
        //    These are the sharpest thing this scrubber handles: possession of
        //    one is permission to join the share. They almost never appear as
        //    a bare word — the shapes that actually reach a log line are
        //    `token=tc…`, `"token":"tc…"`, `tailscreen://join?token=tc…` and
        //    `https://tailscreen.dev/view/#tc…`. An earlier version tested only
        //    whether the whole word was a token, so every one of those passed
        //    through untouched, which is precisely the guarantee the bundle
        //    header makes to the person sending the file.
        if let redacted = redactTokens(in: value) {
            value = redacted
            changed = true
        }

        // 2. An interactive login URL.
        if let redacted = redactLoginURLPath(in: value) {
            value = redacted
            changed = true
        }

        // 3. A tailnet auth key, anywhere in the word for the same reason
        //    tokens are: `authKey=tskey-auth-…` and JSON fragments are how one
        //    actually reaches a log line.
        if let redacted = redactAuthKeys(in: value) {
            value = redacted
            changed = true
        }

        return changed ? value : nil
    }

    /// Replace an interactive login URL's secret path, keeping its origin.
    ///
    /// Tailscale's is `https://login.tailscale.com/a/<secret>`, and a
    /// self-hosted control server's is the same shape on another host — so the
    /// scheme-and-path shape is matched rather than the hostname, which is
    /// exactly the case a hostname allowlist would miss. The origin is KEPT:
    /// which control server was used is a real troubleshooting answer ("they
    /// were on a headscale"), and it is not the secret.
    private static func redactLoginURLPath(in word: String) -> String? {
        guard let scheme = word.range(of: "://") else { return nil }
        let afterScheme = word[scheme.upperBound...]
        // No path at all is a bare origin, which carries nothing.
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let origin = word[word.startIndex..<slash]
        let path = String(afterScheme[slash...])
        // The docs links this app shows the user stay whole.
        guard !isWellKnownPublicPath(path) else { return nil }
        // Length is measured with anything an EARLIER step already redacted
        // subtracted out. A share link is `…/view/#tc:9f21…`: after step 1 its
        // path is long only because the fingerprint is sitting in it, and
        // replacing the whole path here would throw away the one value that
        // lets two bundles show they used the same link. A login URL that also
        // carried a token — `…/a/<secret>?token=tc…` — still has an opaque
        // `/a/<secret>` left after the subtraction, and is redacted.
        guard residualLength(of: path) > 8 else { return nil }
        return "\(origin)/\(placeholder)"
    }

    /// How much of `path` is not already a redaction marker this pass wrote.
    private static func residualLength(of path: String) -> Int {
        var rest = path.replacingOccurrences(of: placeholder, with: "")
        // `tc:` plus its hex fingerprint. Removing at least the marker each
        // time guarantees this terminates.
        while let marker = rest.range(of: "tc:") {
            var end = marker.upperBound
            while end < rest.endIndex, rest[end].isHexDigit {
                end = rest.index(after: end)
            }
            rest.removeSubrange(marker.lowerBound..<end)
        }
        return rest.count
    }

    /// The key *kinds* Tailscale puts between `tskey-` and the secret.
    ///
    /// An allowlist, and deliberately so: the segment after `tskey-` is either
    /// a kind word or it is the secret itself, and there is no way to tell them
    /// apart by shape. Treating an unknown segment as a kind is how
    /// `tskey-<secret>` came to be redacted as `tskey-<secret>-<redacted>` —
    /// the credential preserved verbatim with a placeholder appended, by the
    /// function whose entire job is to prevent exactly that. An unrecognised
    /// kind now redacts from immediately after `tskey-`, which at worst loses
    /// one diagnostic word and at best loses nothing at all.
    private static let authKeyKinds: Set<String> = [
        "auth", "client", "api", "scope", "webhook"
    ]

    /// Replace every auth key embedded anywhere in `word`, or nil when there
    /// is none.
    private static func redactAuthKeys(in word: String) -> String? {
        let marker = "tskey-"
        let characters = Array(word)
        let markerCharacters = Array(marker)
        var out = ""
        var index = 0
        var found = false

        while index < characters.count {
            let fits = index + markerCharacters.count <= characters.count
            let matches =
                fits
                && String(characters[index..<(index + markerCharacters.count)]).lowercased()
                    == marker
            guard
                matches,
                index == 0 || tokenDelimiters.contains(characters[index - 1])
            else {
                out.append(characters[index])
                index += 1
                continue
            }
            // The key runs to the end of its `-`-joined alphanumeric run.
            var end = index
            while end < characters.count, isKeyCharacter(characters[end]) { end += 1 }
            let key = String(characters[index..<end])
            out += redactedAuthKey(key)
            found = true
            index = end
        }
        return found ? out : nil
    }

    /// `tskey-auth-…` → `tskey-auth-<redacted>`; anything whose kind is not
    /// recognised → `tskey-<redacted>`, secret and all.
    private static func redactedAuthKey(_ key: String) -> String {
        let parts = key.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3, authKeyKinds.contains(parts[1].lowercased()) else {
            // Covers the bare `tskey-<secret>` form and any kind this build has
            // never heard of. Which kind it was is worth less than the
            // certainty that nothing after `tskey-` survived.
            return "tskey-\(placeholder)"
        }
        return "\(parts[0])-\(parts[1])-\(placeholder)"
    }

    private static func isKeyCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-")
    }

    /// Characters that can precede a token and still leave it a token.
    ///
    /// A token is only recognised at the start of the word or straight after
    /// one of these, which is what keeps ordinary prose intact: without the
    /// rule, any long word containing `tc` would be a candidate. They are the
    /// separators the real carriers use — `token=`, `"token":`, `?token=`,
    /// `&token=`, and the `#` of a web-viewer fragment.
    private static let tokenDelimiters: Set<Character> = [
        "=", ":", "\"", "'", "?", "#", "&", "/",
        // Bracketing and list punctuation: a credential shows up as
        // `(tskey-auth-…)` in a parenthesised error, `[tc…]`, or after a comma
        // in a joined list. None of these can be part of a token or a key, so
        // treating them as boundaries costs nothing and closes the gap.
        "(", "[", "{", "<", ",", "|"
    ]

    /// Replace every share token embedded anywhere in `word`, or nil when
    /// there is none.
    ///
    /// Returns the word with each token swapped for its fingerprint and
    /// everything around it — the key, the punctuation, the rest of the URL —
    /// left intact, because that surrounding text is what tells a reader
    /// *which* thing was redacted.
    private static func redactTokens(in word: String) -> String? {
        let characters = Array(word)
        var out = ""
        var index = 0
        var found = false

        while index < characters.count {
            guard
                characters[index] == "t", index + 1 < characters.count,
                characters[index + 1] == "c",
                index == 0 || tokenDelimiters.contains(characters[index - 1])
            else {
                out.append(characters[index])
                index += 1
                continue
            }
            // Take the longest base64url run from here; that is the token's
            // own alphabet, so it stops exactly where the token does.
            var end = index
            while end < characters.count, isBase64URL(characters[end]) { end += 1 }
            let candidate = String(characters[index..<end])
            // `isPlausibleToken` is the repo's one definition of the shape,
            // shared with the join field — deliberately not a second opinion
            // about what a token looks like.
            if ShareLinkFormat.isPlausibleToken(candidate) {
                out += "tc:\(fingerprint(candidate))"
                found = true
                index = end
            } else {
                out.append(characters[index])
                index += 1
            }
        }
        return found ? out : nil
    }

    private static func isBase64URL(_ character: Character) -> Bool {
        character.isASCII
            && (character.isLetter || character.isNumber || character == "-" || character == "_")
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
