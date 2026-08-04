import XCTest

@testable import TailscreenL10n

/// Guards the CLAUDE.md invariant that every `L("…")` call-site key in every
/// app's sources exists byte-for-byte in the base catalog.
///
/// It moved here from `Apps/macOS/Tests` when the catalog became shared. Two
/// things changed with the move and both matter: it now scans **all four**
/// source trees (three apps plus the chrome they share) rather than one, and
/// it runs on **Linux CI**, which is the only machine that builds the GTK and
/// WinUI apps' sources on every PR. A catalog test that only ran on macOS
/// would have watched the mac app's keys and let the other two rot.
///
/// Interpolated call sites (`L("Viewing \(host)")`) are matched against their
/// format-specifier form in the catalog (`"Viewing %@"`) via the SAME
/// normalizer the runtime lookup uses, so the test cannot pass on a
/// correspondence the app itself does not make.
///
/// Reads only the repository source tree, located relative to `#filePath`.
final class LocalizationCatalogTests: XCTestCase {
    /// Placeholder both sides normalize to. Shared with the runtime, which is
    /// the point: `LocalizationFormat.normalizeSpecifiers` is what the catalog
    /// lookup falls back to when an exact key misses.
    private static let placeholder = LocalizationFormat.specifierPlaceholder

    /// Every tree whose `L("…")` keys this catalog has to cover.
    private static let sourceTrees = [
        "Apps/macOS/Sources",
        "Apps/linux/Sources",
        "Apps/windows/Sources",
        "Packages/TailscreenHubUI/Sources",
    ]

    private static let catalogRoot =
        "Packages/TailscreenL10n/Sources/TailscreenL10n/Resources"

    private var repoRoot: URL {
        // …/Packages/TailscreenL10n/Tests/TailscreenL10nTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TailscreenL10nTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // TailscreenL10n
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
    }

    private func catalogURL(_ language: String) -> URL {
        repoRoot
            .appendingPathComponent(Self.catalogRoot)
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
    }

    func testEveryLCallSiteKeyExistsInCatalog() throws {
        let base = catalogURL("en")
        guard FileManager.default.fileExists(atPath: base.path) else {
            throw XCTSkip("source tree not available (tests running outside the repo)")
        }
        let catalog = Set(
            StringsFile.parse(text: try String(contentsOf: base, encoding: .utf8)).keys
                .map(LocalizationFormat.normalizeSpecifiers))
        XCTAssertFalse(catalog.isEmpty, "catalog parsed to zero keys — parser broken?")

        var missing: [String] = []
        var callSites = 0
        var scannedTrees = 0

        for tree in Self.sourceTrees {
            let root = repoRoot.appendingPathComponent(tree)
            let files = try Self.swiftFiles(under: root)
            XCTAssertFalse(files.isEmpty, "no Swift sources under \(tree) — path math broken?")
            scannedTrees += 1
            for file in files {
                let text = Self.stripLineComments(try String(contentsOf: file, encoding: .utf8))
                for key in Self.scanLKeys(text) {
                    callSites += 1
                    if !catalog.contains(key) {
                        missing.append("\(tree)/\(file.lastPathComponent): \"\(key)\"")
                    }
                }
            }
        }

        XCTAssertEqual(scannedTrees, Self.sourceTrees.count)
        XCTAssertGreaterThan(callSites, 400, "suspiciously few L() call sites — scanner broken?")
        XCTAssertTrue(
            missing.isEmpty,
            "L() keys missing from en.lproj/Localizable.strings "
                + "(add them, byte-for-byte, with interpolations as %@/%lld):\n"
                + missing.joined(separator: "\n"))
    }

    /// A translation may lag the base catalog — a missing key falls back to
    /// English by design — but it may not contain keys the base does not, and
    /// it may not disagree with the base about how many values a string takes.
    ///
    /// Both failures are silent in the app. An orphaned key is a translation
    /// that stopped being used when someone reworded the English and will
    /// never be seen again; a specifier mismatch renders a sentence with a
    /// value missing from it, in one language only.
    func testTranslationsAgreeWithTheBaseCatalog() throws {
        let base = catalogURL("en")
        guard FileManager.default.fileExists(atPath: base.path) else {
            throw XCTSkip("source tree not available")
        }
        let english = StringsFile.parse(text: try String(contentsOf: base, encoding: .utf8))

        let root = repoRoot.appendingPathComponent(Self.catalogRoot)
        let languages = LocalizationCatalog.availableLocalizations(in: root).filter { $0 != "en" }
        XCTAssertFalse(languages.isEmpty, "no translations found — path math broken?")

        for language in languages {
            let table = StringsFile.parse(
                text: try String(contentsOf: catalogURL(language), encoding: .utf8))
            XCTAssertFalse(table.isEmpty, "\(language).lproj parsed to zero keys")

            let orphans = table.keys.filter { english[$0] == nil }.sorted()
            XCTAssertTrue(
                orphans.isEmpty,
                "\(language).lproj has keys the base catalog does not — reworded or removed "
                    + "in English without updating the translation:\n"
                    + orphans.joined(separator: "\n"))

            for (key, value) in table where english[key] != nil {
                XCTAssertEqual(
                    Self.argumentCount(in: key), Self.argumentCount(in: value),
                    "\(language).lproj: \"\(key)\" and its translation take different values")
            }
        }
    }

    // MARK: - Helpers

    /// Recursive walk, hand-rolled rather than `FileManager.enumerator` —
    /// that returns an `NSEnumerator`, whose `Sequence` conformance is an
    /// overlay detail this test would rather not depend on given it has to run
    /// on Linux as well as Darwin.
    private static func swiftFiles(under root: URL) throws -> [URL] {
        var found: [URL] = []
        var pending = [root]
        while let directory = pending.popLast() {
            let entries =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for entry in entries {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: entry.path, isDirectory: &isDirectory)
                if exists, isDirectory.boolValue {
                    pending.append(entry)
                } else if entry.pathExtension == "swift" {
                    found.append(entry)
                }
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// How many values a format string consumes. Position and length are
    /// deliberately ignored — `%1$@`, `%@` and `%lld` are all one value, and a
    /// translation is free to reorder or retype them (the renderer takes each
    /// argument from the list, not from the conversion character). Dropping or
    /// inventing one is the failure worth catching.
    static func argumentCount(in text: String) -> Int {
        LocalizationFormat.normalizeSpecifiers(text)
            .components(separatedBy: placeholder).count - 1
    }

    /// Drop whole-line `//` comments so doc-comment examples like
    /// `L("Viewing \(host)")` in Localization.swift aren't treated as call
    /// sites. String-aware lexing is deliberately not attempted — trailing
    /// comments containing `L("` don't occur in this codebase.
    static func stripLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Find every `L("…")` string literal in `text` and return its normalized
    /// key: interpolations (`\(…)`, with nested parens and nested string
    /// literals handled) become the placeholder; standard escapes are
    /// resolved. Nested calls like `L("… \(flag ? L("a") : L("b")) …")` yield
    /// the outer key *and* each inner key.
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

    /// Resolve the escape sequences Swift string literals and .strings files
    /// share: `\"`, `\\`, `\n`, `\t`.
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
