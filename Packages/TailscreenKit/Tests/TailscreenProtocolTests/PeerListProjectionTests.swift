import Foundation
import XCTest

@testable import TailscreenProtocol

/// The shared peer-list projection — `PeerListFilter.narrow` and
/// `knownTags(in:)` — that all three hubs used to hand-write over their own
/// peer type. `PeerListFilterTests` covers the per-peer `matches` decision;
/// this covers what the list does with it.
final class PeerListProjectionTests: XCTestCase {
    /// The protocol is exactly the three fields the projection reads, so this fake is the whole surface.
    private struct Row: PeerListRow, Equatable {
        let id: String
        let isOnline: Bool
        let tags: [String]

        init(_ id: String, isOnline: Bool = true, tags: [String] = []) {
            self.id = id
            self.isOnline = isOnline
            self.tags = tags
        }
    }

    private func metadata(isSharing: Bool) -> TailscreenMetadata {
        TailscreenMetadata(
            shareName: "screen", hostname: "peer",
            screenResolution: .init(width: 1920, height: 1080),
            isSharing: isSharing, timestamp: Date(), videoCodec: .h264)
    }

    // MARK: - narrow

    func testDefaultFilterKeepsEveryRowInOrder() {
        let rows = [Row("a"), Row("b", isOnline: false), Row("c", tags: ["tag:ci"])]
        XCTAssertEqual(PeerListFilter.default.narrow(rows), rows)
    }

    func testHideOfflineNarrowsTheList() {
        var filter = PeerListFilter.default
        filter.hideOffline = true
        let rows = [Row("a"), Row("b", isOnline: false), Row("c")]
        XCTAssertEqual(filter.narrow(rows).map(\.id), ["a", "c"])
    }

    /// A peer with no sweep answer is unknown; `onlySharing` hides unknown rather than treating it as "not sharing".
    func testOnlySharingHidesPeersWithNoSweepAnswer() {
        var filter = PeerListFilter.default
        filter.onlySharing = true
        let rows = [Row("answered"), Row("silent")]
        let shareInfo = ["answered": metadata(isSharing: true)]
        XCTAssertEqual(filter.narrow(rows, shareInfo: shareInfo).map(\.id), ["answered"])
    }

    func testOnlySharingHidesAPeerThatAnsweredNotSharing() {
        var filter = PeerListFilter.default
        filter.onlySharing = true
        let rows = [Row("idle"), Row("live")]
        let shareInfo = [
            "idle": metadata(isSharing: false),
            "live": metadata(isSharing: true)
        ]
        XCTAssertEqual(filter.narrow(rows, shareInfo: shareInfo).map(\.id), ["live"])
    }

    /// A dictionary populated under a different key reads as no answer, not somebody else's status.
    func testSweepAnswersAreMatchedByRowIDNotByPosition() {
        var filter = PeerListFilter.default
        filter.onlySharing = true
        let rows = [Row("first"), Row("second")]
        let shareInfo = ["second": metadata(isSharing: true)]
        XCTAssertEqual(filter.narrow(rows, shareInfo: shareInfo).map(\.id), ["second"])
    }

    func testTagAxisAppliesAcrossTheList() {
        var filter = PeerListFilter.default
        filter.selectedTags = ["tag:studio"]
        filter.includeUntagged = false
        let rows = [Row("a", tags: ["tag:studio"]), Row("b", tags: ["tag:media"]), Row("c")]
        XCTAssertEqual(filter.narrow(rows).map(\.id), ["a"])
    }

    // MARK: - knownTags

    func testKnownTagsIsTheSortedUnionOfEveryRowsTags() {
        let rows = [
            Row("a", tags: ["tag:studio", "tag:ci"]),
            Row("b", tags: ["tag:ci"]),
            Row("c")
        ]
        XCTAssertEqual(
            PeerListFilter.default.knownTags(in: rows), ["tag:ci", "tag:studio"])
    }

    /// Sorted, so a discovery sweep reordering peers doesn't reshuffle the menu under a moving cursor.
    func testKnownTagsOrderIsIndependentOfPeerOrder() {
        let forward = [Row("a", tags: ["tag:zulu"]), Row("b", tags: ["tag:alpha"])]
        let reversed = Array(forward.reversed())
        XCTAssertEqual(
            PeerListFilter.default.knownTags(in: forward),
            PeerListFilter.default.knownTags(in: reversed))
    }

    /// If the menu were derived from present peers alone, a selected tag whose
    /// last peer leaves would vanish from the menu, leaving no way to turn the filter back off.
    func testASelectedTagSurvivesItsLastPeerLeaving() {
        var filter = PeerListFilter.default
        filter.selectedTags = ["tag:studio"]
        XCTAssertEqual(filter.knownTags(in: [Row]()), ["tag:studio"])
        XCTAssertEqual(
            filter.knownTags(in: [Row("a", tags: ["tag:media"])]),
            ["tag:media", "tag:studio"])
    }

    func testKnownTagsIsEmptyForAnUntaggedTailnetWithNoSelection() {
        XCTAssertTrue(
            PeerListFilter.default.knownTags(in: [Row("a"), Row("b")]).isEmpty,
            "an untagged tailnet must not grow an empty tag submenu")
    }
}
