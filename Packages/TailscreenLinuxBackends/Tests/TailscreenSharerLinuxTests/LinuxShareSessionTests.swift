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
        // machine's own approval gate.
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
