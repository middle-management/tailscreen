import XCTest

@testable import TailscreenL10n

/// Fails when two base-catalog keys are the same sentence up to case and
/// trailing punctuation — the pattern that quietly accumulates when one
/// platform writes "Stop Sharing" and another writes "Stop sharing", and the
/// same sentence gets translated twice (and, eventually, differently: the
/// catalog really did carry "Filtrera efter tagg" AND "Filtrera på tagg").
///
/// Not every near-pair is a mistake — a menu item and a status line can
/// legitimately carry the same words in each surface's casing, and a clause
/// embedded after "Share failed: " needs its lowercase. Those live in the
/// explicit allowlist below, each with the reason it is two keys on purpose.
/// A new collision outside the allowlist fails: either merge the keys onto
/// one variant (updating the call sites and every translation) or, if both
/// are genuinely load-bearing, add the pair here WITH its justification.
final class CaseVariantKeyTests: XCTestCase {
    /// Pairs kept deliberately, as sets of the exact keys. Grouped by why.
    private static let allowlist: [Set<String>] = [
        // macOS alert titles are uniformly Title Case ("Login Failed",
        // "Request Failed", …); the sentence-case twin is a GTK/WinUI status
        // or placard line among sentence-case siblings. Merging either way
        // would break one surface's internal consistency.
        ["Connection Failed", "Connection failed"],
        ["Microphone Unavailable", "Microphone unavailable"],
        // macOS menu-bar items are Title Case beside Title Case neighbors;
        // the sentence-case twin is visible descriptive text (the shortcut
        // cheat sheet's rows) or a tooltip whose chord-carrying sibling keys
        // ("Mute microphone (%@)") must stay sentence case.
        ["Clear All Annotations", "Clear all annotations"],
        ["Release Remote Control", "Release remote control"],
        ["Mute Microphone", "Mute microphone"],
        ["Unmute Microphone", "Unmute microphone"],
        // The Windows sharer's standalone detail sentence vs the Linux
        // sharer's clause rendered after "Share failed: " — the lowercase is
        // mid-sentence grammar, not styling drift.
        [
            "Could not change the shared source: %@",
            "could not change the shared source: %@"
        ],
        // Standalone status badge vs the lowercase interpolated into the
        // "%@, %@" accessibility sentence — different grammatical positions,
        // and languages that decline by position need them separate.
        ["Offline", "offline"],
        ["Online", "online"],
        // Empty-state punctuation is a per-surface convention: the mac hub's
        // empty states carry no terminal period ("No other running apps"),
        // the shared hub's all do ("No screens match your search.").
        ["No screens match your filters", "No screens match your filters."]
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

    /// Case-fold, and strip trailing whitespace, periods and ellipses (both
    /// "…" and "..."), repeatedly — so "Change Source…" ~ "Change source…"
    /// and "No screens match your filters." ~ its period-less twin.
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

    /// Every allowlist entry must still name real catalog keys that still
    /// collide — otherwise it is a stale exemption that would silently cover
    /// a future, different collision.
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

    /// The detector cannot pass by always returning empty: a planted
    /// collision must be found, and the same group allowlisted must not be.
    func testDetectorFindsAPlantedCollision() {
        let keys = ["Stop Sharing", "Stop sharing…", "Viewer", "viewers"]
        let found = Self.collisions(in: keys, allowing: [])
        XCTAssertEqual(found, [["Stop Sharing", "Stop sharing…"]])
        XCTAssertTrue(
            Self.collisions(in: keys, allowing: [["Stop Sharing", "Stop sharing…"]]).isEmpty)
    }
}
