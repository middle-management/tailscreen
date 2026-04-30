import AppKit
import Combine
import Foundation
import QuartzCore

/// Shared annotation canvas state used by both the sharer overlay (full-screen
/// borderless panel) and the viewer overlay (subview of the viewer window).
/// Holds committed shapes, the in-progress shape being dragged, and a small
/// list of animated click ripples.
///
/// Coordinates on every ``Annotation`` are normalized to [0, 1] with origin at
/// the top-left, so the same shape renders identically on both ends regardless
/// of canvas size. Callers convert pointer locations into normalized space
/// before invoking ``pointerDown(at:)`` / ``pointerMoved(to:)``.
///
/// Networking flow: every locally produced op is forwarded via ``onOp`` so the
/// host can ship it over the wire; remote ops arrive via ``apply(remoteOp:)``
/// which only mutates state and never re-fires ``onOp``.
@MainActor
final class AnnotationCanvasModel: ObservableObject {
    /// Shapes already committed (locally or received from a peer).
    @Published private(set) var annotations: [Annotation] = []
    /// Shape currently being dragged. Rendered alongside ``annotations``.
    @Published private(set) var inProgress: Annotation?
    /// Live click ripples. Each carries its own start time and self-prunes
    /// after ``clickAnimationDuration``.
    @Published private(set) var ephemeralClicks: [EphemeralClick] = []

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

    /// Ids of shapes this canvas created locally, in creation order. Used to
    /// scope Cmd-Z to the local user's own strokes.
    private var localIDs: [UUID] = []
    /// mach-uptime ns of the last in-progress op we transmitted, for the
    /// drag-time throttle.
    private var lastDragEmitNs: UInt64 = 0
    /// Minimum gap between in-progress `.add` ops sent during a drag (~30 Hz).
    private static let dragEmitMinIntervalNs: UInt64 = 33_000_000

    struct EphemeralClick: Identifiable, Equatable {
        /// Unique per-instance id so a retransmit (which replaces an existing
        /// entry in `ephemeralClicks`) appears as a brand-new view to
        /// SwiftUI — restarting the ripple animation, matching the AppKit
        /// behaviour where the timer reset.
        let id = UUID()
        let annotation: Annotation
        let startTime: CFTimeInterval
    }

    var canUndo: Bool { !localIDs.isEmpty }
    var canClearAll: Bool { !annotations.isEmpty || inProgress != nil }

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

        // Click animates on its own timeline on commit; emitting mid-drag
        // would start the ripple early on the remote, so wait for pointerUp.
        if ip.tool != .click {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            if nowNs &- lastDragEmitNs >= Self.dragEmitMinIntervalNs {
                lastDragEmitNs = nowNs
                onOp?(.add(ip))
            }
        }
    }

    /// Commit the in-progress shape (or fire the click ripple). No-op if
    /// nothing is in progress.
    func pointerUp() {
        guard isInputEnabled, let ip = inProgress else { return }
        inProgress = nil
        if ip.tool == .click {
            // Click commits as an ephemeral ripple — never enters
            // `annotations`/`localIDs`, so it can't be undone or cleared.
            addEphemeralClick(ip)
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
            if ann.tool == .click {
                addEphemeralClick(ann)
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
            ephemeralClicks.removeAll()
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
        ephemeralClicks.removeAll()
        inProgress = nil
        onOp?(.clearAll)
    }

    /// Notify the host that the user pressed Esc inside the canvas.
    func escapePressed() { onEscape?() }

    // MARK: - Ephemeral clicks

    /// Insert (or refresh) an animated click marker. Idempotent on annotation
    /// id — a re-arrival of the same id resets the ripple's start time so a
    /// retransmit doesn't stack two overlapping ripples.
    private func addEphemeralClick(_ annotation: Annotation) {
        let now = CACurrentMediaTime()
        let click = EphemeralClick(annotation: annotation, startTime: now)
        if let idx = ephemeralClicks.firstIndex(where: { $0.annotation.id == annotation.id }) {
            ephemeralClicks[idx] = click
        } else {
            ephemeralClicks.append(click)
        }
        scheduleEphemeralPrune()
    }

    /// Drop expired clicks once the longest-lived one is past its deadline.
    /// Self-rescheduling so a burst of clicks coalesces into a single trailing
    /// prune pass.
    private func scheduleEphemeralPrune() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.clickAnimationDuration * 1000) + 50))
            guard let self else { return }
            let cutoff = CACurrentMediaTime() - Self.clickAnimationDuration
            self.ephemeralClicks.removeAll { $0.startTime <= cutoff }
        }
    }
}
