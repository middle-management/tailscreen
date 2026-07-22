import XCTest

@testable import TailscreenProtocol

/// CI-able unit tests for the menubar peer-list filter: the pure
/// `PeerListFilter.matches` decision (hide-offline ∧ any-of-tags with the
/// explicit untagged bucket), the `tag:`-prefix display-name stripping,
/// and the `PeerListFilterStore` persistence round-trip.
final class PeerListFilterTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultPassesEverythingAndIsInactive() {
        let filter = PeerListFilter.default
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.matches(isOnline: true, tags: []))
        XCTAssertTrue(filter.matches(isOnline: false, tags: []))
        XCTAssertTrue(filter.matches(isOnline: true, tags: ["tag:server"]))
        XCTAssertTrue(filter.matches(isOnline: false, tags: ["tag:server", "tag:ci"]))
    }

    // MARK: - Status axis

    func testHideOfflineDropsOnlyOfflinePeers() {
        var filter = PeerListFilter.default
        filter.hideOffline = true
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(isOnline: true, tags: []))
        XCTAssertFalse(filter.matches(isOnline: false, tags: []))
        // Tags don't rescue an offline peer.
        XCTAssertFalse(filter.matches(isOnline: false, tags: ["tag:server"]))
    }

    // MARK: - Tag axis

    func testSelectedTagKeepsOnlyCarriers() {
        var filter = PeerListFilter.default
        filter.selectedTags = ["tag:server"]
        filter.includeUntagged = false
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(isOnline: true, tags: ["tag:server"]))
        XCTAssertFalse(filter.matches(isOnline: true, tags: ["tag:ci"]))
        XCTAssertFalse(filter.matches(isOnline: true, tags: []))
    }

    func testTagMatchIsAnyOf() {
        var filter = PeerListFilter.default
        filter.selectedTags = ["tag:server", "tag:kiosk"]
        // Carrying any one selected tag is enough…
        XCTAssertTrue(filter.matches(isOnline: true, tags: ["tag:kiosk", "tag:other"]))
        // …carrying only unselected tags is not.
        XCTAssertFalse(filter.matches(isOnline: true, tags: ["tag:other"]))
    }

    func testUntaggedBucketIsAnExplicitChoiceWhileTagFilterActive() {
        var filter = PeerListFilter.default
        filter.selectedTags = ["tag:server"]

        filter.includeUntagged = true
        XCTAssertTrue(filter.matches(isOnline: true, tags: []))

        filter.includeUntagged = false
        XCTAssertFalse(filter.matches(isOnline: true, tags: []))
    }

    func testIncludeUntaggedIrrelevantWithoutSelectedTags() {
        // With the tag axis off, the untagged knob must not hide anything —
        // otherwise clearing the last tag would silently keep filtering.
        var filter = PeerListFilter.default
        filter.includeUntagged = false
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.matches(isOnline: true, tags: []))
    }

    func testAxesCombineAsConjunction() {
        var filter = PeerListFilter.default
        filter.hideOffline = true
        filter.selectedTags = ["tag:server"]
        filter.includeUntagged = false
        XCTAssertTrue(filter.matches(isOnline: true, tags: ["tag:server"]))
        XCTAssertFalse(filter.matches(isOnline: false, tags: ["tag:server"]))
        XCTAssertFalse(filter.matches(isOnline: true, tags: ["tag:ci"]))
    }

    // MARK: - Display name

    func testDisplayNameStripsTagPrefix() {
        XCTAssertEqual(PeerListFilter.displayName(forTag: "tag:server"), "server")
        // No prefix → unchanged.
        XCTAssertEqual(PeerListFilter.displayName(forTag: "server"), "server")
        // Only the first prefix is stripped.
        XCTAssertEqual(PeerListFilter.displayName(forTag: "tag:tag:x"), "tag:x")
        // A bare prefix must still yield a clickable label.
        XCTAssertEqual(PeerListFilter.displayName(forTag: "tag:"), "tag:")
    }

    // MARK: - Store persistence

    private func withScratchDefaults(_ body: (UserDefaults) -> Void) throws {
        let suite = "PeerListFilterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    func testStoreMissingKeyLoadsDefault() throws {
        try withScratchDefaults { defaults in
            XCTAssertEqual(PeerListFilterStore.load(from: defaults), .default)
        }
    }

    func testStoreRoundTrip() throws {
        try withScratchDefaults { defaults in
            let filter = PeerListFilter(
                hideOffline: true,
                selectedTags: ["tag:server", "tag:ci"],
                includeUntagged: false)
            PeerListFilterStore.save(filter, to: defaults)
            XCTAssertEqual(PeerListFilterStore.load(from: defaults), filter)
        }
    }

    func testStoreCorruptBlobLoadsDefault() throws {
        try withScratchDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: PeerListFilterStore.key)
            XCTAssertEqual(PeerListFilterStore.load(from: defaults), .default)
        }
    }
}
