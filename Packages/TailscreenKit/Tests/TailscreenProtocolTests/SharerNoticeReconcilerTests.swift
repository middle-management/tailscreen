import Foundation
import XCTest

@testable import TailscreenProtocol

/// Pins the reconcile loop between live rows and posted notices — the
/// sequencing both swift-cross-ui hosts' `SharerNotifications` now delegate to
/// (`SharerNoticeReconciler`), driven through a fake poster. The *decision*
/// halves (`noticesToPost`/`noticesToWithdraw`) are `SharerNoticeTests`'; what
/// is pinned here is the bookkeeping around them: the label remembered for a
/// departure, the withdraw-then-depart pairing, the answered-from-the-banner
/// forget, and the reset that keeps teardown silent.
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

        // The row left — admitted from the window, or the peer gave up. A
        // banner whose Accept button now does nothing must come down.
        reconciler.applyAsk(kind: .viewerPending, candidates: [], poster: poster)
        XCTAssertEqual(
            poster.events.last,
            "withdraw:\(SharerNoticeKind.viewerPending.rawValue):100.64.0.5:1234")

        // Forget-on-leave: the SAME peer genuinely asking again IS news.
        reconciler.applyAsk(kind: .viewerPending, candidates: [waiting], poster: poster)
        XCTAssertEqual(
            poster.events.last,
            "post:\(SharerNoticeKind.viewerPending.rawValue):100.64.0.5:1234:robert-macbook")
    }

    @MainActor
    func testAskKindsKeepSeparateBooks() async throws {
        // One identity can legitimately be both waiting to watch and asking
        // for control; announcing one must not swallow the other.
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
        // The press came back through app activation (the Windows path) —
        // outside any reconcile pass — and the host withdrew the toast itself.
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
        // The arrival banner goes; a departure banner replaces it — with the
        // label remembered from the arrival, because the peer is gone from
        // every live list by the time this fires.
        XCTAssertEqual(
            Array(poster.events.dropFirst()),
            [
                "withdraw:\(SharerNoticeKind.viewerJoined.rawValue):100.64.0.7:9000",
                "post:\(SharerNoticeKind.viewerLeft.rawValue):100.64.0.7:9000:living-room-tv",
            ])
    }

    @MainActor
    func testOnlyAnnouncedViewersGetADeparture() async throws {
        var reconciler = SharerNoticeReconciler()
        let poster = FakePoster()

        // Never announced (e.g. the notifier came up mid-share on a fresh
        // reconciler): an empty roster has nobody to say goodbye about.
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
                NoticeCandidate(identity: "b:2", label: "b"),
            ], poster: poster)
        let before = poster.events.count

        // Stopping a share expels every viewer at once. The host clears the
        // books BEFORE the empty rosters reconcile, so nobody gets a "stopped
        // watching" banner at the exact moment the sharer decided to stop.
        reconciler.reset()
        reconciler.applyViewers([], poster: poster)
        reconciler.applyAsk(kind: .viewerPending, candidates: [], poster: poster)

        XCTAssertEqual(poster.events.count, before)
    }
}
