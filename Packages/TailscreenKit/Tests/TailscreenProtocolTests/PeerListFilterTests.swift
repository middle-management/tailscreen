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

/// The cache behind the sharing chip: what a metadata sweep's answers do to the
/// per-peer status map.
///
/// Two lines of code in each hub, and every hub had written them slightly
/// differently — which is exactly the shape of divergence nothing catches,
/// because both spellings compile, both render a plausible list, and the wrong
/// one only shows up as an invitation to connect to a share that already ended.
final class PeerShareStatusMapTests: XCTestCase {
    private func metadata(isSharing: Bool) -> TailscreenMetadata {
        TailscreenMetadata(
            shareName: "Display 1", hostname: "robert-macbook",
            screenResolution: .init(width: 1920, height: 1080),
            isSharing: isSharing, timestamp: Date(timeIntervalSince1970: 0))
    }

    func testAnAnswerIsRecorded() {
        let map = PeerShareStatusMap.recording(metadata(isSharing: true), for: "a", in: [:])
        XCTAssertEqual(PeerSharingState(fetched: map["a"]), .sharing)
    }

    func testANoAnswerClearsAPreviousAnswer() {
        // THE decision. `nil` is status-unknown — a timeout, an EOF, a legacy
        // build dropping the unknown byte — and never evidence about what that
        // machine is doing now. Keeping the last answer is stale-positive by
        // construction: a peer that stops sharing and stops answering in the
        // same window keeps saying "Sharing" until it answers again.
        let seeded = ["a": metadata(isSharing: true)]
        let map = PeerShareStatusMap.recording(nil, for: "a", in: seeded)
        XCTAssertNil(map["a"])
        XCTAssertEqual(PeerSharingState(fetched: map["a"]), .unknown)
    }

    func testRecordingOnePeerLeavesTheOthersAlone() {
        let seeded = ["a": metadata(isSharing: true), "b": metadata(isSharing: false)]
        let map = PeerShareStatusMap.recording(nil, for: "a", in: seeded)
        XCTAssertEqual(PeerSharingState(fetched: map["b"]), .notSharing)
    }

    func testPruningDropsPeersNoLongerPresent() {
        // A departed peer keeping its last answer means the same id returning
        // later shows a stale chip until its next probe lands.
        let seeded = ["a": metadata(isSharing: true), "gone": metadata(isSharing: true)]
        let map = PeerShareStatusMap.pruned(seeded, toPresent: ["a"])
        XCTAssertEqual(map.keys.sorted(), ["a"])
    }

    func testPruningToNothingEmptiesTheMap() {
        let seeded = ["a": metadata(isSharing: true)]
        XCTAssertTrue(PeerShareStatusMap.pruned(seeded, toPresent: []).isEmpty)
    }

    func testPruningKeepsEveryPresentPeer() {
        let seeded = ["a": metadata(isSharing: true), "b": metadata(isSharing: false)]
        let map = PeerShareStatusMap.pruned(seeded, toPresent: ["a", "b", "c"])
        XCTAssertEqual(map.keys.sorted(), ["a", "b"])
    }
}
