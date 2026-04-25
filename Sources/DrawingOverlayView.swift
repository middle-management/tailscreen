import AppKit

/// NSView that renders and captures annotations. Used both as the viewer's
/// overlay (subview of the viewer window's contentView, sitting above the
/// `AVSampleBufferDisplayLayer`) and as the sharer's overlay (contentView of
/// the borderless `SharerOverlayWindow` panel).
///
/// Coordinates stored on each ``Annotation`` are normalized to [0, 1] with
/// origin at the top-left. The view converts to/from its own bounds on every
/// mouse event and during draw.
///
/// Input:
///   • Left mouse drag  — draw the current tool's shape.
///   • Right click      — clear all annotations.
///   • 1–5              — select tool (pen/line/arrow/rectangle/oval).
///   • Cmd-Z            — undo the last shape created by this view.
///   • Esc              — request the host to hide the overlay.
@MainActor
final class DrawingOverlayView: NSView {
    /// Shapes already committed (either locally or received from a peer).
    private(set) var annotations: [Annotation] = []
    /// Shape currently being dragged; rendered along with ``annotations``.
    private var inProgress: Annotation?
    /// mach-uptime ns of the last in-progress op we transmitted, for the
    /// drag-time throttle.
    private var lastDragEmitNs: UInt64 = 0
    /// Minimum gap between in-progress `.add` ops sent during a drag.
    /// 30 Hz keeps remote rendering smooth without flooding the TCP back-
    /// channel — a typical 100-point pen stroke at 60 Hz mouse rate is
    /// only ~3 KB/s after JSON, but throttling halves that and matches
    /// most displays' refresh.
    private static let dragEmitMinIntervalNs: UInt64 = 33_000_000
    /// Ids of shapes this view created locally, in creation order. Used to
    /// scope Cmd-Z to the local user's own strokes.
    private var localIDs: [UUID] = []

    var currentTool: AnnotationTool = .pen

    /// Color used for new annotations made in this view. Defaults to the
    /// palette's first entry; callers (sharer/viewer overlay setup)
    /// override with the per-author color derived from a stable identity
    /// so each participant draws in their own color.
    var currentColor: Annotation.RGBA = Annotation.defaultColor

    /// When false, mouse events are ignored (passed through to the next
    /// responder). The view still renders existing annotations.
    var isInputEnabled: Bool = true

    /// Called whenever this view produces an op that should be transmitted
    /// and/or echoed into shared state.
    var onOp: ((AnnotationOp) -> Void)?

    /// Called when the user presses Esc inside the view.
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Apply a remote op. Only mutates local rendering state; does NOT fire
    /// ``onOp``, so it won't loop back over the wire.
    func apply(remoteOp op: AnnotationOp) {
        switch op {
        case .add(let ann):
            // Upsert by id so progressive `.add` updates from the
            // originator's mouseDragged stream replace the in-flight
            // shape rather than stack duplicates.
            if let idx = annotations.firstIndex(where: { $0.id == ann.id }) {
                annotations[idx] = ann
            } else {
                annotations.append(ann)
            }
        case .undo(let id):
            annotations.removeAll { $0.id == id }
        case .clearAll:
            annotations.removeAll()
        }
        needsDisplay = true
    }

    // MARK: - Coordinate helpers

    private func normalized(_ point: NSPoint) -> CGPoint {
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        // NSView default coordinate origin is bottom-left; normalize to
        // top-left so the math is identical on sharer + viewer.
        return CGPoint(
            x: max(0, min(1, point.x / w)),
            y: max(0, min(1, 1 - point.y / h))
        )
    }

    private func denormalized(_ p: CGPoint) -> NSPoint {
        NSPoint(x: p.x * bounds.width, y: (1 - p.y) * bounds.height)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard isInputEnabled else { super.mouseDown(with: event); return }
        let loc = convert(event.locationInWindow, from: nil)
        let p = normalized(loc)
        inProgress = Annotation(
            id: UUID(),
            tool: currentTool,
            points: [p],
            color: currentColor,
            width: Annotation.defaultWidth
        )
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInputEnabled, var ip = inProgress else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let p = normalized(loc)
        switch ip.tool {
        case .pen:
            var pts = ip.points
            pts.append(p)
            ip = Annotation(id: ip.id, tool: ip.tool, points: pts, color: ip.color, width: ip.width)
        case .line, .arrow, .rectangle, .oval:
            // Two-point shapes: keep [start, current].
            let start = ip.points.first ?? p
            ip = Annotation(id: ip.id, tool: ip.tool, points: [start, p], color: ip.color, width: ip.width)
        }
        inProgress = ip
        needsDisplay = true

        // Stream the in-progress shape over the back-channel so the remote
        // sees the stroke build up live instead of popping in only on
        // mouseUp. Throttled to ~30 Hz; receivers upsert by id so each
        // update replaces the previous in-progress shape.
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if nowNs &- lastDragEmitNs >= Self.dragEmitMinIntervalNs {
            lastDragEmitNs = nowNs
            onOp?(.add(ip))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isInputEnabled, let ip = inProgress else { return }
        inProgress = nil
        // Discard trivial clicks (no drag).
        if ip.points.count < 2 {
            needsDisplay = true
            return
        }
        annotations.append(ip)
        localIDs.append(ip.id)
        needsDisplay = true
        onOp?(.add(ip))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInputEnabled else { super.rightMouseDown(with: event); return }
        annotations.removeAll()
        localIDs.removeAll()
        inProgress = nil
        needsDisplay = true
        onOp?(.clearAll)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Esc (keyCode 53) — let the host decide what to do.
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        // Cmd-Z — undo the most recent shape this view created.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            guard let id = localIDs.popLast() else { return }
            annotations.removeAll { $0.id == id }
            needsDisplay = true
            onOp?(.undo(id))
            return
        }
        switch event.charactersIgnoringModifiers {
        case "1": currentTool = .pen
        case "2": currentTool = .line
        case "3": currentTool = .arrow
        case "4": currentTool = .rectangle
        case "5": currentTool = .oval
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Render every committed shape, then the in-progress one on top.
        for ann in annotations { draw(annotation: ann) }
        if let ip = inProgress { draw(annotation: ip) }
    }

    private func draw(annotation: Annotation) {
        let color = NSColor(
            srgbRed: CGFloat(annotation.color.r),
            green: CGFloat(annotation.color.g),
            blue: CGFloat(annotation.color.b),
            alpha: CGFloat(annotation.color.a)
        )
        color.setStroke()

        let path = NSBezierPath()
        path.lineWidth = CGFloat(annotation.width)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let pts = annotation.points.map(denormalized)
        guard let first = pts.first else { return }

        switch annotation.tool {
        case .pen:
            path.move(to: first)
            for p in pts.dropFirst() { path.line(to: p) }
            path.stroke()

        case .line:
            guard let last = pts.last, pts.count >= 2 else { return }
            path.move(to: first)
            path.line(to: last)
            path.stroke()

        case .arrow:
            guard let last = pts.last, pts.count >= 2 else { return }
            path.move(to: first)
            path.line(to: last)
            path.stroke()
            // Arrowhead: two short segments at ±150° from the shaft direction.
            let dx = last.x - first.x
            let dy = last.y - first.y
            let ang = atan2(dy, dx)
            let headLen = max(12.0, CGFloat(annotation.width) * 4)
            let headAng = CGFloat.pi * 5 / 6
            let head = NSBezierPath()
            head.lineWidth = CGFloat(annotation.width)
            head.lineCapStyle = .round
            head.move(to: last)
            head.line(to: NSPoint(
                x: last.x + cos(ang + headAng) * headLen,
                y: last.y + sin(ang + headAng) * headLen
            ))
            head.move(to: last)
            head.line(to: NSPoint(
                x: last.x + cos(ang - headAng) * headLen,
                y: last.y + sin(ang - headAng) * headLen
            ))
            head.stroke()

        case .rectangle:
            guard let last = pts.last, pts.count >= 2 else { return }
            let rect = NSRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
            NSBezierPath(rect: rect).apply(strokeWidth: CGFloat(annotation.width))

        case .oval:
            guard let last = pts.last, pts.count >= 2 else { return }
            let rect = NSRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
            NSBezierPath(ovalIn: rect).apply(strokeWidth: CGFloat(annotation.width))
        }
    }
}

private extension NSBezierPath {
    func apply(strokeWidth: CGFloat) {
        lineWidth = strokeWidth
        lineCapStyle = .round
        lineJoinStyle = .round
        stroke()
    }
}
