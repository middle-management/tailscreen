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
///
/// Timing: the two decisions that need a clock — dating an ephemeral stroke and
/// sweeping the ones that have aged out — read the `nowNs` handed to
/// ``apply(_:nowNs:)`` / ``endStroke(nowNs:)`` / ``expire(nowNs:)``, with the
/// process uptime clock as the fallback for a host that threads none. Same
/// shape as `VoiceDownlink.ingest(_:nowNs:)`, and for the same reason: a
/// time-based rule nobody can pin to a fixed instant is a rule nobody tests.
public final class AnnotationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var strokes: [Annotation] = []
    /// Deadlines for the ephemeral strokes, keyed by annotation id — the same
    /// bookkeeping ``ReceivedAnnotations`` keeps on the sharer's half, and
    /// deliberately reading its ``ReceivedAnnotations/ephemeralLifetimeNs(for:)``
    /// rather than a second table: a click marker that vanished at 0.8 s on the
    /// sharer's screen and stayed up on the viewer's would be two machines
    /// disagreeing about one gesture.
    private var expiries: [UUID: UInt64] = [:]
    private var live: [CGPoint] = []
    /// Tool the in-progress stroke was started with — latched at `beginStroke`
    /// so switching tools mid-drag can't reshape the stroke under way.
    private var liveTool: AnnotationTool = .pen
    /// Identity of the in-progress stroke, minted per drag. Stable for the
    /// drag's whole life so `visibleAnnotations` reports one stroke growing
    /// rather than a new one per frame; per-store rather than a shared
    /// sentinel, so two canvases can never collide.
    private var liveID = UUID()
    private var requestRedraw: (() -> Void)?

    /// Current drawing mode (main-thread only: the toolbar sets it, capture
    /// reads it).
    public var mode: AnnotationMode = .off
    /// This participant's stroke color. SEEDED from the local identity — a
    /// machine that never touches the color menu draws in the same color
    /// across reconnects and relaunches — and settable since the toolbars
    /// grew a picker (the mac viewer's color menu first, now the shared
    /// chrome's): per-stroke color rides the wire (`Annotation.color`), so a
    /// picked color reaches the sharer and other viewers with no protocol
    /// change.
    public var color = Annotation.RGBA.paletteColor(forIdentity: AnnotationStore.localIdentity())

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
        expiries.removeAll()
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
    ///
    /// **Upsert, not append.** A peer dragging a stroke re-sends the SAME id
    /// with a longer point list every few milliseconds; appending stacked
    /// hundreds of copies of one stroke, so the store grew without bound for as
    /// long as somebody kept drawing and the renderer drew every copy on top of
    /// itself. Same rule ``ReceivedAnnotations/apply(_:nowNs:)`` documents, and
    /// the same rule ``visibleAnnotations`` already relied on for the live local
    /// stroke.
    ///
    /// - Parameter nowNs: monotonic clock reading for this op's arrival, used
    ///   to date ephemeral strokes and to sweep the ones that have aged out.
    ///   Pass the host's clock where one is already threaded (deterministic,
    ///   testable); nil reads the process's monotonic uptime clock — the same
    ///   affordance `VoiceDownlink.ingest(_:nowNs:)` offers.
    public func apply(_ op: AnnotationOp, nowNs: UInt64? = nil) {
        let now = nowNs ?? Self.monotonicNowNs()
        lock.lock()
        switch op {
        case .add(let annotation):
            if let index = strokes.firstIndex(where: { $0.id == annotation.id }) {
                strokes[index] = annotation
            } else {
                strokes.append(annotation)
            }
            recordExpiryLocked(for: annotation, nowNs: now)
        case .undo(let id):
            strokes.removeAll { $0.id == id }
            expiries.removeValue(forKey: id)
        case .clearAll:
            strokes.removeAll()
            expiries.removeAll()
        }
        _ = sweepExpiredLocked(nowNs: now)
        lock.unlock()
        redraw()
    }

    // MARK: Ephemeral strokes

    /// Drop every stroke past its deadline. Returns whether anything went, so a
    /// host can skip a repaint it would otherwise queue.
    ///
    /// Deliberately does **not** call `redraw()`: both hosts sweep from inside
    /// their render pass (the GTK GLArea's `render`, the WinUI frame composite),
    /// where asking for another repaint from within the repaint is at best a
    /// wasted frame. `apply` sweeps too, so a canvas anyone is still drawing on
    /// stays swept without a render pass at all.
    ///
    /// - Parameter nowNs: monotonic clock reading; nil reads the uptime clock.
    @discardableResult
    public func expire(nowNs: UInt64? = nil) -> Bool {
        let now = nowNs ?? Self.monotonicNowNs()
        lock.lock()
        let changed = sweepExpiredLocked(nowNs: now)
        lock.unlock()
        return changed
    }

    /// When the next ephemeral stroke falls due, for a host that would rather
    /// schedule a repaint than poll. Nil when nothing is ephemeral.
    public var nextExpiryNs: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return expiries.values.min()
    }

    /// Record (or clear) a stroke's deadline. Clearing matters on the upsert
    /// path: an id re-sent under a permanent tool must not keep a deadline it
    /// picked up as a click.
    private func recordExpiryLocked(for annotation: Annotation, nowNs: UInt64) {
        if let lifetime = ReceivedAnnotations.ephemeralLifetimeNs(for: annotation.tool) {
            expiries[annotation.id] = nowNs &+ lifetime
        } else {
            expiries.removeValue(forKey: annotation.id)
        }
    }

    /// Caller must hold `lock`.
    private func sweepExpiredLocked(nowNs: UInt64) -> Bool {
        guard !expiries.isEmpty else { return false }
        let dead = Set(expiries.filter { $0.value <= nowNs }.keys)
        guard !dead.isEmpty else { return false }
        strokes.removeAll { dead.contains($0.id) }
        for id in dead { expiries.removeValue(forKey: id) }
        return true
    }

    private static func monotonicNowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    // MARK: Local capture (main thread)

    public func beginStroke(at point: CGPoint) {
        lock.lock()
        live = [point]
        liveID = UUID()
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
    ///
    /// - Parameter nowNs: monotonic clock reading, so a locally-drawn click
    ///   marker ages out on the same schedule as one relayed in. macOS's
    ///   `AnnotationCanvasModel` already expires its own clicks; a viewer whose
    ///   marker outlived the one it just put on the sharer's screen would be
    ///   the two halves of one gesture disagreeing.
    public func endStroke(nowNs: UInt64? = nil) {
        let now = nowNs ?? Self.monotonicNowNs()
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
        recordExpiryLocked(for: annotation, nowNs: now)
        _ = sweepExpiredLocked(nowNs: now)
        lock.unlock()
        onLocalOp?(.add(annotation))
        redraw()
    }

    /// Undo the most recent committed stroke (any author), relaying `.undo`.
    public func undo() {
        lock.lock()
        let removed = strokes.popLast()
        if let removed { expiries.removeValue(forKey: removed.id) }
        lock.unlock()
        if let removed { onLocalOp?(.undo(removed.id)) }
        redraw()
    }

    /// Clear the whole canvas, relaying `.clearAll`.
    public func clearAll() {
        lock.lock()
        strokes.removeAll()
        expiries.removeAll()
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
    /// The live stroke is materialized rather than omitted: a viewer that
    /// cannot see its own stroke until the drag ends has no idea whether
    /// drawing is working. Its id is stable for the whole drag (minted at
    /// `beginStroke`), so a renderer that diffs by id sees one stroke growing
    /// rather than a new one every frame — the same upsert-not-append rule
    /// `ReceivedAnnotations` documents for the relayed side.
    public var visibleAnnotations: [Annotation] {
        lock.lock()
        let committed = strokes
        let livePoints = live
        let liveShape = liveTool
        let liveColor = color
        let liveID = self.liveID
        lock.unlock()
        guard !livePoints.isEmpty else { return committed }
        return committed + [
            Annotation(
                id: liveID, tool: liveShape, points: livePoints,
                color: liveColor, width: Annotation.defaultWidth)
        ]
    }

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
