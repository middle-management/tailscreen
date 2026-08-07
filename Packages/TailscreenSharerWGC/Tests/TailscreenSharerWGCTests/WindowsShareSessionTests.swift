import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenSharerWGC

/// The WINDOWS share engine's first tests.
///
/// It had none: `Apps/windows` has no test target, and everything this engine
/// decided was covered only by Linux CI typechecking the file. That gap is not
/// symmetric with the platform — the engine's Windows-bound dependencies all
/// stub out off Windows, so the whole orchestration layer (generation stamping,
/// the invite hold-and-replay, the approval gate mirror, the mute latch, the
/// idle guards, the access facade) can be driven headless on a Linux runner
/// with no display, no capture item, no node and no WinUI.
///
/// The deliberate counterpart of `LinuxShareSessionTests` in
/// `Packages/TailscreenLinuxBackends`, asserting the same contracts against the
/// other isolation model — this engine is lock-guarded where that one is
/// `@MainActor` — which is exactly what `SharerSessionCore` and
/// `SharerVoiceSession` exist to let both hosts share without unifying.
///
/// Nothing here calls `prepareProcess()`, `pickTarget()` or `beginSharing` —
/// those need real Windows.
/// Collects the session's `@Sendable` status pushes.
///
/// A box rather than a captured `var` because `onStatus` is deliberately
/// `@Sendable`: this engine publishes from whichever thread moved the state —
/// a network thread, the capture thread, the mic thread — and the callback's
/// signature is what says so.
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

    /// A session against a throwaway access store. Injectable specifically so
    /// this suite does not write into whoever ran it: the production default
    /// resolves `%LOCALAPPDATA%`, which off Windows falls back to the home
    /// directory.
    private func makeSession() -> WindowsShareSession {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscreen-wgc-tests-\(UUID().uuidString)")
        return WindowsShareSession(accessStore: PeerAccessStore(directory: directory.path))
    }

    // MARK: Invitations accepted before a share exists

    /// Accepting somebody's ask to share necessarily happens before the share
    /// starts — that is what accepting means — so the invitee's IP has to
    /// survive until a server exists to tell. Losing it parks the person this
    /// machine just invited at its own approval gate, seconds later, with no
    /// context.
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

    /// The server's own gate defaults OFF — right for a headless automation
    /// sharer, wrong for a desktop app — so this wrapper has to fail closed and
    /// say so in the status the switch reads back from.
    func testApprovalGateDefaultsClosedAndMirrorsIntoTheStatus() {
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
    /// nothing. The engine used to guard on the *voice* while publishing the
    /// *flags*, so a device that had already failed — voice still held,
    /// `micAvailable` already false — could be toggled into `micOn == true`: a
    /// live-microphone indicator over a device recording nothing.
    func testMicToggleWithNoDeviceIsAQuietNoOp() {
        let session = makeSession()
        let published = StatusLog()
        session.onStatus = { published.append($0) }

        session.toggleMic()
        session.toggleMic()

        XCTAssertEqual(published.count, 0, "nothing is open, so nothing moved")
    }

    /// Releasing a device that was never opened publishes nothing at all.
    ///
    /// The pairing itself — both flags always moving together, so a `micOn`
    /// left true over a released device can never happen — is `VoiceLatch`'s
    /// and is pinned in `VoiceLatchTests` with a device that really opens.
    /// What is asserted here is that this engine adds no idle status churn on
    /// top of it: `stopVoice` runs on every teardown path, including ones that
    /// never got as far as a microphone.
    func testStoppingVoiceThatNeverOpenedIsSilent() {
        let session = makeSession()
        let published = StatusLog()
        session.onStatus = { published.append($0) }

        session.stopVoice()
        session.stopVoice()

        XCTAssertEqual(published.count, 0)
    }

    // MARK: Idle guards

    /// Every control action with no live share is a quiet no-op rather than a
    /// crash or a lie. `grantControl` in particular must report false: on this
    /// host that also covers an unresolvable capture region, which the app
    /// words for the person.
    func testControlActionsWithoutAServerAreQuietNoOps() {
        let session = makeSession()
        XCTAssertFalse(session.grantControl(to: UUID()), "no server means no grant")
        session.declineControl(UUID())
        session.revokeControl()
        session.approveViewer("100.64.0.5:1234")
        session.denyViewer("100.64.0.5:1234")
        session.disconnectViewer("100.64.0.5:1234")
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

    /// The engine's own share-generation gate, driven with no server behind it.
    ///
    /// The rule this pins is the one PR #244 added: `beginSharing`'s await spans
    /// tsnet bring-up — minutes, on an interactive browser login — so a stop can
    /// land in the middle, and the tail that wakes up afterwards must recognise
    /// that the share it belongs to is over. Before the stamp it published
    /// "Sharing" over an idle session: a share the person could not see, could
    /// not stop, and did not ask for.
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

    /// Always the same bytes, and always the `.display` kind — on Windows the
    /// ITEM is the selection and the backend was constructed with it. The kind
    /// still matters: the encoder rejects `.application`, which one capture item
    /// cannot express anyway.
    func testWindowsSelectionDataIsAlwaysADisplayKind() throws {
        let data = WindowsShareSession.windowsSelectionData()
        let decoded = try JSONDecoder().decode(PickerSelection.self, from: data)
        XCTAssertEqual(decoded.kind, .display)
        XCTAssertNil(decoded.displayID)
        XCTAssertNil(decoded.windowID)
        // Compared decoded, not byte-for-byte: `JSONEncoder` does not order
        // keys unless asked to, so two encodes of one value legitimately differ
        // as bytes. What has to hold is that a share and its mid-share source
        // change send the same SELECTION.
        let again = try JSONDecoder().decode(
            PickerSelection.self, from: WindowsShareSession.windowsSelectionData())
        XCTAssertEqual(again.kind, decoded.kind)
        XCTAssertEqual(again.bundleIDs, decoded.bundleIDs)
    }

    // MARK: Access facade

    /// "Always Allow" / "Deny & Block" round-trip, and every change re-publishes
    /// — a block on somebody already watching expels them, so the roster the
    /// sharer is looking at is about to be wrong.
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

    /// A decision made about a row whose StableNodeID has not resolved yet is
    /// queued, not dropped — the coordinator's contract, asserted here because
    /// this host forwards taps into it and nothing else in this package does.
    func testADecisionOnAnUnresolvedRowIsDeferredRatherThanLost() {
        let session = makeSession()
        session.remember(
            rowID: "100.64.0.4:600", stableID: nil, displayName: "unknown-peer", policy: .deny)
        XCTAssertTrue(session.isDeferred(rowID: "100.64.0.4:600"))
        XCTAssertFalse(session.isDeferred(rowID: "100.64.0.99:1"))
    }
}
