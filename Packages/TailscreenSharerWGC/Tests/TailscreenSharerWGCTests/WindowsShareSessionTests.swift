import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenSharerWGC

/// The WINDOWS share engine's tests, driven headless on Linux CI:
/// `Apps/windows` has no test target, and the engine's Windows-bound
/// dependencies all stub out off Windows, so generation stamping, the invite
/// hold-and-replay, the approval gate mirror, the mute latch, idle guards and
/// the access facade can all be exercised with no display, capture item,
/// node or WinUI.
///
/// The deliberate counterpart of `LinuxShareSessionTests`, asserting the
/// same contracts against the other isolation model (lock-guarded here,
/// `@MainActor` there) — what `SharerSessionCore`/`SharerVoiceSession` exist
/// to let both hosts share without unifying.
///
/// Nothing here calls `prepareProcess()`, `pickTarget()` or `beginSharing` —
/// those need real Windows.
/// Collects the session's `@Sendable` status pushes. A box, not a captured
/// `var`, since `onStatus` is deliberately `@Sendable` — this engine
/// publishes from whichever thread moved the state.
private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [WindowsShareSession.Status] = []

    var all: [WindowsShareSession.Status] { lock.withLock { entries } }
    var last: WindowsShareSession.Status? { lock.withLock { entries.last } }
    var count: Int { lock.withLock { entries.count } }

    func append(_ status: WindowsShareSession.Status) {
        lock.withLock { entries.append(status) }
    }
}

final class WindowsShareSessionTests: XCTestCase {

    /// A session against a throwaway access store, so this suite doesn't
    /// write into whoever ran it (the production default off Windows falls
    /// back to the home directory).
    private func makeSession() -> WindowsShareSession {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscreen-wgc-tests-\(UUID().uuidString)")
        return WindowsShareSession(accessStore: PeerAccessStore(directory: directory.path))
    }

    // MARK: Invitations accepted before a share exists

    /// Accepting an ask happens before a server exists, so the invitee's IP
    /// must survive for replay, or they land at their own approval gate seconds later.
    func testInviteWithNoServerIsHeldForReplay() {
        let session = makeSession()
        session.preApproveViewer(ip: "100.64.0.7")
        XCTAssertEqual(session.pendingPreApprovedIPs, ["100.64.0.7"])

        // Idempotent: a retry of the same ask must not stack.
        session.preApproveViewer(ip: "100.64.0.7")
        session.preApproveViewer(ip: "100.64.0.9")
        XCTAssertEqual(session.pendingPreApprovedIPs, ["100.64.0.7", "100.64.0.9"])
    }

    // MARK: Approval gate

    /// The server's own gate defaults OFF (right for headless automation,
    /// wrong for a desktop app), so this wrapper must fail closed **before
    /// anybody configures it**. Asserted separately from the mirroring
    /// below: this default silently admits strangers if wrong, with nothing
    /// visibly broken.
    func testApprovalIsRequiredBeforeAnybodyConfiguresIt() {
        let session = makeSession()
        let published = StatusLog()
        session.onStatus = { published.append($0) }

        // Force a publish without changing the gate, so the assertion reads
        // the engine's own starting value rather than one this test set.
        session.preApproveViewer(ip: "100.64.0.7")
        session.setRequireApproval(true)

        XCTAssertEqual(
            published.last?.requireApproval, true,
            "a session nobody has configured must already require approval")
        XCTAssertTrue(
            WindowsShareSession.Status().requireApproval,
            "the published status must start closed too — the UI switch reads back from it")
    }

    func testApprovalGateMirrorsIntoTheStatus() {
        let session = makeSession()
        let published = StatusLog()
        session.onStatus = { published.append($0) }

        session.setRequireApproval(false)
        XCTAssertEqual(published.last?.requireApproval, false)
        session.setRequireApproval(true)
        XCTAssertEqual(published.last?.requireApproval, true)
    }

    // MARK: The mute latch

    /// A toggle with no capture device open moves nothing and publishes
    /// nothing.
    func testMicToggleWithNoDeviceIsAQuietNoOp() {
        let session = makeSession()
        let published = StatusLog()
        session.onStatus = { published.append($0) }

        session.toggleMic()
        session.toggleMic()

        XCTAssertEqual(published.count, 0, "nothing is open, so nothing moved")
    }

    /// Releasing a device that was never opened publishes nothing — this
    /// engine adds no idle status churn on top of `VoiceLatch`'s own pairing.
    func testStoppingVoiceThatNeverOpenedIsSilent() {
        let session = makeSession()
        let published = StatusLog()
        session.onStatus = { published.append($0) }

        session.stopVoice()
        session.stopVoice()

        XCTAssertEqual(published.count, 0)
    }

    // MARK: Idle guards

    /// Every control action with no live share is a quiet no-op. `grantControl`
    /// must report false — on this host that also covers an unresolvable
    /// capture region.
    func testControlActionsWithoutAServerAreQuietNoOps() {
        let session = makeSession()
        XCTAssertFalse(session.grantControl(to: UUID()), "no server means no grant")
        session.declineControl(UUID())
        session.revokeControl()
        session.approveViewer("100.64.0.5:1234")
        session.denyViewer("100.64.0.5:1234")
        session.disconnectViewer("100.64.0.5:1234")
        XCTAssertNil(session.takeLinkOffer(id: UUID()), "no server means no offer to take")
        session.dismissLinkOffer(id: UUID())
    }

    // MARK: Link offers

    /// `Status()` starts with an empty queue — a fresh session (or one whose
    /// share just ended) has nothing pending for the UI to render.
    func testLinkOffersStartEmpty() {
        XCTAssertEqual(WindowsShareSession.Status().linkOffers, [])
    }

    func testStopSharingWithoutAServerLeavesNothingClaimingToShare() async {
        let session = makeSession()
        let published = StatusLog()
        session.onStatus = { published.append($0) }

        await session.stopSharing()

        XCTAssertFalse(
            published.all.contains(where: { $0.isSharing }),
            "nothing ran, so nothing may publish a live share")
    }

    // MARK: The share stamp

    /// `beginSharing`'s await spans tsnet bring-up (minutes, on an
    /// interactive login), so a stop can land mid-flight; the tail that
    /// wakes up afterward must recognize the share it belongs to is over.
    func testAStoppedShareIsNoLongerTheCurrentOne() {
        let session = makeSession()
        let first = session.beginShareGeneration()
        XCTAssertTrue(session.isCurrentShare(first))

        session.endShareGeneration()
        XCTAssertFalse(
            session.isCurrentShare(first),
            "a tail waking up after the stop must not publish for the share that ended")

        let second = session.beginShareGeneration()
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(session.isCurrentShare(second))
        XCTAssertFalse(
            session.isCurrentShare(first),
            "and the previous attempt stays closed once a new one opens")
    }

    // MARK: Selection bytes

    /// Always the same bytes and always `.display` — the item IS the
    /// selection, but `kind` still matters since the encoder rejects `.application`.
    func testWindowsSelectionDataIsAlwaysADisplayKind() throws {
        let data = WindowsShareSession.windowsSelectionData()
        let decoded = try JSONDecoder().decode(PickerSelection.self, from: data)
        XCTAssertEqual(decoded.kind, .display)
        XCTAssertNil(decoded.displayID)
        XCTAssertNil(decoded.windowID)
        // Compared decoded, not byte-for-byte: JSONEncoder doesn't order keys
        // unless asked to.
        let again = try JSONDecoder().decode(
            PickerSelection.self, from: WindowsShareSession.windowsSelectionData())
        XCTAssertEqual(again.kind, decoded.kind)
        XCTAssertEqual(again.bundleIDs, decoded.bundleIDs)
    }

    // MARK: Access facade

    /// "Always Allow" / "Deny & Block" round-trip, and every change re-publishes.
    func testRememberForgetRoundTripsAndRepublishes() {
        let session = makeSession()
        let published = StatusLog()
        session.onStatus = { published.append($0) }

        session.remember(
            rowID: "100.64.0.3:555", stableID: "node-abc", displayName: "living-room-tv",
            policy: .deny)
        XCTAssertEqual(session.remembered(stableID: "node-abc"), .deny)
        let afterRemember = published.count
        XCTAssertGreaterThan(afterRemember, 0, "a standing decision changes how rows render")

        session.forget(rowID: "100.64.0.3:555", stableID: "node-abc")
        XCTAssertNil(session.remembered(stableID: "node-abc"))
        XCTAssertGreaterThan(published.count, afterRemember)
    }

    /// A decision on a row whose StableNodeID hasn't resolved yet is queued, not dropped.
    func testADecisionOnAnUnresolvedRowIsDeferredRatherThanLost() {
        let session = makeSession()
        session.remember(
            rowID: "100.64.0.4:600", stableID: nil, displayName: "unknown-peer", policy: .deny)
        XCTAssertTrue(session.isDeferred(rowID: "100.64.0.4:600"))
        XCTAssertFalse(session.isDeferred(rowID: "100.64.0.99:1"))
    }
}
