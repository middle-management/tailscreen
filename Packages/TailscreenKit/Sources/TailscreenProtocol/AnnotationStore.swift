import Foundation

/// What a pointer drag over the video does.
public enum AnnotationMode: Sendable, Equatable {
    /// Not drawing — pointer drags zoom/pan or (if granted) drive remote control.
    case off
    /// Drawing with `tool` — pointer drags annotate. Mirrors the mac viewer's
    /// toolbar tool group (pen / line / arrow / rectangle / oval / click).
    case drawing(AnnotationTool)

    /// The active tool, or nil when drawing is off.
    public var tool: AnnotationTool? {
        if case .drawing(let tool) = self { return tool }
        return nil
    }
}

/// A **viewer's** annotation canvas: committed strokes (local + relayed from
/// the sharer) plus the in-progress stroke being drawn.
///
/// The counterpart of ``ReceivedAnnotations``, which is the *sharer's* half —
/// display-only, no local drawing, no undo stack. This one owns the drawing:
/// live drag tracking, the tool latch, the relay of finalized ops. Two types
/// because the two roles genuinely differ, and a sharer that only displays what
/// viewers send needs none of the machinery below.
///
/// Portable, and it always was — Foundation plus this module, with nothing
/// toolkit-specific in it. It lived in `TailscreenViewerGtk` until the WinUI
/// viewer needed the identical canvas, and copying it would have guaranteed the
/// two drifted. Each host reads it differently and that is the point: GTK takes
/// `renderData` (flattened arrays for its GL shader), WinUI takes
/// ``visibleAnnotations`` and hands them to ``AnnotationRasterizer``.
///
/// Threading: the render side reads on the host's UI thread, capture writes on
/// it, and the back-channel's inbound handler applies remote ops from its own
/// task — so strokes are lock-guarded. Finalized local ops are handed to
/// `onLocalOp` for the host to relay over the back-channel.
///
/// Coordinates are normalized `[0, 1]` in the video frame (origin top-left) —
/// the same space `Annotation`/`InputEvent` use — so a viewer stroke lands in
/// the right place on the sharer's screen.
public final class AnnotationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var strokes: [Annotation] = []
    private var live: [CGPoint] = []
    /// Tool the in-progress stroke was started with — latched at `beginStroke`
    /// so switching tools mid-drag can't reshape the stroke under way.
    private var liveTool: AnnotationTool = .pen
    private var requestRedraw: (() -> Void)?

    /// Current drawing mode (main-thread only: the toolbar sets it, capture
    /// reads it).
    public var mode: AnnotationMode = .off
    /// This participant's stroke color. Assigned once from the local identity —
    /// exactly like the mac viewer, which sets
    /// `paletteColor(forIdentity: localIdentity())` rather than offering a
    /// picker — so each participant always draws in the same color, and the
    /// same machine keeps its color across reconnects and relaunches.
    public var color: Annotation.RGBA = Annotation.RGBA.paletteColor(
        forIdentity: AnnotationStore.localIdentity())

    /// Stable per-machine drawing identity, mirroring the mac's
    /// `Host.current().localizedName + TailscreenInstance.hostnameSuffix`.
    /// Deliberately NOT the tsnet node name: that carries a fresh UUID each
    /// launch, which would reshuffle this viewer's color every run.
    public static func localIdentity() -> String {
        let host = ProcessInfo.processInfo.hostName
        let name = host.isEmpty ? "tailscreen-viewer" : host
        return "\(name)\(TailscreenInstance.hostnameSuffix)"
    }
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
        liveTool = mode.tool ?? .pen
        lock.unlock()
        redraw()
    }

    /// Extend the in-progress stroke. Freehand (`pen`) accumulates a trail;
    /// anchored shape tools keep the anchor and REPLACE the moving point, so a
    /// rectangle/oval/line/arrow rubber-bands from where the drag started.
    public func extendStroke(to point: CGPoint) {
        lock.lock()
        if !live.isEmpty {
            if AnnotationGeometry.isAnchored(liveTool) {
                if live.count == 1 { live.append(point) } else { live[live.count - 1] = point }
            } else {
                live.append(point)
            }
        }
        lock.unlock()
        redraw()
    }

    /// Commit the in-progress stroke as an `Annotation`, add it locally, and
    /// hand it to `onLocalOp` for relay. A tap (single point) still commits —
    /// that's exactly what the `click` marker is.
    public func endStroke() {
        lock.lock()
        let points = live
        let tool = liveTool
        live = []
        let color = self.color
        lock.unlock()
        guard !points.isEmpty else { return }
        // Shape tools that never moved (a click with, say, the rectangle tool)
        // would render as a degenerate dot — drop them rather than relay noise.
        if AnnotationGeometry.isAnchored(tool), tool != .click, points.count < 2 { return }
        let annotation = Annotation(
            id: UUID(), tool: tool, points: points, color: color,
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

    /// Everything that should currently be visible, including the in-progress
    /// stroke, as `Annotation` values.
    ///
    /// The renderer-agnostic view of this canvas, for a host that rasterizes
    /// rather than feeding a shader — the WinUI viewer draws these straight
    /// into the decoded frame with ``AnnotationRasterizer/draw(_:into:)``.
    ///
    /// The live stroke is synthesized with a **stable id** derived from nothing
    /// (a fresh UUID each call would be fine here since nothing dedupes on it),
    /// but it is deliberately materialized rather than omitted: a viewer that
    /// cannot see its own stroke until the drag ends has no idea whether
    /// drawing is working.
    public var visibleAnnotations: [Annotation] {
        lock.lock()
        let committed = strokes
        let livePoints = live
        let liveShape = liveTool
        let liveColor = color
        lock.unlock()
        guard !livePoints.isEmpty else { return committed }
        return committed + [
            Annotation(
                id: Self.liveStrokeID, tool: liveShape, points: livePoints,
                color: liveColor, width: Annotation.defaultWidth)
        ]
    }

    /// Identity for the in-progress stroke. Fixed rather than fresh so a
    /// renderer that diffs by id sees one stroke growing rather than a new one
    /// every frame — the same upsert-not-append rule `ReceivedAnnotations`
    /// documents for the relayed side.
    private static let liveStrokeID = UUID(
        uuidString: "00000000-0000-0000-0000-0000000000FF") ?? UUID()

    /// Flattened stroke geometry for `cgtkvideo_draw_annotations`: normalized
    /// x,y pairs, per-stroke vertex counts, per-stroke rgba (4 each), per-stroke
    /// pixel widths. Includes the in-progress live stroke last (in the current
    /// color) so drawing is visible mid-drag.
    /// - Parameters:
    ///   - aspect: the video's width÷height, so the `click` marker renders as a
    ///     circle rather than an ellipse on non-square video.
    ///   - renderHeight: the surface height in pixels. Arrowheads and the click
    ///     ring are FIXED pixel sizes shared with the mac
    ///     (`AnnotationGeometry.arrowHeadLength` / `clickOuterRadius`), so they
    ///     are converted into this store's normalized space here.
    public func renderData(
        aspect: Double = 1,
        renderHeight: Double = 540
    ) -> (xy: [Float], counts: [Int32], rgba: [Float], widths: [Float]) {
        lock.lock()
        let committed = strokes
        let livePoints = live
        let liveShape = liveTool
        let liveColor = color
        lock.unlock()

        var xy: [Float] = []
        var counts: [Int32] = []
        var rgba: [Float] = []
        var widths: [Float] = []

        // Each stroke's stored points are expanded to its renderable outline
        // (shape tools store only anchor+current — see `AnnotationGeometry`).
        let scale = renderHeight > 0 ? renderHeight : 540
        func append(tool: AnnotationTool, raw: [CGPoint], color: Annotation.RGBA, width: Double) {
            let points = AnnotationGeometry.polyline(
                tool: tool, points: raw,
                headLength: AnnotationGeometry.arrowHeadLength(strokeWidth: width) / scale,
                clickRadius: AnnotationGeometry.clickOuterRadius(strokeWidth: width) / scale,
                aspect: aspect)
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

        for stroke in committed {
            append(tool: stroke.tool, raw: stroke.points, color: stroke.color, width: stroke.width)
        }
        append(tool: liveShape, raw: livePoints, color: liveColor, width: Annotation.defaultWidth)
        return (xy, counts, rgba, widths)
    }
}
