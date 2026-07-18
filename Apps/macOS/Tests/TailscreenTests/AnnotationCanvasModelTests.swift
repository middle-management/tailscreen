import XCTest

@testable import Tailscreen
@testable import TailscreenProtocol
@testable import TailscreenTransport

/// Unit tests for `AnnotationCanvasModel` — the pure canvas state machine
/// shared by the sharer overlay and the viewer overlay. Pointer input, the
/// local-undo stack, remote-op application (upsert / idempotence / no
/// echo-back), and ephemeral click lifetime. All-@MainActor, no UI.
final class AnnotationCanvasModelTests: XCTestCase {

    private func annotation(
        id: UUID = UUID(), tool: AnnotationTool = .pen, points: [CGPoint]
    ) -> Annotation {
        Annotation(
            id: id, tool: tool, points: points,
            color: Annotation.defaultColor, width: Annotation.defaultWidth)
    }

    // MARK: - Pointer input

    @MainActor
    func testPenStrokeCommitsAndEmitsAdd() {
        var ops: [AnnotationOp] = []
        let model = AnnotationCanvasModel()
        model.onOp = { ops.append($0) }
        model.currentTool = .pen

        model.pointerDown(at: CGPoint(x: 0.1, y: 0.1))
        XCTAssertNotNil(model.inProgress)
        model.pointerMoved(to: CGPoint(x: 0.2, y: 0.2))
        model.pointerUp()

        XCTAssertEqual(model.annotations.count, 1)
        let committed = model.annotations[0]
        XCTAssertEqual(committed.points, [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)])
        XCTAssertNil(model.inProgress)
        XCTAssertTrue(model.canUndo)

        // Every emitted op is an .add carrying the same shape id (the
        // mid-drag in-progress emit plus the commit).
        XCTAssertFalse(ops.isEmpty)
        for op in ops {
            guard case .add(let ann) = op else {
                return XCTFail("expected only .add ops, got \(op)")
            }
            XCTAssertEqual(ann.id, committed.id)
        }
        // The final emit is the committed shape itself.
        XCTAssertEqual(ops.last, .add(committed))
    }

    @MainActor
    func testTwoPointToolKeepsStartAndCurrent() {
        let model = AnnotationCanvasModel()
        model.currentTool = .rectangle

        model.pointerDown(at: CGPoint(x: 0.1, y: 0.1))
        model.pointerMoved(to: CGPoint(x: 0.3, y: 0.3))
        model.pointerMoved(to: CGPoint(x: 0.5, y: 0.2))

        XCTAssertEqual(
            model.inProgress?.points,
            [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.2)])
    }

    @MainActor
    func testZeroDragShapeIsDiscarded() {
        var ops: [AnnotationOp] = []
        let model = AnnotationCanvasModel()
        model.onOp = { ops.append($0) }
        model.currentTool = .line

        model.pointerDown(at: CGPoint(x: 0.4, y: 0.4))
        model.pointerUp()  // no move — a trivial click on a shape tool

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertTrue(ops.isEmpty)
        XCTAssertFalse(model.canUndo)
    }

    @MainActor
    func testDisabledInputDropsPointerEvents() {
        var ops: [AnnotationOp] = []
        let model = AnnotationCanvasModel()
        model.onOp = { ops.append($0) }
        model.isInputEnabled = false

        model.pointerDown(at: CGPoint(x: 0.1, y: 0.1))
        XCTAssertNil(model.inProgress)
        model.pointerMoved(to: CGPoint(x: 0.2, y: 0.2))
        model.pointerUp()

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertTrue(ops.isEmpty)
    }

    // MARK: - Remote ops

    @MainActor
    func testRemoteAddUpsertsById() {
        let model = AnnotationCanvasModel()
        let id = UUID()

        // Progressive in-flight adds from the originator's drag stream
        // replace the shape rather than stacking copies.
        model.apply(remoteOp: .add(annotation(id: id, points: [CGPoint(x: 0.1, y: 0.1)])))
        model.apply(
            remoteOp: .add(
                annotation(id: id, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)])))

        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertEqual(model.annotations[0].points.count, 2)
    }

    @MainActor
    func testRemoteOpsNeverRefireOnOp() {
        var ops: [AnnotationOp] = []
        let model = AnnotationCanvasModel()
        model.onOp = { ops.append($0) }

        let ann = annotation(points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)])
        model.apply(remoteOp: .add(ann))
        model.apply(remoteOp: .undo(ann.id))
        model.apply(remoteOp: .clearAll)

        // apply(remoteOp:) mutates state only — echoing back over the wire
        // would loop ops between peers forever.
        XCTAssertTrue(ops.isEmpty)
    }

    @MainActor
    func testRemoteUndoRemovesShape() {
        let model = AnnotationCanvasModel()
        let ann = annotation(points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)])
        model.apply(remoteOp: .add(ann))
        model.apply(remoteOp: .undo(ann.id))
        XCTAssertTrue(model.annotations.isEmpty)
    }

    // MARK: - Local undo

    @MainActor
    func testLocalUndoPopsOnlyLocalShapes() throws {
        var ops: [AnnotationOp] = []
        let model = AnnotationCanvasModel()
        model.onOp = { ops.append($0) }

        // One remote shape, one local stroke.
        let remote = annotation(points: [CGPoint(x: 0.7, y: 0.7), CGPoint(x: 0.8, y: 0.8)])
        model.apply(remoteOp: .add(remote))
        model.pointerDown(at: CGPoint(x: 0.1, y: 0.1))
        model.pointerMoved(to: CGPoint(x: 0.2, y: 0.2))
        model.pointerUp()
        let localID = try XCTUnwrap(model.annotations.first(where: { $0.id != remote.id })).id

        ops.removeAll()
        model.performLocalUndo()

        // Local stroke is gone and broadcast as an undo; the remote shape
        // is not ours to undo.
        XCTAssertEqual(model.annotations.map(\.id), [remote.id])
        XCTAssertEqual(ops, [.undo(localID)])

        // Stack is empty now: a second undo is a silent no-op.
        ops.removeAll()
        model.performLocalUndo()
        XCTAssertEqual(model.annotations.map(\.id), [remote.id])
        XCTAssertTrue(ops.isEmpty)
    }

    @MainActor
    func testClearAllWipesEverythingAndBroadcasts() {
        var ops: [AnnotationOp] = []
        let model = AnnotationCanvasModel()
        model.onOp = { ops.append($0) }

        model.apply(
            remoteOp: .add(annotation(points: [CGPoint(x: 0.7, y: 0.7), CGPoint(x: 0.8, y: 0.8)])))
        model.pointerDown(at: CGPoint(x: 0.1, y: 0.1))
        model.pointerMoved(to: CGPoint(x: 0.2, y: 0.2))
        model.pointerUp()

        ops.removeAll()
        model.clearAll()

        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertNil(model.inProgress)
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(ops, [.clearAll])
    }

    // MARK: - Ephemeral clicks

    @MainActor
    func testClickCommitsWithoutDragAndIsNotUndoable() {
        var ops: [AnnotationOp] = []
        let model = AnnotationCanvasModel()
        model.onOp = { ops.append($0) }
        model.currentTool = .click

        model.pointerDown(at: CGPoint(x: 0.5, y: 0.5))
        model.pointerUp()

        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertEqual(model.annotations[0].points.count, 1)
        XCTAssertEqual(ops.count, 1)
        // Clicks are excluded from the undo stack — Cmd-Z must never fight
        // the removal animation.
        XCTAssertFalse(model.canUndo)
    }

    @MainActor
    func testClickAutoRemovesAfterLifetime() async throws {
        let model = AnnotationCanvasModel()
        model.currentTool = .click
        model.pointerDown(at: CGPoint(x: 0.5, y: 0.5))
        model.pointerUp()
        XCTAssertEqual(model.annotations.count, 1)

        // Lifetime is clickAnimationDuration (0.8 s) + 50 ms slop; wait
        // comfortably past it.
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(model.annotations.isEmpty)
    }

    @MainActor
    func testDuplicateRemoteEphemeralAddIsIdempotent() {
        let model = AnnotationCanvasModel()
        let click = annotation(tool: .click, points: [CGPoint(x: 0.5, y: 0.5)])

        model.apply(remoteOp: .add(click))
        model.apply(remoteOp: .add(click))

        // A duplicate .add for an ephemeral that's already animating must
        // not stack a second overlapping animation on the same id.
        XCTAssertEqual(model.annotations.count, 1)
    }

    @MainActor
    func testEphemeralLifetimeOnlyForClicks() {
        XCTAssertNotNil(AnnotationCanvasModel.ephemeralLifetime(for: .click))
        for tool in AnnotationTool.allCases where tool != .click {
            XCTAssertNil(AnnotationCanvasModel.ephemeralLifetime(for: tool))
        }
    }

    @MainActor
    func testEscapeFiresCallback() {
        let model = AnnotationCanvasModel()
        var fired = false
        model.onEscape = { fired = true }
        model.escapePressed()
        XCTAssertTrue(fired)
    }
}
