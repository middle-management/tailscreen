import XCTest

@testable import TailscreenProtocol

/// The viewer's annotation canvas — the half that owns local drawing and
/// applies what the sharer relays back. Two silent defects: an `.add` for an
/// id already on the canvas used to APPEND, so a dragged pen stroke grew the
/// store unbounded with every copy overdrawn; and nothing ever swept
/// ephemeral strokes, so a `.click` marker that vanishes on the sharer's
/// screen stayed on the viewer's for the rest of the share. Every case
/// drives an explicit `nowNs`, so no test needs to sleep.
final class AnnotationStoreTests: XCTestCase {
    private func stroke(
        _ id: UUID = UUID(), tool: AnnotationTool = .pen, points: Int = 2
    ) -> Annotation {
        Annotation(
            id: id, tool: tool,
            points: (0..<points).map { CGPoint(x: Double($0) / 10, y: Double($0) / 10) },
            color: Annotation.defaultColor, width: Annotation.defaultWidth)
    }

    private func click(_ id: UUID = UUID()) -> Annotation {
        Annotation(
            id: id, tool: .click, points: [CGPoint(x: 0.5, y: 0.5)],
            color: Annotation.defaultColor, width: Annotation.defaultWidth)
    }

    // MARK: Applying relayed ops

    func testAddPutsTheStrokeOnTheCanvas() {
        let store = AnnotationStore()
        let ann = stroke()
        store.apply(.add(ann), nowNs: 0)
        XCTAssertEqual(store.visibleAnnotations.map(\.id), [ann.id])
    }

    func testAddForAKnownIdUpdatesInPlaceRatherThanAppending() {
        let store = AnnotationStore()
        let id = UUID()
        store.apply(.add(stroke(id, points: 2)), nowNs: 0)
        store.apply(.add(stroke(id, points: 5)), nowNs: 1)
        store.apply(.add(stroke(id, points: 9)), nowNs: 2)

        let visible = store.visibleAnnotations
        XCTAssertEqual(visible.count, 1, "one stroke growing, not three strokes")
        XCTAssertEqual(visible.first?.points.count, 9, "and it is the LATEST version")
    }

    /// Replacing by remove-then-append would float the dragged stroke to
    /// the top, jumping in front of one drawn over it.
    func testUpsertKeepsPositionSoDrawOrderIsStable() {
        let store = AnnotationStore()
        let first = UUID()
        let second = UUID()
        store.apply(.add(stroke(first)), nowNs: 0)
        store.apply(.add(stroke(second)), nowNs: 0)
        store.apply(.add(stroke(first, points: 7)), nowNs: 1)

        XCTAssertEqual(store.visibleAnnotations.map(\.id), [first, second])
    }

    func testUndoRemovesJustThatStroke() {
        let store = AnnotationStore()
        let doomed = stroke()
        let kept = stroke()
        store.apply(.add(doomed), nowNs: 0)
        store.apply(.add(kept), nowNs: 0)
        store.apply(.undo(doomed.id), nowNs: 0)
        XCTAssertEqual(store.visibleAnnotations.map(\.id), [kept.id])
    }

    func testUndoOfAnUnknownIdChangesNothing() {
        let store = AnnotationStore()
        let kept = stroke()
        store.apply(.add(kept), nowNs: 0)
        store.apply(.undo(UUID()), nowNs: 0)
        XCTAssertEqual(store.visibleAnnotations.map(\.id), [kept.id])
    }

    func testClearAllEmptiesTheCanvas() {
        let store = AnnotationStore()
        store.apply(.add(stroke()), nowNs: 0)
        store.apply(.add(click()), nowNs: 0)
        store.apply(.clearAll, nowNs: 0)
        XCTAssertTrue(store.visibleAnnotations.isEmpty)
    }

    // MARK: Ephemeral strokes

    func testAClickMarkerSurvivesUpToItsDeadline() {
        let store = AnnotationStore()
        let marker = click()
        store.apply(.add(marker), nowNs: 1_000)

        let deadline = 1_000 + ReceivedAnnotations.clickLifetimeNs
        XCTAssertFalse(store.expire(nowNs: deadline - 1), "nothing due one nanosecond early")
        XCTAssertEqual(store.visibleAnnotations.map(\.id), [marker.id])
    }

    /// `<=`, matching `ReceivedAnnotations.expire` exactly — both halves
    /// must drop the same marker on the same nanosecond.
    func testAClickMarkerGoesAtItsDeadline() {
        let store = AnnotationStore()
        store.apply(.add(click()), nowNs: 1_000)

        let deadline = 1_000 + ReceivedAnnotations.clickLifetimeNs
        XCTAssertTrue(store.expire(nowNs: deadline))
        XCTAssertTrue(store.visibleAnnotations.isEmpty)
        XCTAssertFalse(store.expire(nowNs: deadline), "nothing left to sweep")
    }

    /// A host repaints per decoded frame, but ops arrive on the TCP
    /// back-channel — so `apply` sweeps too, even if video has stalled.
    func testAnOpSweepsWhatHasAgedOutWithoutWaitingForARenderPass() {
        let store = AnnotationStore()
        store.apply(.add(click()), nowNs: 0)
        let later = stroke()
        store.apply(.add(later), nowNs: ReceivedAnnotations.clickLifetimeNs)
        XCTAssertEqual(store.visibleAnnotations.map(\.id), [later.id])
    }

    func testANonEphemeralStrokeIsNeverSwept() {
        let store = AnnotationStore()
        let permanent = stroke(tool: .arrow)
        store.apply(.add(permanent), nowNs: 0)

        XCTAssertFalse(store.expire(nowNs: UInt64.max))
        XCTAssertEqual(store.visibleAnnotations.map(\.id), [permanent.id])
        XCTAssertNil(store.nextExpiryNs, "a permanent stroke schedules nothing")
    }

    /// Leaving the deadline behind would delete a pen stroke shortly after
    /// it stopped being a click.
    func testReAddingAnIdUnderAPermanentToolDropsItsOldDeadline() {
        let store = AnnotationStore()
        let id = UUID()
        store.apply(.add(click(id)), nowNs: 0)
        XCTAssertNotNil(store.nextExpiryNs)

        store.apply(.add(stroke(id, tool: .pen)), nowNs: 0)
        XCTAssertNil(store.nextExpiryNs)
        XCTAssertFalse(store.expire(nowNs: UInt64.max))
        XCTAssertEqual(store.visibleAnnotations.map(\.id), [id])
    }

    func testAnUndoneEphemeralLeavesNoDeadlineBehind() {
        let store = AnnotationStore()
        let marker = click()
        store.apply(.add(marker), nowNs: 0)
        store.apply(.undo(marker.id), nowNs: 0)
        XCTAssertNil(store.nextExpiryNs)
    }

    func testClearAllDropsPendingDeadlinesToo() {
        let store = AnnotationStore()
        store.apply(.add(click()), nowNs: 0)
        store.apply(.clearAll, nowNs: 0)
        XCTAssertNil(store.nextExpiryNs)
    }

    func testNextExpiryIsTheSoonestDeadline() {
        let store = AnnotationStore()
        store.apply(.add(click()), nowNs: 5_000)
        store.apply(.add(click()), nowNs: 1_000)
        XCTAssertEqual(store.nextExpiryNs, 1_000 + ReceivedAnnotations.clickLifetimeNs)
    }

    func testALocallyDrawnClickMarkerAgesOutLikeARelayedOne() {
        let store = AnnotationStore()
        store.mode = .drawing(.click)
        store.beginStroke(at: CGPoint(x: 0.5, y: 0.5))
        store.endStroke(nowNs: 0)
        XCTAssertEqual(store.visibleAnnotations.count, 1)

        XCTAssertTrue(store.expire(nowNs: ReceivedAnnotations.clickLifetimeNs))
        XCTAssertTrue(store.visibleAnnotations.isEmpty)
    }

    func testALocallyDrawnPenStrokeIsNotEphemeral() {
        let store = AnnotationStore()
        store.mode = .drawing(.pen)
        store.beginStroke(at: CGPoint(x: 0.1, y: 0.1))
        store.extendStroke(to: CGPoint(x: 0.4, y: 0.4))
        store.endStroke(nowNs: 0)

        XCTAssertFalse(store.expire(nowNs: UInt64.max))
        XCTAssertEqual(store.visibleAnnotations.count, 1)
    }

    /// The store outlives a session — a carried-over deadline would name an
    /// id no longer on the canvas.
    func testResetForNewSessionForgetsDeadlinesAsWellAsStrokes() {
        let store = AnnotationStore()
        store.apply(.add(click()), nowNs: 0)
        store.resetForNewSession()
        XCTAssertNil(store.nextExpiryNs)
        XCTAssertTrue(store.visibleAnnotations.isEmpty)
    }

    // MARK: Relay

    /// Re-firing `onLocalOp` for an inbound op would bounce every stroke
    /// back at the sharer, once per viewer.
    func testRelayedOpsDoNotEchoBackOutOverTheWire() {
        let store = AnnotationStore()
        final class Box: @unchecked Sendable { var ops: [AnnotationOp] = [] }
        let box = Box()
        store.onLocalOp = { box.ops.append($0) }
        store.apply(.add(stroke()), nowNs: 0)
        XCTAssertTrue(box.ops.isEmpty)
    }
}
