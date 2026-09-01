import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenSharer

/// Pins the sharer's annotation fan-out ordering.
///
/// Annotation ops are a sequence about one stroke, not independent events:
/// `.undo(X)` only means anything to a peer that already holds `.add(X)`, and
/// `.clearAll` only clears what arrived before it. Every fan-out site used to
/// spawn its own `Task { await broadcastAnnotation(…) }` — one per relayed
/// viewer op, one per disconnect-cleanup undo, one per sharer stroke on each
/// of the three hosts — and separately-created tasks reach a shared await
/// point in whatever order the runtime picks.
///
/// That bug is worth a suite precisely because it does not reproduce on
/// demand: most runs come out in order, and the one that doesn't leaves a
/// stroke on every viewer's canvas for the rest of the share with nothing
/// left that can remove it. Enqueueing through the outbox makes the order a
/// property of the code rather than of the scheduler, so a reintroduced
/// `Task { … }` fails here every time instead of once a fortnight in front of
/// somebody.
///
/// No tsnet node: with no control listener the fan-out itself is a no-op, and
/// what is under test is the sequence the drain takes items in.
final class AnnotationFanOutOrderTests: XCTestCase {
    /// A server with no capture backend, no injector and no node — the
    /// headless shape the network suites already use.
    private func makeServer() -> TailscaleScreenShareServer {
        TailscaleScreenShareServer(captureFactory: nil, inputInjector: nil)
    }

    /// Collects fan-out ops and signals once `expected` of them have landed.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var ops: [AnnotationOp] = []
        private var expectation: XCTestExpectation?
        private var expected = 0

        func arm(_ expectation: XCTestExpectation, count: Int) {
            lock.lock()
            defer { lock.unlock() }
            self.expectation = expectation
            self.expected = count
        }

        func record(_ op: AnnotationOp) {
            lock.lock()
            ops.append(op)
            let done = ops.count == expected
            let expectation = self.expectation
            lock.unlock()
            if done { expectation?.fulfill() }
        }

        var all: [AnnotationOp] {
            lock.lock()
            defer { lock.unlock() }
            return ops
        }
    }

    /// The headline property: fan-out order IS enqueue order, for a run long
    /// enough that a task-per-op implementation would have inverted a pair.
    func testFanOutOrderMatchesEnqueueOrder() {
        let server = makeServer()
        let recorder = Recorder()
        let drained = expectation(description: "outbox drained")
        recorder.arm(drained, count: 200)
        server.onAnnotationBroadcastForTesting = { recorder.record($0) }

        let ids = (0..<200).map { _ in UUID() }
        for id in ids { server.enqueueAnnotationBroadcast(.undo(id)) }
        wait(for: [drained], timeout: 5)

        XCTAssertEqual(recorder.all, ids.map { AnnotationOp.undo($0) })
    }

    /// The pairing that actually breaks a canvas: an `.undo` reaching viewers
    /// before the `.add` it refers to is dropped as an unknown id, and the
    /// stroke can never be removed again.
    func testUndoNeverOvertakesItsAdd() {
        let server = makeServer()
        let recorder = Recorder()
        let drained = expectation(description: "outbox drained")
        recorder.arm(drained, count: 100)
        server.onAnnotationBroadcastForTesting = { recorder.record($0) }

        var expected: [AnnotationOp] = []
        for _ in 0..<50 {
            let annotation = Self.stroke()
            server.enqueueAnnotationBroadcast(.add(annotation))
            server.enqueueAnnotationBroadcast(.undo(annotation.id))
            expected.append(.add(annotation))
            expected.append(.undo(annotation.id))
        }
        wait(for: [drained], timeout: 5)

        XCTAssertEqual(recorder.all, expected)
    }

    /// The relay and the disconnect-cleanup undos share one outbox on purpose:
    /// a departing viewer's last `.add` may still be queued when its cleanup
    /// `.undo` is produced, and two queues would let the undo win.
    func testExclusionTargetDoesNotSplitTheOrdering() {
        let server = makeServer()
        let recorder = Recorder()
        let drained = expectation(description: "outbox drained")
        recorder.arm(drained, count: 3)
        server.onAnnotationBroadcastForTesting = { recorder.record($0) }

        let annotation = Self.stroke()
        let viewer = UUID()
        server.enqueueAnnotationBroadcast(.add(annotation), excludingConnection: viewer)
        server.enqueueAnnotationBroadcast(.undo(annotation.id), excludingConnection: viewer)
        server.enqueueAnnotationBroadcast(.clearAll)
        wait(for: [drained], timeout: 5)

        XCTAssertEqual(recorder.all, [.add(annotation), .undo(annotation.id), .clearAll])
    }

    private static func stroke() -> Annotation {
        Annotation(
            id: UUID(),
            tool: .pen,
            points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)],
            color: Annotation.defaultColor,
            width: Annotation.defaultWidth)
    }
}
