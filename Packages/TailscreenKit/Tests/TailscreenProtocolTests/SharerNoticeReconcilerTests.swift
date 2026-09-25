import Foundation
import XCTest

@testable import TailscreenProtocol

/// Pins `SharerNoticeReconciler`'s bookkeeping around live rows vs. posted
/// notices, driven through a fake poster: the label remembered for a
/// departure, the withdraw-then-depart pairing, the answered-from-the-banner
/// forget, and the reset that keeps teardown silent. The *decision* halves
/// (`noticesToPost`/`noticesToWithdraw`) are `SharerNoticeTests`'.
final class SharerNoticeReconcilerTests: XCTestCase {

    /// Records what a platform backend would have delivered.
    @MainActor
    private final class FakePoster: NoticePosting {
        var events: [String] = []
        func post(_ notice: SharerNotice) {
            events.append("post:\(notice.kind.rawValue):\(notice.identity):\(notice.label)")
        }
        func withdraw(kind: SharerNoticeKind, identity: String) {
            events.append("withdraw:\(kind.rawValue):\(identity)")
        }
    }

    // MARK: Asks

    @MainActor
    func testAskAnnouncesNewRowsOnceAndWithdrawsGoneOnes() async throws {
        var reconciler = SharerNoticeReconciler()
        let poster = FakePoster()
        let waiting = NoticeCandidate(identity: "100.64.0.5:1234", label: "robert-macbook")

        reconciler.applyAsk(kind: .viewerPending, candidates: [waiting], poster: poster)
        XCTAssertEqual(
            poster.events,
            ["post:\(SharerNoticeKind.viewerPending.rawValue):100.64.0.5:1234:robert-macbook"])

        // A re-emitted snapshot for an unrelated reason announces nothing.
        reconciler.applyAsk(kind: .viewerPending, candidates: [waiting], poster: poster)
        XCTAssertEqual(poster.events.count, 1)

        // Row left (admitted or gave up): a banner whose Accept now does nothing must come down.
        reconciler.applyAsk(kind: .viewerPending, candidates: [], poster: poster)
        XCTAssertEqual(
            poster.events.last,
            "withdraw:\(SharerNoticeKind.viewerPending.rawValue):100.64.0.5:1234")

        // Forget-on-leave: the same peer asking again is news.
        reconciler.applyAsk(kind: .viewerPending, candidates: [waiting], poster: poster)
        XCTAssertEqual(
            poster.events.last,
            "post:\(SharerNoticeKind.viewerPending.rawValue):100.64.0.5:1234:robert-macbook")
    }

    @MainActor
    func testAskKindsKeepSeparateBooks() async throws {
        // One identity can be both waiting to watch and asking for control; announcing one must not swallow the other.
        var reconciler = SharerNoticeReconciler()
        let poster = FakePoster()
        let identity = "100.64.0.5:1234"

        reconciler.applyAsk(
            kind: .viewerPending,
            candidates: [NoticeCandidate(identity: identity, label: "a")], poster: poster)
        reconciler.applyAsk(
            kind: .controlRequested,
            candidates: [NoticeCandidate(identity: identity, label: "a")], poster: poster)

        XCTAssertEqual(poster.events.count, 2)
    }

    @MainActor
    func testAnsweredFromTheBannerIsForgottenSoAFreshAskAnnouncesAgain() async throws {
        var reconciler = SharerNoticeReconciler()
        let poster = FakePoster()
        let asker = NoticeCandidate(identity: "req-1", label: "studio-imac")

        reconciler.applyAsk(kind: .requestToShare, candidates: [asker], poster: poster)
        // The press came back via app activation (Windows), outside any reconcile pass.
        reconciler.forget(kind: .requestToShare, identity: "req-1")

        reconciler.applyAsk(kind: .requestToShare, candidates: [asker], poster: poster)
        XCTAssertEqual(
            poster.events.filter { $0.hasPrefix("post:") }.count, 2,
            "an answered-and-forgotten ask must announce again, not stay muted")
    }

    // MARK: Joined / left

    @MainActor
    func testDepartureReplacesArrivalAndCarriesTheRememberedLabel() async throws {
        var reconciler = SharerNoticeReconciler()
        let poster = FakePoster()
        let viewer = NoticeCandidate(identity: "100.64.0.7:9000", label: "living-room-tv")

        reconciler.applyViewers([viewer], poster: poster)
        XCTAssertEqual(
            poster.events,
            ["post:\(SharerNoticeKind.viewerJoined.rawValue):100.64.0.7:9000:living-room-tv"])

        reconciler.applyViewers([], poster: poster)
        // Departure banner replaces the arrival, carrying its remembered label
        // (the peer is gone from every live list by the time this fires).
        XCTAssertEqual(
            Array(poster.events.dropFirst()),
            [
                "withdraw:\(SharerNoticeKind.viewerJoined.rawValue):100.64.0.7:9000",
                "post:\(SharerNoticeKind.viewerLeft.rawValue):100.64.0.7:9000:living-room-tv"
            ])
    }

    @MainActor
    func testOnlyAnnouncedViewersGetADeparture() async throws {
        var reconciler = SharerNoticeReconciler()
        let poster = FakePoster()

        // Never announced (notifier came up mid-share): nobody to say goodbye about.
        reconciler.applyViewers([], poster: poster)
        XCTAssertEqual(poster.events, [])
    }

    @MainActor
    func testResetKeepsTeardownSilent() async throws {
        var reconciler = SharerNoticeReconciler()
        let poster = FakePoster()
        reconciler.applyViewers(
            [
                NoticeCandidate(identity: "a:1", label: "a"),
                NoticeCandidate(identity: "b:2", label: "b")
            ], poster: poster)
        let before = poster.events.count

        // The host must clear the books before the empty rosters reconcile, or a "stopped
        // watching" banner fires at the exact moment the sharer stops.
        reconciler.reset()
        reconciler.applyViewers([], poster: poster)
        reconciler.applyAsk(kind: .viewerPending, candidates: [], poster: poster)

        XCTAssertEqual(poster.events.count, before)
    }
}
