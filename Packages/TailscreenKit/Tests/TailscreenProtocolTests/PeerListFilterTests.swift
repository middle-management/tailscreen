import XCTest

@testable import TailscreenProtocol

/// CI-able unit tests for the menubar peer-list filter: the pure
/// `PeerListFilter.matches` decision (hide-offline ∧ only-sharing ∧
/// any-of-tags with the explicit untagged bucket, sharing state tri-state
/// with unknown hiding while the axis is on), the `tag:`-prefix
/// display-name stripping, and the `PeerListFilterStore` persistence
/// round-trip incl. the older-blob decode-with-fallback.
final class PeerListFilterTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultPassesEverythingAndIsInactive() {
        let filter = PeerListFilter.default
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.matches(isOnline: true, tags: []))
        XCTAssertTrue(filter.matches(isOnline: false, tags: []))
        XCTAssertTrue(filter.matches(isOnline: true, tags: ["tag:server"]))
        XCTAssertTrue(filter.matches(isOnline: false, tags: ["tag:server", "tag:ci"]))
        // Sharing state is irrelevant while the axis is off — including
        // unknown and explicitly-not-sharing.
        XCTAssertTrue(filter.matches(isOnline: true, tags: [], sharing: .unknown))
        XCTAssertTrue(filter.matches(isOnline: true, tags: [], sharing: .notSharing))
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

    // MARK: - Sharing axis

    func testOnlySharingKeepsOnlyConfirmedSharers() {
        var filter = PeerListFilter.default
        filter.onlySharing = true
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(isOnline: true, tags: [], sharing: .sharing))
        XCTAssertFalse(filter.matches(isOnline: true, tags: [], sharing: .notSharing))
        // Unknown (no answer yet / legacy peer / offline) hides while the
        // axis is on — the user asked for screens they can actually watch.
        XCTAssertFalse(filter.matches(isOnline: true, tags: [], sharing: .unknown))
    }

    func testOnlySharingConjoinsWithOtherAxes() {
        var filter = PeerListFilter.default
        filter.onlySharing = true
        filter.selectedTags = ["tag:server"]
        filter.includeUntagged = false
        // Sharing but wrong tag → hidden; tagged but not sharing → hidden.
        XCTAssertFalse(filter.matches(isOnline: true, tags: ["tag:ci"], sharing: .sharing))
        XCTAssertFalse(filter.matches(isOnline: true, tags: ["tag:server"], sharing: .notSharing))
        XCTAssertTrue(filter.matches(isOnline: true, tags: ["tag:server"], sharing: .sharing))
    }

    func testSharingStateProjectionFromFetchedMetadata() {
        XCTAssertEqual(PeerSharingState(fetched: nil), .unknown)
        let idle = TailscreenMetadata(
            shareName: "", hostname: "wisp-2",
            screenResolution: .init(width: 1, height: 1),
            isSharing: false, timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(PeerSharingState(fetched: idle), .notSharing)
        let live = TailscreenMetadata(
            shareName: "s", hostname: "wisp-1",
            screenResolution: .init(width: 1, height: 1),
            isSharing: true, timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(PeerSharingState(fetched: live), .sharing)
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
                includeUntagged: false,
                onlySharing: true)
            PeerListFilterStore.save(filter, to: defaults)
            XCTAssertEqual(PeerListFilterStore.load(from: defaults), filter)
        }
    }

    func testStoreOlderBlobWithoutOnlySharingLoadsWithAxisOff() throws {
        // A blob persisted before the sharing axis existed must load with
        // the new axis off and every stored choice intact — NOT reset the
        // whole filter to `.default` via the decode-failure path.
        try withScratchDefaults { defaults in
            let legacyJSON = """
                {"hideOffline":true,"selectedTags":["tag:server"],"includeUntagged":false}
                """
            defaults.set(Data(legacyJSON.utf8), forKey: PeerListFilterStore.key)
            let loaded = PeerListFilterStore.load(from: defaults)
            XCTAssertTrue(loaded.hideOffline)
            XCTAssertEqual(loaded.selectedTags, ["tag:server"])
            XCTAssertFalse(loaded.includeUntagged)
            XCTAssertFalse(loaded.onlySharing)
        }
    }

    func testStoreCorruptBlobLoadsDefault() throws {
        try withScratchDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: PeerListFilterStore.key)
            XCTAssertEqual(PeerListFilterStore.load(from: defaults), .default)
        }
    }
}
