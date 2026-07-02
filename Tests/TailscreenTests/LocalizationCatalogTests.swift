import XCTest

@testable import Tailscreen

/// Guards the CLAUDE.md invariant that every `L("…")` call-site key in
/// `Sources/` exists byte-for-byte in the base catalog
/// (`Sources/Resources/en.lproj/Localizable.strings`). Interpolated call
/// sites (`L("Viewing \(host)")`) are matched against their format-specifier
/// form in the catalog (`"Viewing %@"`). Runs on CI — it only reads the
/// repository source tree, located relative to `#filePath`.
final class LocalizationCatalogTests: XCTestCase {
    /// Placeholder both sides normalize to: call-site interpolations
    /// (`\(…)`) and catalog format specifiers (`%@`, `%lld`, …). NUL can't
    /// appear in real keys, so it never collides.
    private static let placeholder = "\u{0}ARG"

    private var repoRoot: URL {
        // …/Tests/TailscreenTests/LocalizationCatalogTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testEveryLCallSiteKeyExistsInCatalog() throws {
        let catalogURL =
            repoRoot
            .appendingPathComponent("Sources/Resources/en.lproj/Localizable.strings")
        let sourcesURL = repoRoot.appendingPathComponent("Sources")
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            throw XCTSkip("source tree not available (tests running outside the repo)")
        }

        let catalogText = try String(contentsOf: catalogURL, encoding: .utf8)
        let catalog = Set(try Self.parseCatalogKeys(catalogText).map { try Self.normalizeCatalogKey($0) })
        XCTAssertFalse(catalog.isEmpty, "catalog parsed to zero keys — parser broken?")

        var missing: [String] = []
        var callSites = 0
        let files = try FileManager.default.contentsOfDirectory(
            at: sourcesURL, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        XCTAssertFalse(files.isEmpty, "no Swift sources found — path math broken?")

        for file in files {
            let text = Self.stripLineComments(try String(contentsOf: file, encoding: .utf8))
            for key in Self.scanLKeys(text) {
                callSites += 1
                if !catalog.contains(key) {
                    missing.append("\(file.lastPathComponent): \"\(key)\"")
                }
            }
        }

        XCTAssertGreaterThan(callSites, 100, "suspiciously few L() call sites — scanner broken?")
        XCTAssertTrue(
            missing.isEmpty,
            "L() keys missing from en.lproj/Localizable.strings "
                + "(add them, byte-for-byte, with interpolations as %@/%lld):\n"
                + missing.joined(separator: "\n"))
    }

    // MARK: - Catalog parsing

    /// Extract the key of every `"key" = "value";` line. Keys/values may
    /// contain escaped quotes.
    static func parseCatalogKeys(_ text: String) throws -> [String] {
        let pattern = #"^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"(?:[^"\\]|\\.)*"\s*;\s*$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let ns = text as NSString
        var keys: [String] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            keys.append(unescape(ns.substring(with: match.range(at: 1))))
        }
        return keys
    }

    /// Replace printf-style format specifiers (including positional forms
    /// like `%1$@`) with the shared placeholder.
    static func normalizeCatalogKey(_ key: String) throws -> String {
        let pattern = #"%(?:\d+\$)?(?:@|lld|ld|d|u|f|s)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = key as NSString
        return regex.stringByReplacingMatches(
            in: key, range: NSRange(location: 0, length: ns.length),
            withTemplate: placeholder)
    }

    // MARK: - Source scanning

    /// Drop whole-line `//` comments so doc-comment examples like
    /// `L("Viewing \(host)")` in Localization.swift aren't treated as call
    /// sites. String-aware lexing is deliberately not attempted — trailing
    /// comments containing `L("` don't occur in this codebase.
    static func stripLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Find every `L("…")` string literal in `text` and return its
    /// normalized key: interpolations (`\(…)`, with nested parens and nested
    /// string literals handled) become the placeholder; standard escapes are
    /// resolved. Nested calls like `L("… \(flag ? L("a") : L("b")) …")`
    /// yield the outer key *and* each inner key.
    static func scanLKeys(_ text: String) -> [String] {
        var keys: [String] = []
        let chars = Array(text)
        let n = chars.count
        var i = 0
        while i < n {
            // Find the next standalone `L(`.
            guard chars[i] == "L", i + 1 < n, chars[i + 1] == "(" else {
                i += 1
                continue
            }
            if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_" {
                i += 2
                continue
            }
            var k = i + 2
            while k < n, chars[k] == " " || chars[k] == "\t" || chars[k] == "\n" || chars[k] == "\r" {
                k += 1
            }
            guard k < n, chars[k] == "\"" else {
                i += 2
                continue
            }
            k += 1
            var raw = ""
            while k < n, chars[k] != "\"" {
                if chars[k] == "\\" {
                    if k + 1 < n, chars[k + 1] == "(" {
                        // Interpolation: skip to the matching paren, tracking
                        // nesting and string literals inside it. Inner `L(`
                        // calls are picked up by the outer while-loop later
                        // because we only advance `i` past the *outer* L(.
                        var depth = 1
                        k += 2
                        while k < n, depth > 0 {
                            switch chars[k] {
                            case "\"":
                                k += 1
                                while k < n, chars[k] != "\"" {
                                    if chars[k] == "\\" { k += 1 }
                                    k += 1
                                }
                            case "(": depth += 1
                            case ")": depth -= 1
                            default: break
                            }
                            k += 1
                        }
                        raw += placeholder
                        continue
                    }
                    if k + 1 < n {
                        raw.append(chars[k])
                        raw.append(chars[k + 1])
                        k += 2
                        continue
                    }
                }
                raw.append(chars[k])
                k += 1
            }
            keys.append(unescape(raw))
            // Resume *inside* what we just scanned so nested L( calls within
            // interpolations are found too.
            i += 2
        }
        return keys
    }

    /// Resolve the escape sequences Swift string literals and .strings
    /// files share: `\"`, `\\`, `\n`, `\t`.
    static func unescape(_ s: String) -> String {
        var out = ""
        var iter = s.makeIterator()
        while let c = iter.next() {
            guard c == "\\" else {
                out.append(c)
                continue
            }
            guard let next = iter.next() else {
                out.append(c)
                break
            }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            default: out.append(next)
            }
        }
        return out
    }
}
