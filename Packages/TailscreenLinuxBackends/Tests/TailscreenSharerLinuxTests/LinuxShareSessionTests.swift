import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenSharerLinux

/// Smoke coverage for the GTK app's share engine, now that it lives where a
/// headless CI job can reach it. Nothing here brings up a node, a capture
/// backend or an X display — that is `CaptureEncoderTests`' half — so what is
/// pinned is exactly the orchestration that used to sit untested in the app
/// target: the ask-to-share inbox wiring, the pre-approve hand-off, the
/// drawing latch's no-surface refusal, the access facade, and the idle
/// teardown's quietness.
final class LinuxShareSessionTests: XCTestCase {

    /// An engine against a throwaway access store — no node, no display, no
    /// GTK. `PeerAccessStore` creates its directory on first write, so nothing
    /// here can fail.
    @MainActor
    private func makeEngine() -> LinuxShareSession {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscreen-engine-tests-\(UUID().uuidString)")
        return LinuxShareSession(
            display: nil, accessStore: PeerAccessStore(directory: directory.path))
    }

    // MARK: Asks to share

    @MainActor
    func testShareRequestIsPublishedAndAcceptPreApprovesAndStarts() async throws {
        let engine = makeEngine()
        var published: [[PendingShareRequest]] = []
        var startRequests = 0
        engine.onShareRequestsChanged = { published.append($0) }
        engine.onStartShareRequested = { startRequests += 1 }

        engine.noteShareRequest(
            from: "robert-macbook", sourceAddr: "100.64.0.7:53211", connectionID: UUID())
        XCTAssertEqual(published.count, 1)
        let request = try XCTUnwrap(published.last?.first)
        XCTAssertEqual(request.fromHostname, "robert-macbook")
        XCTAssertEqual(request.sourceKey, "100.64.0.7", "the key is the IP, never the hostname")

        engine.answerShareRequest(id: request.id, accept: true)
        XCTAssertEqual(published.last, [], "an answered ask leaves the inbox")
        XCTAssertEqual(startRequests, 1, "accept must hand off to the host's share flow")
        // Accept happens before a server exists, so the invitee's IP is held
        // for replay — losing it parks the person just invited at this
        // machine's own approval gate. The hold/drain rule itself is
        // `SharerSessionCore`'s and is pinned there for both hosts.
        XCTAssertEqual(engine.pendingPreApprovedIPs, ["100.64.0.7"])
    }

    @MainActor
    func testDeclinedShareRequestNeitherStartsNorPreApproves() async throws {
        let engine = makeEngine()
        var startRequests = 0
        var latest: [PendingShareRequest] = []
        engine.onShareRequestsChanged = { latest = $0 }
        engine.onStartShareRequested = { startRequests += 1 }

        engine.noteShareRequest(
            from: "studio-imac", sourceAddr: "100.64.0.9:40100", connectionID: UUID())
        let request = try XCTUnwrap(latest.first)
        engine.answerShareRequest(id: request.id, accept: false)

        XCTAssertEqual(latest, [])
        XCTAssertEqual(startRequests, 0, "a decline must not start a share")
        XCTAssertTrue(engine.pendingPreApprovedIPs.isEmpty, "a declined peer is not invited past the gate")
    }

    @MainActor
    func testAnsweringUnknownRequestChangesNothing() async throws {
        let engine = makeEngine()
        var events = 0
        engine.onShareRequestsChanged = { _ in events += 1 }
        engine.onStartShareRequested = { XCTFail("nothing was asked") }
        engine.answerShareRequest(id: UUID(), accept: true)
        XCTAssertEqual(events, 0)
    }

    @MainActor
    func testClearShareRequestsEmptiesTheInboxOnce() async throws {
        let engine = makeEngine()
        var published: [[PendingShareRequest]] = []
        engine.onShareRequestsChanged = { published.append($0) }
        engine.noteShareRequest(from: "a", sourceAddr: "100.64.0.1:1", connectionID: UUID())
        engine.clearShareRequests()
        XCTAssertEqual(published.last, [])
        let count = published.count
        // Empty already — a second clear must not republish (and re-notify).
        engine.clearShareRequests()
        XCTAssertEqual(published.count, count)
    }

    // MARK: Drawing latch

    @MainActor
    func testArmingWithNoOverlayRefusesAndSaysWhy() async throws {
        let engine = makeEngine()
        var seen: [(AnnotationTool?, SharerDrawingRefusal?)] = []
        engine.onDrawingChanged = { seen.append(($0, $1)) }

        engine.selectTool(.pen)
        XCTAssertEqual(seen.last?.0, nil, "a refused arm must not read as an armed tool")
        XCTAssertEqual(seen.last?.1, .noSurface)

        // Disarming with nothing armed is a quiet no-op, not a second refusal.
        engine.selectTool(nil)
        XCTAssertEqual(seen.last?.0, nil)
        XCTAssertNil(seen.last?.1)
    }

    // MARK: Idle guards

    @MainActor
    func testControlActionsWithoutAServerAreQuietNoOps() async throws {
        let engine = makeEngine()
        XCTAssertFalse(engine.grantControl(to: UUID()), "no server means no grant")
        engine.declineControl(UUID())
        engine.revokeControl()
        engine.approve("100.64.0.5:1234")
        engine.deny("100.64.0.5:1234")
        engine.disconnect("100.64.0.5:1234")
        engine.setRequireApproval(false)
        engine.toggleMic()
    }

    @MainActor
    func testStopWithoutAServerGoesIdleWithoutAnEndEvent() async throws {
        let engine = makeEngine()
        var phases: [LinuxShareSession.Phase] = []
        var ended = 0
        engine.onPhaseChanged = { phases.append($0) }
        engine.onShareDidEnd = { _ in ended += 1 }

        engine.stopSharing()

        XCTAssertEqual(phases, [.idle])
        XCTAssertEqual(
            ended, 0,
            "nothing ran, so the host must not be told to tear notifications down")
    }

    @MainActor
    func testChangeSourceWithoutAServerReportsFalse() async throws {
        let engine = makeEngine()
        let changed = try await engine.changeSource(filterData: Data(), captureFactory: {
            fatalError("no share is running — the factory must never be invoked")
        })
        XCTAssertFalse(changed)
    }

    // MARK: Control-grant staleness

    /// The high-water mark alone cannot reject a snapshot from a share that
    /// has ended, and that is not a detail: teardown **resets** the mark to
    /// zero, because a fresh server starts its own `onControlGrantChanged`
    /// sequence at zero and a carried-over mark would discard the next share's
    /// first snapshots. So a snapshot still in flight from the old server is
    /// not stale against zero — it lands, telling the sharer somebody is
    /// driving a machine they just stopped sharing, and it leaves the mark
    /// high enough to swallow the next share's grant entirely.
    @MainActor
    func testALateGrantFromAnEndedShareIsIgnoredAndDoesNotPoisonTheNextShare() async throws {
        let engine = makeEngine()
        var grants: [String?] = []
        engine.onControlGrantChanged = { grants.append($0) }

        let share = engine.beginShareGeneration()
        engine.applyControlGrant(share: share, generation: 3, displayName: "robert-macbook")
        XCTAssertEqual(grants, ["robert-macbook"])

        // What `stopSharing` / `handleCaptureStopped` leave behind.
        engine.endShareGeneration()
        grants.removeAll()
        engine.applyControlGrant(share: share, generation: 3, displayName: "robert-macbook")
        XCTAssertTrue(
            grants.isEmpty,
            "a snapshot from a share that ended must not announce a live grant")

        // And the next share's own first snapshot — a low generation, from a
        // server that starts counting again — still has to land.
        let next = engine.beginShareGeneration()
        engine.applyControlGrant(share: next, generation: 1, displayName: "studio-imac")
        XCTAssertEqual(grants, ["studio-imac"])
    }

    /// Within one share the reorder guard is unchanged: a hop can deliver an
    /// older snapshot last, and applying its `nil` would tell the sharer
    /// nobody is controlling their machine while somebody is.
    @MainActor
    func testAReorderedGrantSnapshotWithinAShareIsStillDiscarded() async throws {
        let engine = makeEngine()
        var grants: [String?] = []
        engine.onControlGrantChanged = { grants.append($0) }

        let share = engine.beginShareGeneration()
        engine.applyControlGrant(share: share, generation: 5, displayName: "robert-macbook")
        engine.applyControlGrant(share: share, generation: 4, displayName: nil)
        XCTAssertEqual(grants, ["robert-macbook"])

        // Equal generations are NOT stale — two racing notifies can observe
        // the same pair, and re-applying it is idempotent.
        engine.applyControlGrant(share: share, generation: 5, displayName: "robert-macbook")
        XCTAssertEqual(grants, ["robert-macbook", "robert-macbook"])
    }

    // MARK: Voice

    /// The mic control is absent, not present-and-inert, until a device is
    /// open — and a toggle while there is none publishes nothing at all rather
    /// than lighting an indicator over a microphone that does not exist.
    ///
    /// The latch that decides this is `VoiceLatch`, shared with the Windows
    /// engine and both viewers; what this pins is the GTK engine's wiring onto
    /// it, which is the half that used to guard on the voice while publishing
    /// the flags.
    @MainActor
    func testTogglingTheMicWithNoDeviceOpenPublishesNothing() async throws {
        let engine = makeEngine()
        var voiceStates: [(Bool, Bool)] = []
        engine.onVoiceChanged = { available, on in voiceStates.append((available, on)) }

        engine.toggleMic()
        engine.toggleMic()

        XCTAssertTrue(voiceStates.isEmpty)
        XCTAssertFalse(engine.micAvailable)
        XCTAssertFalse(engine.micOn, "an indicator over a device that is not open")
    }

    // MARK: Access facade

    @MainActor
    func testRememberForgetRoundTripsAndAnnouncesEachChange() async throws {
        let engine = makeEngine()
        var changes = 0
        engine.onAccessChanged = { changes += 1 }

        engine.remember(
            rowID: "100.64.0.3:555", stableID: "node-abc", label: "living-room-tv",
            policy: .deny)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(engine.remembered(stableID: "node-abc"), .deny)

        engine.forget(rowID: "100.64.0.3:555", stableID: "node-abc")
        XCTAssertEqual(changes, 2)
        XCTAssertNil(engine.remembered(stableID: "node-abc"))
    }
}
