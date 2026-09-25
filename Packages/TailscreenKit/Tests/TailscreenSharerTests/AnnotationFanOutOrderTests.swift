import Foundation
import TailscreenProtocol
import XCTest

@testable import TailscreenSharer

/// Pins the sharer's annotation fan-out ordering. `.undo(X)` only means
/// anything to a peer already holding `.add(X)`, and `.clearAll` only clears
/// what arrived before it — so a `Task { … }`-per-op fan-out (each reaching
/// its await point in scheduler-chosen order) can invert a pair and leave an
/// unremovable stroke on every viewer's canvas. Enqueueing through the outbox
/// makes order a property of the code, not the scheduler.
///
/// No tsnet node: fan-out is a no-op with no control listener; what's under
/// test is the order the drain takes items in.
final class AnnotationFanOutOrderTests: XCTestCase {
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

    /// An `.undo` reaching viewers before its `.add` is dropped as an unknown
    /// id, and the stroke can never be removed again.
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

    /// Relay and disconnect-cleanup undos share one outbox: a departing
    /// viewer's queued `.add` must not be overtaken by its cleanup `.undo`.
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
