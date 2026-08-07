import Foundation
import TailscreenProtocol
import TailscreenTransport
import XCTest

@testable import TailscreenSharer

/// Pins the ask-to-share sequencing all three hosts now share — the piece
/// protocol.md's pitfall section documents rule by rule, because each rule was
/// once hand-written per host and each has a silent failure mode: an answer
/// that dials back reaches whoever holds the address now; an accept that skips
/// pre-approval parks the person just invited at this machine's own gate; a
/// stale row is a button that does nothing.
///
/// No tsnet node anywhere: the reply send is observed through the
/// coordinator's internal seam (`sendResponseForTesting`) — which is also why
/// this suite, unlike its neighbours, needs `@testable`: the decision
/// *surface* stays public, the seam stays internal. The inbox arithmetic
/// (coalescing key, cap, expiry math) is `ShareRequestInboxTests`' — what is
/// pinned here is the sequencing around it.
final class SharerAskToShareCoordinatorTests: XCTestCase {

    @MainActor
    private func makeCoordinator() -> (
        SharerAskToShareCoordinator, replies: () -> [(Bool, UUID)]
    ) {
        let coordinator = SharerAskToShareCoordinator()
        var replies: [(Bool, UUID)] = []
        coordinator.sendResponseForTesting = { accepted, connectionID in
            replies.append((accepted, connectionID))
        }
        return (coordinator, { replies })
    }

    // MARK: Arrival

    @MainActor
    func testArrivalPublishesTheInbox() async throws {
        let (coordinator, _) = makeCoordinator()
        var published: [[PendingShareRequest]] = []
        var received: [String] = []
        coordinator.onRequestsChanged = { published.append($0) }
        coordinator.onRequestReceived = { received.append($0) }

        coordinator.noteRequest(
            from: "robert-macbook", sourceAddr: "100.64.0.7:53211", connectionID: UUID())

        XCTAssertEqual(received, ["robert-macbook"])
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(coordinator.requests.first?.sourceKey, "100.64.0.7")
    }

    @MainActor
    func testExpiredRowIsPrunedWhenANewAskArrives() async throws {
        let (coordinator, _) = makeCoordinator()
        let second = 1_000_000_000 as UInt64

        coordinator.noteRequest(
            from: "old", sourceAddr: "100.64.0.1:1000", connectionID: UUID(), nowNs: second)
        coordinator.noteRequest(
            from: "fresh", sourceAddr: "100.64.0.2:2000", connectionID: UUID(),
            nowNs: second + SharerAskToShareCoordinator.requestTTLNs + 1)

        // The requester waits 120 s and gives up; a row past that is a Share
        // button answering a connection that has already gone.
        XCTAssertEqual(coordinator.requests.map(\.fromHostname), ["fresh"])
    }

    @MainActor
    func testDroppedFloodArrivalDoesNotRepublish() async throws {
        let (coordinator, _) = makeCoordinator()
        for i in 0..<ShareRequestInbox.maxPending {
            coordinator.noteRequest(
                from: "host-\(i)", sourceAddr: "100.64.1.\(i):40000", connectionID: UUID())
        }
        var publishes = 0
        coordinator.onRequestsChanged = { _ in publishes += 1 }
        coordinator.noteRequest(
            from: "one-too-many", sourceAddr: "100.64.9.9:40000", connectionID: UUID())
        XCTAssertEqual(publishes, 0, "a capped-out arrival changes nothing to publish")
        XCTAssertEqual(coordinator.requests.count, ShareRequestInbox.maxPending)
    }

    // MARK: Answering

    @MainActor
    func testAcceptRepliesOnTheArrivalConnectionThenPreApprovesThenStarts() async throws {
        let (coordinator, replies) = makeCoordinator()
        var order: [String] = []
        coordinator.onPreApproveViewer = { order.append("preapprove:\($0)") }
        coordinator.onStartShare = { order.append("start") }

        let connection = UUID()
        coordinator.noteRequest(
            from: "robert-macbook", sourceAddr: "100.64.0.7:53211", connectionID: connection)
        let request = try XCTUnwrap(coordinator.requests.first)

        coordinator.answer(id: request.id, accept: true)

        XCTAssertTrue(coordinator.requests.isEmpty)
        XCTAssertEqual(replies().count, 1)
        XCTAssertEqual(replies().first?.0, true)
        // ON the connection the ask arrived on — a dial-back would answer
        // whoever currently holds the requester's claimed address.
        XCTAssertEqual(replies().first?.1, connection)
        // Pre-approve strictly before the share flow: the invitee's HELLO can
        // arrive the moment the share is up.
        XCTAssertEqual(order, ["preapprove:100.64.0.7", "start"])
    }

    @MainActor
    func testAcceptAfterARetryRepliesOnTheFreshestConnection() async throws {
        let (coordinator, replies) = makeCoordinator()
        let stale = UUID()
        let fresh = UUID()

        coordinator.noteRequest(
            from: "robert-macbook", sourceAddr: "100.64.0.7:53211", connectionID: stale)
        coordinator.noteRequest(
            from: "robert-macbook", sourceAddr: "100.64.0.7:53999", connectionID: fresh)
        XCTAssertEqual(coordinator.requests.count, 1, "a retry coalesces, not stacks")

        let request = try XCTUnwrap(coordinator.requests.first)
        coordinator.answer(id: request.id, accept: true)

        // The old connection is most likely why the peer retried; an answer
        // sent down it reaches nobody.
        XCTAssertEqual(replies().map(\.1), [fresh])
    }

    @MainActor
    func testDeclineRepliesAndNeitherPreApprovesNorStarts() async throws {
        let (coordinator, replies) = makeCoordinator()
        coordinator.onPreApproveViewer = { _ in XCTFail("a decline invites nobody") }
        coordinator.onStartShare = { XCTFail("a decline starts nothing") }

        let connection = UUID()
        coordinator.noteRequest(
            from: "studio-imac", sourceAddr: "100.64.0.9:40100", connectionID: connection)
        let request = try XCTUnwrap(coordinator.requests.first)

        coordinator.answer(id: request.id, accept: false)

        XCTAssertTrue(coordinator.requests.isEmpty)
        XCTAssertEqual(replies().first?.0, false)
        XCTAssertEqual(replies().first?.1, connection)
    }

    @MainActor
    func testAcceptWithNoConnectionStillPreApprovesAndStarts() async throws {
        // A legacy transport that never learned the connection: nothing to
        // reply on, but the person still said yes — the share must happen.
        let (coordinator, replies) = makeCoordinator()
        var order: [String] = []
        coordinator.onPreApproveViewer = { order.append("preapprove:\($0)") }
        coordinator.onStartShare = { order.append("start") }

        coordinator.noteRequest(
            from: "legacy", sourceAddr: "100.64.0.4:100", connectionID: nil)
        let request = try XCTUnwrap(coordinator.requests.first)
        coordinator.answer(id: request.id, accept: true)

        XCTAssertTrue(replies().isEmpty)
        XCTAssertEqual(order, ["preapprove:100.64.0.4", "start"])
    }

    @MainActor
    func testAnsweringAnUnknownIdDoesNothing() async throws {
        let (coordinator, replies) = makeCoordinator()
        var publishes = 0
        coordinator.onRequestsChanged = { _ in publishes += 1 }
        coordinator.onStartShare = { XCTFail("nothing was asked") }

        coordinator.answer(id: UUID(), accept: true)

        XCTAssertEqual(publishes, 0)
        XCTAssertTrue(replies().isEmpty)
    }

    // MARK: Clearing

    @MainActor
    func testClearPublishesOnceAndOnlyWhenSomethingWasParked() async throws {
        let (coordinator, _) = makeCoordinator()
        var published: [[PendingShareRequest]] = []
        coordinator.onRequestsChanged = { published.append($0) }

        coordinator.noteRequest(
            from: "a", sourceAddr: "100.64.0.1:1", connectionID: UUID())
        coordinator.clearRequests()
        XCTAssertEqual(published.last, [])
        let count = published.count

        // Empty already — a second clear must not republish (and re-notify).
        coordinator.clearRequests()
        XCTAssertEqual(published.count, count)
    }

    // MARK: Listener bring-up
    //
    // Driven through `ensureListenerForTesting`, which supplies the bind step
    // the real `ensureListener` gets from `TailscreenControlListener.start` —
    // a `TailscaleNode` cannot be constructed without standing a real tsnet
    // node up, and none of what is pinned here is about the node.
    //
    // What is pinned is the gap the old `(listener, listenerNode)` pair could
    // not express: **created, not bound yet.** A listener stopped in that
    // state is not stopped at all (`stop()` clears `isRunning`, `start()` sets
    // it again on its way to binding), so a supersede or a teardown landing
    // there used to leave a listener holding port 7447 that nothing tracked.

    /// A start that throws must leave nothing behind.
    ///
    /// The old code assigned the listener before starting it and never
    /// unassigned it, so a failed bind wedged the coordinator permanently: the
    /// next `ensure` saw "already bound to this node" and returned, and this
    /// machine never heard an ask again short of a restart.
    @MainActor
    func testAFailedListenerStartLeavesTheBringUpRetryable() async throws {
        let (coordinator, _) = makeCoordinator()
        let errors = Tally()
        coordinator.onListenerError = { _ in errors.increment() }

        struct Boom: Error {}
        coordinator.ensureListenerForTesting { _ in throw Boom() }
        await settle(until: { errors.value == 1 }, "the start failure was never reported")

        XCTAssertEqual(coordinator.listenerPhaseForTesting, "idle")
        XCTAssertNil(coordinator.controlListener)

        coordinator.ensureListenerForTesting { _ in }
        await settle(
            until: { coordinator.listenerPhaseForTesting == "running" },
            "a bring-up after a failed one never bound")
        XCTAssertNotNil(coordinator.controlListener)
    }

    /// `server.start(controlListener:)` binds its OWN listener on 7447 when
    /// handed nil, so the bring-up window must not read as "no listener".
    @MainActor
    func testControlListenerIsHandedOutWhileItIsStillStarting() async throws {
        let (coordinator, _) = makeCoordinator()
        let gate = Gate()
        let binding = ListenerBox()
        coordinator.ensureListenerForTesting { listener in
            binding.set(listener)
            try await gate.wait()
        }
        await settle(until: { binding.value != nil }, "the start step never ran")

        XCTAssertEqual(coordinator.listenerPhaseForTesting, "starting")
        XCTAssertTrue(
            coordinator.controlListener === binding.value,
            "a share started mid-bring-up must get THIS listener, not a second one on 7447")

        await gate.open()
        await settle(
            until: { coordinator.listenerPhaseForTesting == "running" }, "the bind never finished")
        XCTAssertTrue(coordinator.controlListener === binding.value)
    }

    /// A supersede that lands while the previous listener is still binding
    /// must wait for that bind to settle before stopping it — the whole reason
    /// the phase exists.
    @MainActor
    func testASupersededStartingListenerIsStoppedAfterItsStartSettles() async throws {
        let (coordinator, _) = makeCoordinator()
        let stopped = ListenerLog()
        coordinator.stopListenerForTesting = { stopped.record($0) }

        let gate = Gate()
        let first = ListenerBox()
        coordinator.ensureListenerForTesting { listener in
            first.set(listener)
            try await gate.wait()
        }
        await settle(until: { first.value != nil }, "the first start never ran")
        XCTAssertEqual(coordinator.listenerPhaseForTesting, "starting")

        let second = ListenerBox()
        coordinator.ensureListenerForTesting { listener in second.set(listener) }
        await settle(
            until: { coordinator.listenerPhaseForTesting == "running" },
            "the superseding bring-up never bound")

        // Stopping the first one HERE is what the old code did, and it did
        // nothing: its `start` had not returned, so the bind that followed put
        // it back on 7447 next to the one that replaced it.
        XCTAssertTrue(stopped.isEmpty, "nothing can be stopped until its own bind returns")

        await gate.open()
        await settle(until: { stopped.count == 1 }, "the superseded listener was never stopped")
        XCTAssertTrue(stopped.contains(try XCTUnwrap(first.value)))
        XCTAssertFalse(stopped.contains(try XCTUnwrap(second.value)))
        XCTAssertTrue(coordinator.controlListener === second.value)
    }

    /// A listener that HAS bound is stopped immediately on supersede — the
    /// deferral above is for the starting case only.
    @MainActor
    func testASupersededRunningListenerIsStoppedAtOnce() async throws {
        let (coordinator, _) = makeCoordinator()
        let stopped = ListenerLog()
        coordinator.stopListenerForTesting = { stopped.record($0) }

        let first = ListenerBox()
        coordinator.ensureListenerForTesting { listener in first.set(listener) }
        await settle(
            until: { coordinator.listenerPhaseForTesting == "running" },
            "the first bring-up never bound")

        coordinator.ensureListenerForTesting { _ in }
        await settle(until: { stopped.count == 1 }, "the replaced listener was never stopped")
        XCTAssertTrue(stopped.contains(try XCTUnwrap(first.value)))
    }

    /// Teardown racing a bring-up: `stopListener()` clears the state at once,
    /// and the listener that goes on to bind is stopped when it does.
    @MainActor
    func testStopListenerDuringABringUpTearsDownWhatItWasBinding() async throws {
        let (coordinator, _) = makeCoordinator()
        let stopped = ListenerLog()
        coordinator.stopListenerForTesting = { stopped.record($0) }

        let gate = Gate()
        let binding = ListenerBox()
        coordinator.ensureListenerForTesting { listener in
            binding.set(listener)
            try await gate.wait()
        }
        await settle(until: { binding.value != nil }, "the start step never ran")

        await coordinator.stopListener()
        XCTAssertEqual(coordinator.listenerPhaseForTesting, "idle")
        XCTAssertNil(coordinator.controlListener)
        XCTAssertTrue(stopped.isEmpty, "there is nothing bound to stop yet")

        await gate.open()
        await settle(
            until: { stopped.count == 1 },
            "a listener that bound after the teardown was left holding 7447")
        XCTAssertTrue(stopped.contains(try XCTUnwrap(binding.value)))
        XCTAssertEqual(coordinator.listenerPhaseForTesting, "idle")
    }

    // MARK: Helpers

    /// Let the coordinator's detached bring-up work run until `condition`
    /// holds. Yielding rather than `wait(for:)`: these tests are on the main
    /// actor and so is the bring-up, so blocking would deadlock the thing
    /// being waited for.
    @MainActor
    private func settle(
        until condition: @MainActor () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail(message, file: file, line: line)
    }

    /// A start step the test decides when to complete.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters = []
            for continuation in pending { continuation.resume() }
        }
    }

    /// The listener a bring-up was handed, captured from its start step.
    private final class ListenerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var listener: TailscreenControlListener?
        func set(_ listener: TailscreenControlListener) { lock.withLock { self.listener = listener } }
        var value: TailscreenControlListener? { lock.withLock { listener } }
    }

    /// Which listeners the coordinator asked to stop, and in what order.
    private final class ListenerLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [ObjectIdentifier] = []
        func record(_ listener: TailscreenControlListener) {
            lock.withLock { ids.append(ObjectIdentifier(listener)) }
        }
        var count: Int { lock.withLock { ids.count } }
        var isEmpty: Bool { lock.withLock { ids.isEmpty } }
        func contains(_ listener: TailscreenControlListener) -> Bool {
            lock.withLock { ids.contains(ObjectIdentifier(listener)) }
        }
    }

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
