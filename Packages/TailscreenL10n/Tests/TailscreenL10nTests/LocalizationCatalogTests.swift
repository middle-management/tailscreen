import XCTest

@testable import TailscreenL10n

/// Guards the CLAUDE.md invariant that every `L("…")` call-site key in every
/// app's sources exists byte-for-byte in the base catalog. Scans all four
/// source trees (three apps plus their shared chrome) and runs on Linux CI —
/// the only machine that builds the GTK/WinUI sources on every PR.
///
/// Interpolated call sites (`L("Viewing \(host)")`) are matched against the
/// catalog's specifier form (`"Viewing %@"`) via the same normalizer the
/// runtime lookup uses. Reads the repository source tree relative to `#filePath`.
final class LocalizationCatalogTests: XCTestCase {
    private static let placeholder = LocalizationFormat.specifierPlaceholder

    /// Every tree whose `L("…")` keys this catalog has to cover.
    private static let sourceTrees = [
        "Apps/macOS/Sources",
        "Apps/linux/Sources",
        "Apps/windows/Sources",
        "Packages/TailscreenHubUI/Sources"
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

    /// Inverse of `testEveryLCallSiteKeyExistsInCatalog`: every base catalog
    /// key must be reachable from some `L("…")` call site, or it's an orphan
    /// that gets translated in every language and never rendered.
    func testEveryCatalogKeyHasACallSite() throws {
        let base = catalogURL("en")
        guard FileManager.default.fileExists(atPath: base.path) else {
            throw XCTSkip("source tree not available (tests running outside the repo)")
        }
        let catalog = StringsFile.parse(text: try String(contentsOf: base, encoding: .utf8))
        XCTAssertFalse(catalog.isEmpty, "catalog parsed to zero keys — parser broken?")

        var reachable: Set<String> = []
        for tree in Self.sourceTrees {
            let root = repoRoot.appendingPathComponent(tree)
            for file in try Self.swiftFiles(under: root) {
                let text = Self.stripLineComments(try String(contentsOf: file, encoding: .utf8))
                reachable.formUnion(Self.scanLKeys(text))
            }
        }
        XCTAssertGreaterThan(
            reachable.count, 300, "suspiciously few distinct L() keys — scanner broken?")

        // Compare in normalized form — the same correspondence the runtime lookup makes.
        let orphans =
            catalog.keys
            .filter { !reachable.contains(LocalizationFormat.normalizeSpecifiers($0)) }
            .filter { !Self.keysWithoutASwiftCallSite.contains($0) }
            .sorted()

        XCTAssertTrue(
            orphans.isEmpty,
            "en.lproj/Localizable.strings carries keys no L(\"…\") call site can reach. "
                + "Delete them (and the same key from every <lang>.lproj), or add the key to "
                + "`keysWithoutASwiftCallSite` with a reason if it is reached some other way:\n"
                + orphans.joined(separator: "\n"))
    }

    /// Catalog keys that legitimately have no `L("…")` call site in any scanned
    /// tree. Each needs a reason: the point of the list is that it stays short
    /// enough to read, not that it absorbs whatever the test finds.
    static let keysWithoutASwiftCallSite: Set<String> = [
        // The browser viewer's audio button (web/viewer/viewer.js). No Swift
        // call site; read via `export_strings.py` instead.
        "Enable Audio",
        "Mute Audio",
        "Unmute Audio",
        "Audio Unavailable"
    ]

    /// A translation may lag the base catalog (missing key falls back to
    /// English), but may not carry keys the base doesn't, or disagree with it
    /// on argument count — both fail silently in the app otherwise.
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

    /// Hand-rolled rather than `FileManager.enumerator`, whose `Sequence`
    /// conformance is an overlay detail this shouldn't depend on cross-platform.
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

    /// How many values a format string consumes. Position/type ignored —
    /// `%1$@`, `%@`, `%lld` are all one value; only a wrong count is a failure.
    static func argumentCount(in text: String) -> Int {
        LocalizationFormat.normalizeSpecifiers(text)
            .components(separatedBy: placeholder).count - 1
    }

    /// Drop whole-line `//` comments so doc-comment examples aren't treated
    /// as call sites. No string-aware lexing — trailing `//` comments
    /// containing `L("` don't occur in this codebase.
    static func stripLineComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Find every `L("…")` string literal in `text` and return its normalized
    /// key: interpolations become the placeholder, escapes resolved. Nested
    /// calls like `L("… \(flag ? L("a") : L("b")) …")` yield the outer key
    /// and each inner key.
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
                        // Skip to the matching paren, tracking nesting and
                        // string literals; inner `L(` calls are found later
                        // since `i` only advances past the outer L(.
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
            // Resume inside what we just scanned to find nested L( calls too.
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
