import XCTest

@testable import TailscreenProtocol

/// App Veil — the pure exclusion decision (`AppVeil.effectiveExclusions`),
/// the persisted list (`AppVeilStore` round-trip through an injected
/// `UserDefaults` suite, tri-state enabled default), and the
/// `PickerSelection.excludedBundleIDs` JSON contract (backward-compatible
/// decode, copy helpers). All CI-able; the live capture-side effect
/// (`SCContentFilter(display:excludingApplications:…)`) is local-only.
final class AppVeilTests: XCTestCase {

    /// Scratch `UserDefaults` suite, wiped on teardown so runs don't
    /// contaminate each other (or the developer's real defaults).
    private func makeScratchDefaults() throws -> UserDefaults {
        let name = "app-veil-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: - Pure exclusion decision

    func testDisplayShareExcludesVeiledApps() {
        XCTAssertEqual(
            AppVeil.effectiveExclusions(
                kind: .display, veiled: ["com.a.a", "com.b.b"], enabled: true),
            ["com.a.a", "com.b.b"])
    }

    func testExclusionsAreOrderStableAndDeduped() {
        XCTAssertEqual(
            AppVeil.effectiveExclusions(
                kind: .display,
                veiled: ["com.b.b", "com.a.a", "com.b.b", "", "com.a.a"],
                enabled: true),
            ["com.b.b", "com.a.a"])
    }

    /// A `.window` share captures exactly one window and an `.application`
    /// share's include-list already hides everything not picked — veiling
    /// must not interfere (an explicitly picked app wins over its veil
    /// entry).
    func testNonDisplayKindsNeverExclude() {
        for kind in [PickerSelection.Kind.window, .application] {
            XCTAssertEqual(
                AppVeil.effectiveExclusions(kind: kind, veiled: ["com.a.a"], enabled: true),
                [], "kind \(kind) must not veil")
        }
    }

    func testMasterToggleOffDisablesVeiling() {
        XCTAssertEqual(
            AppVeil.effectiveExclusions(kind: .display, veiled: ["com.a.a"], enabled: false),
            [])
    }

    // MARK: - Store round-trip

    @MainActor
    func testStoreRoundTripsThroughDefaults() throws {
        let defaults = try makeScratchDefaults()
        let store = AppVeilStore(defaults: defaults)
        XCTAssertTrue(store.entries.isEmpty)
        store.add(bundleID: "com.slack.Slack", displayName: "Slack")
        store.add(bundleID: "com.apple.mail", displayName: "Mail")
        XCTAssertTrue(store.isVeiled("com.slack.Slack"))
        XCTAssertFalse(store.isVeiled("com.other.app"))

        // A fresh store over the same suite sees the persisted list, in
        // insertion order.
        let reloaded = AppVeilStore(defaults: defaults)
        XCTAssertEqual(reloaded.entries.map(\.bundleID), ["com.slack.Slack", "com.apple.mail"])
        XCTAssertEqual(reloaded.entries.map(\.displayName), ["Slack", "Mail"])

        reloaded.remove(bundleID: "com.slack.Slack")
        let reloadedAgain = AppVeilStore(defaults: defaults)
        XCTAssertEqual(reloadedAgain.entries.map(\.bundleID), ["com.apple.mail"])
    }

    /// Re-adding a veiled app refreshes its cosmetic display name without
    /// duplicating the entry or bumping its position.
    @MainActor
    func testReAddRefreshesDisplayNameWithoutDuplicating() throws {
        let defaults = try makeScratchDefaults()
        let store = AppVeilStore(defaults: defaults)
        store.add(bundleID: "com.a.a", displayName: "Old Name")
        store.add(bundleID: "com.b.b", displayName: "B")
        store.add(bundleID: "com.a.a", displayName: "New Name")
        XCTAssertEqual(store.entries.map(\.bundleID), ["com.a.a", "com.b.b"])
        XCTAssertEqual(store.entries.first?.displayName, "New Name")
    }

    /// The master toggle defaults **on** for a never-touched install, and
    /// an explicit opt-out sticks across store instances (tri-state read,
    /// same migration shape as `ViewerApprovalDefaults`).
    @MainActor
    func testEnabledTriStateDefault() throws {
        let defaults = try makeScratchDefaults()
        XCTAssertTrue(AppVeilStore(defaults: defaults).isEnabled)

        let store = AppVeilStore(defaults: defaults)
        store.isEnabled = false
        XCTAssertFalse(AppVeilStore(defaults: defaults).isEnabled)
        store.isEnabled = true
        XCTAssertTrue(AppVeilStore(defaults: defaults).isEnabled)
    }

    /// `effectiveExclusions(for:)` is the store-side projection of the pure
    /// decision: kind- and toggle-gated.
    @MainActor
    func testStoreEffectiveExclusions() throws {
        let defaults = try makeScratchDefaults()
        let store = AppVeilStore(defaults: defaults)
        store.add(bundleID: "com.a.a", displayName: "A")
        XCTAssertEqual(store.effectiveExclusions(for: .display), ["com.a.a"])
        XCTAssertEqual(store.effectiveExclusions(for: .window), [])
        XCTAssertEqual(store.effectiveExclusions(for: .application), [])
        store.isEnabled = false
        XCTAssertEqual(store.effectiveExclusions(for: .display), [])
    }

    /// A corrupt persisted blob degrades to an empty list, never a crash.
    @MainActor
    func testCorruptEntriesBlobDegradesToEmpty() throws {
        let defaults = try makeScratchDefaults()
        defaults.set(Data("not json".utf8), forKey: AppVeilStore.entriesKey)
        XCTAssertTrue(AppVeilStore(defaults: defaults).entries.isEmpty)
    }

    // MARK: - PickerSelection JSON contract

    /// The `excludedBundleIDs` field round-trips, and JSON produced by an
    /// older picker-helper (no such key) still decodes, defaulting to `[]`
    /// — the same backward-compat contract as `captureAudio`.
    func testPickerSelectionExcludedBundleIDsRoundTrip() throws {
        let original = PickerSelection(
            kind: .display, displayID: 1, windowID: nil, bundleIDs: [],
            captureAudio: true, excludedBundleIDs: ["com.a.a", "com.b.b"])
        let decoded = try JSONDecoder().decode(
            PickerSelection.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.excludedBundleIDs, ["com.a.a", "com.b.b"])
    }

    func testPickerSelectionOldJSONDecodesToNoExclusions() throws {
        let json = Data(#"{"kind":"display","displayID":1,"bundleIDs":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(PickerSelection.self, from: json)
        XCTAssertEqual(decoded.excludedBundleIDs, [])
    }

    /// The two copy helpers each preserve the other's field, so the
    /// sharer's transform chain (`settingCaptureAudio` then
    /// `settingExcludedBundleIDs`, in either order) loses nothing.
    func testCopyHelpersPreserveEachOther() {
        let base = PickerSelection(
            kind: .display, displayID: 7, windowID: nil, bundleIDs: [])
        let veiledThenAudio =
            base
            .settingExcludedBundleIDs(["com.a.a"])
            .settingCaptureAudio(true)
        XCTAssertEqual(veiledThenAudio.excludedBundleIDs, ["com.a.a"])
        XCTAssertTrue(veiledThenAudio.captureAudio)

        let audioThenVeiled =
            base
            .settingCaptureAudio(true)
            .settingExcludedBundleIDs(["com.a.a"])
        XCTAssertEqual(audioThenVeiled, veiledThenAudio)
        XCTAssertEqual(audioThenVeiled.displayID, 7)
        XCTAssertEqual(audioThenVeiled.kind, .display)
    }
}
