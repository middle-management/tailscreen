import Foundation

/// What must never reach a diagnostics bundle, removed at the moment of
/// recording, not at export.
///
/// The line: capabilities are redacted (a share token, auth key, or login
/// URL grants permission to anyone holding it — replaced by a fingerprint,
/// since a fingerprint answers every troubleshooting question a raw value
/// does). Identifiers are kept (tailnet IPs, device names, peer hostnames —
/// what makes a bundle legible and lets two sides merge; not secrets in the
/// capability sense, and disclosed via ``DiagnosticsBundle/Header/contentNotice``).
///
/// Scrubbing is defence in depth, not the primary mechanism — no call site
/// records a secret directly, but free-text fields (a caught error's
/// description, a captured log line) are written by code with no idea it
/// feeds a recorder. Every string is scrubbed on the way **in**, not on
/// export, since an unredacted recorder is one forgotten export path from a leak.
public enum DiagnosticsRedaction {

    /// What a redacted value is replaced with, when there is nothing
    /// meaningful to keep.
    public static let placeholder = "<redacted>"

    /// Scrub every string value in a field set. Keys are left alone — they
    /// come from instrumentation, never user data, and scrubbing one would break joins.
    public static func scrub(_ fields: [String: DiagnosticValue]) -> [String: DiagnosticValue] {
        // Copy-on-write: `var scrubbed = fields` doesn't copy until the first
        // mutation, so the common all-clean case pays nothing.
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

    /// Scrub one free-text string. Word-wise, not regex — a scanner with no
    /// catastrophic backtracking belongs on a path that runs inside a lock.
    public static func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        // Cheap pre-filter: nearly every recorded string has none of these.
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
            // Split on whitespace only — punctuation (`://`, `-`, `_`, `=`)
            // occurs inside the blobs being matched.
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
        // Strip trailing sentence punctuation so "…token=tcABC." matches, put it back after.
        let trailing = word.suffix(while: { ".,;:!?)]}\"'".contains($0) })
        let core = String(word.dropLast(trailing.count))
        guard !core.isEmpty else { return word }

        if let replacement = redactCore(core) {
            return replacement + trailing
        }
        return word
    }

    /// The three shapes, applied in sequence, since one value can carry more
    /// than one credential — returning on the first match let
    /// `token=tc…&authKey=tskey-auth-…` leak the auth key.
    private static func redactCore(_ core: String) -> String? {
        var value = core
        var changed = false

        // 1. Share tokens, anywhere in the word: `token=tc…`,
        //    `"token":"tc…"`, `tailscreen://join?token=tc…`, `…/view/#tc…`.
        if let redacted = redactTokens(in: value) {
            value = redacted
            changed = true
        }

        // 2. An interactive login URL.
        if let redacted = redactLoginURLPath(in: value) {
            value = redacted
            changed = true
        }

        // 3. A tailnet auth key, anywhere in the word: `authKey=tskey-auth-…`.
        if let redacted = redactAuthKeys(in: value) {
            value = redacted
            changed = true
        }

        return changed ? value : nil
    }

    /// Replace an interactive login URL's secret path, keeping its origin
    /// (Tailscale's is `https://login.tailscale.com/a/<secret>`; a
    /// self-hosted control server is the same shape elsewhere, so matching
    /// scheme-and-path beats a hostname allowlist). The origin is a real
    /// troubleshooting answer, not the secret.
    private static func redactLoginURLPath(in word: String) -> String? {
        guard let scheme = word.range(of: "://") else { return nil }
        let afterScheme = word[scheme.upperBound...]
        // No path at all is a bare origin, which carries nothing.
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let origin = word[word.startIndex..<slash]
        let path = String(afterScheme[slash...])
        // The docs links this app shows the user stay whole.
        guard !isWellKnownPublicPath(path) else { return nil }
        // Length measured with anything an earlier step already redacted
        // subtracted out, so a share link's fingerprint (`…/view/#tc:9f21…`)
        // survives while a login URL that also carried a token still redacts.
        guard residualLength(of: path) > 8 else { return nil }
        return "\(origin)/\(placeholder)"
    }

    /// How much of `path` is not already a redaction marker this pass wrote.
    private static func residualLength(of path: String) -> Int {
        var rest = path.replacingOccurrences(of: placeholder, with: "")
        // `tc:` plus its hex fingerprint.
        while let marker = rest.range(of: "tc:") {
            var end = marker.upperBound
            while end < rest.endIndex, rest[end].isHexDigit {
                end = rest.index(after: end)
            }
            rest.removeSubrange(marker.lowerBound..<end)
        }
        return rest.count
    }

    /// The key *kinds* Tailscale puts between `tskey-` and the secret. An
    /// allowlist: the segment after `tskey-` is either a kind word or the
    /// secret itself, with no way to tell them apart by shape, so an
    /// unrecognised segment redacts from immediately after `tskey-` rather
    /// than risk preserving a secret verbatim.
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
            // Covers the bare `tskey-<secret>` form and any unrecognised kind.
            return "tskey-\(placeholder)"
        }
        return "\(parts[0])-\(parts[1])-\(placeholder)"
    }

    private static func isKeyCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-")
    }

    /// Characters that can precede a token and still leave it a token — the
    /// real carriers' separators (`token=`, `"token":`, `?token=`, `#`),
    /// without which any long word containing `tc` would be a candidate.
    private static let tokenDelimiters: Set<Character> = [
        "=", ":", "\"", "'", "?", "#", "&", "/",
        "(", "[", "{", "<", ",", "|"
    ]

    /// Replace every share token embedded anywhere in `word`, or nil when
    /// there is none. Everything around the token (punctuation, the rest of
    /// the URL) stays intact, so a reader sees which thing was redacted.
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
            // Longest base64url run from here — the token's own alphabet, so it stops where the token does.
            var end = index
            while end < characters.count, isBase64URL(characters[end]) { end += 1 }
            let candidate = String(characters[index..<end])
            // `isPlausibleToken` is the repo's one definition of the shape, shared with the join field.
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
    /// page, the web viewer's base. Redacting these would be pure noise.
    private static func isWellKnownPublicPath(_ path: String) -> Bool {
        let publicPrefixes = ["/docs", "/install", "/troubleshooting", "/usage", "/next"]
        return publicPrefixes.contains { path.hasPrefix($0) }
    }

    /// A short, stable, one-way fingerprint of a secret. FNV-1a, not a
    /// cryptographic hash: this tier is Foundation-only (no CryptoKit on
    /// Linux), and the requirement is linkability, not attacker resistance.
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
