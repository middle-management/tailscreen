import AppKit
import QuartzCore

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
///   • 1–6              — select tool (pen/line/arrow/rectangle/oval/click).
///   • Cmd-Z            — undo the last shape created by this view.
///   • Esc              — request the host to hide the overlay.
@MainActor
final class DrawingOverlayView: NSView {
    /// Shapes already committed (either locally or received from a peer).
    private(set) var annotations: [Annotation] = []
    /// Shape currently being dragged; rendered along with ``annotations``.
    private var inProgress: Annotation?
    /// Live click markers, each with a wall-clock start time. Click is an
    /// attention-grabbing ripple that auto-disappears after
    /// ``clickAnimationDuration`` — it never lands in ``annotations`` and
    /// participates in neither undo nor clear-all (it self-prunes).
    private var ephemeralClicks: [EphemeralClick] = []
    /// 60 Hz tick that drives ripple animation + pruning. Lives only while
    /// at least one ephemeral click is on screen, then nils out.
    private var clickAnimationTimer: Timer?
    /// Total lifetime of a click ripple, start to fully gone.
    private static let clickAnimationDuration: CFTimeInterval = 0.8

    private struct EphemeralClick {
        let annotation: Annotation
        let startTime: CFTimeInterval
    }
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
            if ann.tool == .click {
                // Click is ephemeral on both ends — start the ripple
                // animation when the peer's mouseUp lands here.
                addEphemeralClick(ann)
            } else if let idx = annotations.firstIndex(where: { $0.id == ann.id }) {
                // Upsert by id so progressive `.add` updates from the
                // originator's mouseDragged stream replace the in-flight
                // shape rather than stack duplicates.
                annotations[idx] = ann
            } else {
                annotations.append(ann)
            }
        case .undo(let id):
            annotations.removeAll { $0.id == id }
        case .clearAll:
            annotations.removeAll()
            ephemeralClicks.removeAll()
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
        case .click:
            // Click is a single-point marker — let the cursor follow the
            // drag so the user can fine-tune position before mouseUp, but
            // never accumulate points.
            ip = Annotation(id: ip.id, tool: ip.tool, points: [p], color: ip.color, width: ip.width)
        }
        inProgress = ip
        needsDisplay = true

        // Stream the in-progress shape over the back-channel so the remote
        // sees the stroke build up live instead of popping in only on
        // mouseUp. Throttled to ~30 Hz; receivers upsert by id so each
        // update replaces the previous in-progress shape.
        // Click is ephemeral and animates on its own timeline — emitting
        // mid-drag would start the ripple early on the remote, so wait
        // for mouseUp and send a single `.add`.
        if ip.tool != .click {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs &- lastDragEmitNs >= Self.dragEmitMinIntervalNs {
                lastDragEmitNs = nowNs
                onOp?(.add(ip))
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isInputEnabled, let ip = inProgress else { return }
        inProgress = nil
        if ip.tool == .click {
            // Click commits as an ephemeral ripple — never enters
            // `annotations`/`localIDs`, so it can't be undone or
            // cleared (it disappears on its own).
            addEphemeralClick(ip)
            onOp?(.add(ip))
            return
        }
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
        clearAll()
    }

    // MARK: - Public command API (used by the app menu)

    /// Pop the most recent locally-created shape; mirror the op to the
    /// remote so peers see the undo. No-op if the local stack is empty.
    func performLocalUndo() {
        guard let id = localIDs.popLast() else { return }
        annotations.removeAll { $0.id == id }
        needsDisplay = true
        onOp?(.undo(id))
    }

    /// Wipe every annotation everyone has drawn (local + remote) and
    /// broadcast the clear. Bound to ⇧⌘⌫ from the Edit menu.
    func clearAll() {
        annotations.removeAll()
        localIDs.removeAll()
        ephemeralClicks.removeAll()
        inProgress = nil
        needsDisplay = true
        onOp?(.clearAll)
    }

    /// True iff there's at least one local shape that ``performLocalUndo``
    /// could remove. Drives menu-item enablement.
    var canUndo: Bool { !localIDs.isEmpty }

    /// True iff at least one annotation exists anywhere on this canvas.
    var canClearAll: Bool { !annotations.isEmpty || inProgress != nil }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Esc (keyCode 53) — let the host decide what to do.
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        // Cmd-Z — undo the most recent shape this view created. Kept here
        // as a fallback for when the overlay is firstResponder; the app
        // menu wires the same action via Edit → Undo.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            performLocalUndo()
            return
        }
        switch event.charactersIgnoringModifiers {
        case "1": currentTool = .pen
        case "2": currentTool = .line
        case "3": currentTool = .arrow
        case "4": currentTool = .rectangle
        case "5": currentTool = .oval
        case "6": currentTool = .click
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Render every committed shape, the in-progress one, then the
        // ephemeral click ripples last so they sit on top of any
        // overlapping permanent annotations.
        for ann in annotations { draw(annotation: ann) }
        if let ip = inProgress { draw(annotation: ip) }
        if !ephemeralClicks.isEmpty {
            let now = CACurrentMediaTime()
            for click in ephemeralClicks {
                let elapsed = now - click.startTime
                let progress = max(0, min(1, elapsed / Self.clickAnimationDuration))
                drawEphemeralClick(click.annotation, progress: progress)
            }
        }
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

        case .click:
            // Bullseye marker: filled center dot + outer ring. Sized off
            // the stroke width so the marker scales with the user's pen
            // width preference.
            let w = CGFloat(annotation.width)
            let outerRadius = max(14.0, w * 6)
            let innerRadius = max(3.0, w * 1.2)
            let outer = NSRect(
                x: first.x - outerRadius,
                y: first.y - outerRadius,
                width: outerRadius * 2,
                height: outerRadius * 2
            )
            let outerPath = NSBezierPath(ovalIn: outer)
            outerPath.lineWidth = w
            outerPath.stroke()
            let inner = NSRect(
                x: first.x - innerRadius,
                y: first.y - innerRadius,
                width: innerRadius * 2,
                height: innerRadius * 2
            )
            color.setFill()
            NSBezierPath(ovalIn: inner).fill()
        }
    }

    // MARK: - Ephemeral click ripple

    /// Insert an animated click marker. Idempotent on annotation id —
    /// a re-arrival of the same id resets the ripple's start time so a
    /// retransmit doesn't stack two overlapping ripples.
    private func addEphemeralClick(_ annotation: Annotation) {
        let now = CACurrentMediaTime()
        if let idx = ephemeralClicks.firstIndex(where: { $0.annotation.id == annotation.id }) {
            ephemeralClicks[idx] = EphemeralClick(annotation: annotation, startTime: now)
        } else {
            ephemeralClicks.append(EphemeralClick(annotation: annotation, startTime: now))
        }
        if clickAnimationTimer == nil {
            startClickAnimationTimer()
        }
        needsDisplay = true
    }

    /// Drive ephemeral click animation at ~60 Hz. Stops itself once the
    /// ephemeral list is drained so an idle overlay holds no runloop work.
    private func startClickAnimationTimer() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.ephemeralClicks.removeAll {
                    now - $0.startTime > Self.clickAnimationDuration
                }
                if self.ephemeralClicks.isEmpty {
                    self.clickAnimationTimer?.invalidate()
                    self.clickAnimationTimer = nil
                }
                self.needsDisplay = true
            }
        }
        // Common runloop mode keeps the ripple animating during menu
        // tracking and live-resize, where the default mode would pause it.
        RunLoop.main.add(timer, forMode: .common)
        clickAnimationTimer = timer
    }

    /// Two staggered expanding rings + a fading center dot. The ripple
    /// scales off the annotation's stroke width so a thicker pen draws
    /// a louder marker.
    private func drawEphemeralClick(_ annotation: Annotation, progress: Double) {
        let pts = annotation.points.map(denormalized)
        guard let center = pts.first else { return }
        let baseColor = NSColor(
            srgbRed: CGFloat(annotation.color.r),
            green: CGFloat(annotation.color.g),
            blue: CGFloat(annotation.color.b),
            alpha: CGFloat(annotation.color.a)
        )
        let w = CGFloat(annotation.width)
        let startRadius = max(8.0, w * 3)
        let endRadius = max(48.0, w * 14)

        // Two rings; the second starts a beat later so the marker reads
        // as a pulse rather than a single ring.
        for stagger in [0.0, 0.25] {
            let local = (progress - stagger) / (1.0 - stagger)
            guard local > 0, local < 1 else { continue }
            let eased = 1 - pow(1 - local, 2) // ease-out quad
            let radius = startRadius + CGFloat(eased) * (endRadius - startRadius)
            let alpha = CGFloat(1.0 - local) * CGFloat(annotation.color.a)
            let rect = NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let ring = NSBezierPath(ovalIn: rect)
            ring.lineWidth = w
            baseColor.withAlphaComponent(alpha).setStroke()
            ring.stroke()
        }

        // Center dot pulses for the first ~60% of the animation, then
        // fades out so nothing is left behind.
        let dotProgress = min(1.0, progress / 0.6)
        let dotAlpha = CGFloat(1.0 - dotProgress) * CGFloat(annotation.color.a)
        if dotAlpha > 0 {
            let innerR = max(3.0, w * 1.5)
            let inner = NSRect(
                x: center.x - innerR,
                y: center.y - innerR,
                width: innerR * 2,
                height: innerR * 2
            )
            baseColor.withAlphaComponent(dotAlpha).setFill()
            NSBezierPath(ovalIn: inner).fill()
        }
    }

    // MARK: - Lifecycle

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            // Detached from window — no point continuing to fire the
            // ripple timer (and it would otherwise leak the runloop ref).
            clickAnimationTimer?.invalidate()
            clickAnimationTimer = nil
            ephemeralClicks.removeAll()
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
