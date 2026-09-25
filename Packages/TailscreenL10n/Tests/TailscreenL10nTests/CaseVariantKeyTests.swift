import XCTest

@testable import TailscreenL10n

/// Fails when two base-catalog keys are the same sentence up to case and
/// trailing punctuation — the pattern where "Stop Sharing" and "Stop sharing"
/// both exist and get translated twice, eventually differently.
///
/// Not every near-pair is a mistake (a Title Case menu item vs. a
/// sentence-case status line), so legitimate pairs live in the allowlist
/// below with their reason. A new collision fails: merge the keys, or
/// allowlist with a justification.
final class CaseVariantKeyTests: XCTestCase {
    /// Pairs kept deliberately, as sets of the exact keys. Grouped by why.
    private static let allowlist: [Set<String>] = [
        // macOS alert titles are Title Case; the sentence-case twin is a
        // GTK/WinUI status/placard line. Merging would break one surface's consistency.
        ["Connection Failed", "Connection failed"],
        ["Microphone Unavailable", "Microphone unavailable"],
        // macOS menu-bar items are Title Case; the sentence-case twin is
        // descriptive text or a tooltip whose sibling keys must stay sentence case.
        ["Clear All Annotations", "Clear all annotations"],
        ["Release Remote Control", "Release remote control"],
        ["Mute Microphone", "Mute microphone"],
        ["Unmute Microphone", "Unmute microphone"],
        // Windows' standalone detail sentence vs. Linux's mid-sentence clause
        // after "Share failed: " — lowercase is grammar, not drift.
        [
            "Could not change the shared source: %@",
            "could not change the shared source: %@"
        ],
        // Standalone status badge vs. lowercase interpolated into the
        // accessibility sentence — different grammatical positions.
        ["Offline", "offline"],
        ["Online", "online"]
    ]

    private var baseCatalogURL: URL {
        // …/Packages/TailscreenL10n/Tests/TailscreenL10nTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TailscreenL10nTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // TailscreenL10n
            .appendingPathComponent("Sources/TailscreenL10n/Resources")
            .appendingPathComponent("en.lproj/Localizable.strings")
    }

    /// Case-fold and strip trailing whitespace/periods/ellipses repeatedly, so
    /// "Change Source…" ~ "Change source…".
    static func normalized(_ key: String) -> String {
        var text = Substring(key)
        while let last = text.last,
            last == " " || last == "\t" || last == "\n" || last == "." || last == "…"
        {
            text = text.dropLast()
        }
        return text.lowercased()
    }

    /// The offending groups in `keys`: every set of two or more keys that
    /// collide under ``normalized(_:)`` and are not an allowlisted set.
    static func collisions(in keys: [String], allowing allowlist: [Set<String>]) -> [[String]] {
        var groups: [String: [String]] = [:]
        for key in keys {
            groups[normalized(key), default: []].append(key)
        }
        return
            groups.values
            .filter { $0.count > 1 && !allowlist.contains(Set($0)) }
            .map { $0.sorted() }
            .sorted { ($0.first ?? "") < ($1.first ?? "") }
    }

    func testBaseCatalogHasNoUnlistedCaseVariantKeys() throws {
        guard FileManager.default.fileExists(atPath: baseCatalogURL.path) else {
            throw XCTSkip("source tree not available (tests running outside the repo)")
        }
        let keys = Array(
            StringsFile.parse(text: try String(contentsOf: baseCatalogURL, encoding: .utf8)).keys)
        XCTAssertGreaterThan(keys.count, 400, "catalog parsed to too few keys — parser broken?")

        let offending = Self.collisions(in: keys, allowing: Self.allowlist)
        XCTAssertTrue(
            offending.isEmpty,
            "catalog keys that are the same sentence up to case/trailing punctuation — "
                + "merge onto one key (and update call sites + translations), or allowlist "
                + "the pair in CaseVariantKeyTests with a reason:\n"
                + offending.map { $0.joined(separator: "  |  ") }.joined(separator: "\n"))
    }

    /// Every allowlist entry must still name real, colliding catalog keys —
    /// otherwise it's a stale exemption that could cover a future collision.
    func testAllowlistEntriesAreLiveAndColliding() throws {
        guard FileManager.default.fileExists(atPath: baseCatalogURL.path) else {
            throw XCTSkip("source tree not available")
        }
        let catalog = Set(
            StringsFile.parse(text: try String(contentsOf: baseCatalogURL, encoding: .utf8)).keys)
        for entry in Self.allowlist {
            XCTAssertGreaterThan(entry.count, 1, "allowlist entry \(entry) is not a pair")
            XCTAssertEqual(
                Set(entry.map(Self.normalized)).count, 1,
                "allowlist entry \(entry) does not collide under normalization — stale?")
            for key in entry {
                XCTAssertTrue(
                    catalog.contains(key),
                    "allowlist names \"\(key)\", which is no longer in the catalog — "
                        + "remove the stale entry")
            }
        }
    }

    /// Guards against the detector trivially always returning empty.
    func testDetectorFindsAPlantedCollision() {
        let keys = ["Stop Sharing", "Stop sharing…", "Viewer", "viewers"]
        let found = Self.collisions(in: keys, allowing: [])
        XCTAssertEqual(found, [["Stop Sharing", "Stop sharing…"]])
        XCTAssertTrue(
            Self.collisions(in: keys, allowing: [["Stop Sharing", "Stop sharing…"]]).isEmpty)
    }
}
