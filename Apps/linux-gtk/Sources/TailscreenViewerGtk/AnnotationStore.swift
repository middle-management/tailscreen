import Foundation
import TailscreenProtocol

/// Whether the viewer is currently drawing annotations.
public enum AnnotationMode: Sendable, Equatable {
    /// Not drawing — pointer drags pan/zoom or (if granted) drive remote control.
    case off
    /// Freehand pen — pointer drags draw strokes over the video.
    case pen
}

/// Holds the shared annotation canvas for the GTK viewer: committed strokes
/// (local + relayed-from-sharer) plus the in-progress stroke being drawn. The
/// GLArea render reads it (`renderData`) on the GTK main thread; capture writes
/// it on the main thread; the back-channel's inbound handler applies remote ops
/// from its own task — so strokes are lock-guarded. Finalized local ops are
/// handed to `onLocalOp` for the host to relay over the back-channel.
///
/// Coordinates are normalized `[0, 1]` in the video frame (origin top-left) —
/// the same space `Annotation`/`InputEvent` use — so a viewer stroke lands in
/// the right place on the sharer's screen.
public final class AnnotationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var strokes: [Annotation] = []
    private var live: [CGPoint] = []
    private var requestRedraw: (() -> Void)?

    /// Current drawing mode (main-thread only: the toolbar sets it, capture
    /// reads it).
    public var mode: AnnotationMode = .off
    /// Current stroke color (main-thread only).
    public var color: Annotation.RGBA = Annotation.defaultColor
    /// Invoked on the main thread with each finalized LOCAL op so the host can
    /// relay it to the sharer. Remote ops (via `apply`) do NOT re-fire this.
    public var onLocalOp: ((AnnotationOp) -> Void)?

    public init() {}

    /// Clear all strokes + reset mode for a fresh session (the store outlives a
    /// single viewing session).
    public func resetForNewSession() {
        lock.lock()
        strokes.removeAll()
        live = []
        lock.unlock()
        mode = .off
        color = Annotation.defaultColor
        redraw()
    }

    /// Register the GLArea-repaint request (the view sets this once the area
    /// exists); invoked after every change so strokes appear immediately.
    public func setRedraw(_ redraw: @escaping () -> Void) {
        lock.lock()
        requestRedraw = redraw
        lock.unlock()
    }

    private func redraw() {
        lock.lock()
        let cb = requestRedraw
        lock.unlock()
        cb?()
    }

    // MARK: Remote ops (from the sharer's relay)

    /// Apply an inbound op (safe from any thread). Does not re-emit `onLocalOp`.
    public func apply(_ op: AnnotationOp) {
        lock.lock()
        switch op {
        case .add(let annotation): strokes.append(annotation)
        case .undo(let id): strokes.removeAll { $0.id == id }
        case .clearAll: strokes.removeAll()
        }
        lock.unlock()
        redraw()
    }

    // MARK: Local capture (main thread)

    public func beginStroke(at point: CGPoint) {
        lock.lock()
        live = [point]
        lock.unlock()
        redraw()
    }

    public func extendStroke(to point: CGPoint) {
        lock.lock()
        if !live.isEmpty { live.append(point) }
        lock.unlock()
        redraw()
    }

    /// Commit the in-progress stroke as an `Annotation`, emit `.add` locally,
    /// and hand it to `onLocalOp` for relay. A tap (single point) still commits
    /// as a one-point stroke.
    public func endStroke() {
        lock.lock()
        let points = live
        live = []
        let color = self.color
        lock.unlock()
        guard !points.isEmpty else { return }
        let annotation = Annotation(
            id: UUID(), tool: .pen, points: points, color: color,
            width: Annotation.defaultWidth)
        lock.lock()
        strokes.append(annotation)
        lock.unlock()
        onLocalOp?(.add(annotation))
        redraw()
    }

    /// Undo the most recent committed stroke (any author), relaying `.undo`.
    public func undo() {
        lock.lock()
        let removed = strokes.popLast()
        lock.unlock()
        if let removed { onLocalOp?(.undo(removed.id)) }
        redraw()
    }

    /// Clear the whole canvas, relaying `.clearAll`.
    public func clearAll() {
        lock.lock()
        strokes.removeAll()
        live = []
        lock.unlock()
        onLocalOp?(.clearAll)
        redraw()
    }

    // MARK: Rendering

    /// Flattened stroke geometry for `cgtkvideo_draw_annotations`: normalized
    /// x,y pairs, per-stroke vertex counts, per-stroke rgba (4 each), per-stroke
    /// pixel widths. Includes the in-progress live stroke last (in the current
    /// color) so drawing is visible mid-drag.
    public func renderData() -> (xy: [Float], counts: [Int32], rgba: [Float], widths: [Float]) {
        lock.lock()
        let committed = strokes
        let livePoints = live
        let liveColor = color
        lock.unlock()

        var xy: [Float] = []
        var counts: [Int32] = []
        var rgba: [Float] = []
        var widths: [Float] = []

        func append(points: [CGPoint], color: Annotation.RGBA, width: Double) {
            guard !points.isEmpty else { return }
            for p in points {
                xy.append(Float(p.x))
                xy.append(Float(p.y))
            }
            counts.append(Int32(points.count))
            rgba.append(Float(color.r))
            rgba.append(Float(color.g))
            rgba.append(Float(color.b))
            rgba.append(Float(color.a))
            widths.append(Float(width))
        }

        for stroke in committed { append(points: stroke.points, color: stroke.color, width: stroke.width) }
        append(points: livePoints, color: liveColor, width: Annotation.defaultWidth)
        return (xy, counts, rgba, widths)
    }
}
