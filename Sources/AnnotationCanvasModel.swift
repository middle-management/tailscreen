import AppKit
import Combine
import Foundation

/// Shared annotation canvas state used by both the sharer overlay (full-screen
/// borderless panel) and the viewer overlay (subview of the viewer window).
/// Holds committed shapes and the in-progress shape being dragged.
///
/// Coordinates on every ``Annotation`` are normalized to [0, 1] with origin at
/// the top-left, so the same shape renders identically on both ends regardless
/// of canvas size. Callers convert pointer locations into normalized space
/// before invoking ``pointerDown(at:)`` / ``pointerMoved(to:)``.
///
/// Networking flow: every locally produced op is forwarded via ``onOp`` so the
/// host can ship it over the wire; remote ops arrive via ``apply(remoteOp:)``
/// which only mutates state and never re-fires ``onOp``.
///
/// Lifetime: most tools produce permanent annotations. Clicks are ephemeral —
/// committed into ``annotations`` like everything else but auto-removed after
/// ``ephemeralLifetime(for:)``. The renderer is responsible for the visible
/// animation; the model only owns the storage and the removal timer.
@MainActor
final class AnnotationCanvasModel: ObservableObject {
    /// Shapes committed locally or received from a peer. Includes ephemeral
    /// shapes (e.g. clicks) for their lifetime.
    @Published private(set) var annotations: [Annotation] = []
    /// Shape currently being dragged. Rendered alongside ``annotations``.
    @Published private(set) var inProgress: Annotation?

    @Published var currentTool: AnnotationTool = .pen
    /// Color used for new annotations. Callers override with the per-author
    /// palette color so each participant draws in their own color.
    @Published var currentColor: Annotation.RGBA = Annotation.defaultColor
    /// When false, pointer events are dropped on the floor. Existing
    /// annotations still render — the overlay stays passive but visible.
    @Published var isInputEnabled: Bool = true

    /// Fired whenever this canvas produces an op that should be transmitted.
    var onOp: ((AnnotationOp) -> Void)?
    /// Fired when the user presses Esc inside the canvas.
    var onEscape: (() -> Void)?

    /// Total lifetime of a click ripple, start to fully gone.
    static let clickAnimationDuration: CFTimeInterval = 0.8

    /// Ids of *permanent* shapes this canvas created locally, in creation
    /// order. Ephemeral shapes (clicks) are deliberately excluded so Cmd-Z
    /// never fights an animation that's already removing them.
    private var localIDs: [UUID] = []
    /// mach-uptime ns of the last in-progress op we transmitted, for the
    /// drag-time throttle.
    private var lastDragEmitNs: UInt64 = 0
    /// Minimum gap between in-progress `.add` ops sent during a drag (~30 Hz).
    private static let dragEmitMinIntervalNs: UInt64 = 33_000_000

    var canUndo: Bool { !localIDs.isEmpty }
    var canClearAll: Bool { !annotations.isEmpty || inProgress != nil }

    /// Per-tool ephemeral lifetime. `nil` means the tool's annotations are
    /// permanent. Today only `.click` is ephemeral; this is the single
    /// place to flip more tools (or extend with a per-annotation field) if
    /// that ever becomes a real requirement.
    static func ephemeralLifetime(for tool: AnnotationTool) -> CFTimeInterval? {
        switch tool {
        case .click: return clickAnimationDuration
        default: return nil
        }
    }

    // MARK: - Pointer input

    /// Begin a new shape at `point` (normalized). No-op when input is disabled.
    func pointerDown(at point: CGPoint) {
        guard isInputEnabled else { return }
        inProgress = Annotation(
            id: UUID(),
            tool: currentTool,
            points: [point],
            color: currentColor,
            width: Annotation.defaultWidth
        )
    }

    /// Extend the in-progress shape to `point` (normalized). Throttled
    /// in-progress emits go out at ~30 Hz so receivers see the stroke build
    /// up live.
    func pointerMoved(to point: CGPoint) {
        guard isInputEnabled, var ip = inProgress else { return }
        switch ip.tool {
        case .pen:
            var pts = ip.points
            pts.append(point)
            ip = Annotation(id: ip.id, tool: ip.tool, points: pts, color: ip.color, width: ip.width)
        case .line, .arrow, .rectangle, .oval:
            // Two-point shapes: keep [start, current].
            let start = ip.points.first ?? point
            ip = Annotation(id: ip.id, tool: ip.tool, points: [start, point], color: ip.color, width: ip.width)
        case .click:
            // Single-point marker — let the cursor follow but never
            // accumulate points.
            ip = Annotation(id: ip.id, tool: ip.tool, points: [point], color: ip.color, width: ip.width)
        }
        inProgress = ip

        // Ephemeral tools animate on their own timeline on commit; emitting
        // mid-drag would start the animation early on the remote, so wait
        // for pointerUp.
        if Self.ephemeralLifetime(for: ip.tool) == nil {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs &- lastDragEmitNs >= Self.dragEmitMinIntervalNs {
                lastDragEmitNs = nowNs
                onOp?(.add(ip))
            }
        }
    }

    /// Commit the in-progress shape. Ephemeral tools (clicks today) commit
    /// even on a zero-distance drag and schedule themselves for removal;
    /// permanent tools require at least two points.
    func pointerUp() {
        guard isInputEnabled, let ip = inProgress else { return }
        inProgress = nil
        if let lifetime = Self.ephemeralLifetime(for: ip.tool) {
            commitEphemeral(ip, lifetime: lifetime)
            onOp?(.add(ip))
            return
        }
        // Discard trivial clicks on shape tools (no drag).
        if ip.points.count < 2 { return }
        annotations.append(ip)
        localIDs.append(ip.id)
        onOp?(.add(ip))
    }

    // MARK: - Remote ops & menu commands

    /// Apply a remote op. Mutates rendering state only; does NOT fire
    /// ``onOp`` so it won't loop back over the wire.
    func apply(remoteOp op: AnnotationOp) {
        switch op {
        case .add(let ann):
            if let lifetime = Self.ephemeralLifetime(for: ann.tool) {
                // Idempotent: a duplicate `.add` for an ephemeral that's
                // already animating is a no-op (don't stack two overlapping
                // animations on the same id).
                guard !annotations.contains(where: { $0.id == ann.id }) else { return }
                commitEphemeral(ann, lifetime: lifetime)
            } else if let idx = annotations.firstIndex(where: { $0.id == ann.id }) {
                // Upsert by id so progressive in-flight `.add` updates from
                // the originator's drag stream replace rather than stack.
                annotations[idx] = ann
            } else {
                annotations.append(ann)
            }
        case .undo(let id):
            annotations.removeAll { $0.id == id }
        case .clearAll:
            annotations.removeAll()
        }
    }

    /// Pop the most recent locally-created shape and broadcast the undo.
    /// No-op if the local stack is empty.
    func performLocalUndo() {
        guard let id = localIDs.popLast() else { return }
        annotations.removeAll { $0.id == id }
        onOp?(.undo(id))
    }

    /// Wipe every annotation everyone has drawn (local + remote) and
    /// broadcast the clear.
    func clearAll() {
        annotations.removeAll()
        localIDs.removeAll()
        inProgress = nil
        onOp?(.clearAll)
    }

    /// Notify the host that the user pressed Esc inside the canvas.
    func escapePressed() { onEscape?() }

    // MARK: - Ephemerals

    /// Insert an ephemeral annotation and schedule its removal. The renderer
    /// drives the visual animation off the view's lifetime; the model only
    /// guarantees the storage entry disappears after `lifetime`.
    private func commitEphemeral(_ annotation: Annotation, lifetime: CFTimeInterval) {
        annotations.append(annotation)
        let id = annotation.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(lifetime * 1000) + 50))
            self?.annotations.removeAll { $0.id == id }
        }
    }
}
