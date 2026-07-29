import Foundation

/// The receiving half of annotations: what a sharer has been asked to display.
///
/// **Not** `TailscreenViewerGtk.AnnotationStore`, which is the GTK viewer's
/// DRAWING store — live stroke tracking, tool mode, this participant's colour.
/// The name here says which half it is, because the first version of this file
/// was called `AnnotationStore` too and broke that viewer's build by shadowing
/// it through a shared import.
///
/// The macOS `AnnotationCanvasModel` does this *and* owns local drawing — tool
/// selection, drag tracking, an undo stack of the strokes this machine made.
/// A sharer that only displays what viewers send needs none of that, and
/// bringing it along would mean porting a `@Published` SwiftUI model to a
/// platform with no SwiftUI. So this is the half that is actually shared:
/// apply an op, drop what has aged out, hand back what to draw.
///
/// A value type with an injected clock, because the caller owns the thread and
/// tests must not sleep.
public struct ReceivedAnnotations: Sendable {
    /// How long a `.click` marker stays up. The same 0.8 s the macOS overlay
    /// animates over — a viewer pointing at something on two machines at once
    /// should see it vanish at the same moment on both.
    public static let clickLifetimeNs: UInt64 = 800_000_000

    /// Whether a tool's strokes disappear on their own, and after how long.
    ///
    /// Only `.click` is ephemeral today. Single place to change that, mirroring
    /// `AnnotationCanvasModel.ephemeralLifetime(for:)` on macOS — which should
    /// eventually call this instead of carrying its own copy.
    public static func ephemeralLifetimeNs(for tool: AnnotationTool) -> UInt64? {
        switch tool {
        case .click: return clickLifetimeNs
        default: return nil
        }
    }

    /// In arrival order — later strokes draw over earlier ones.
    public private(set) var annotations: [Annotation] = []
    /// Deadlines for the ephemeral ones, keyed by annotation id.
    private var expiries: [UUID: UInt64] = [:]

    public init() {}

    public var isEmpty: Bool { annotations.isEmpty }

    /// Apply one op. Returns whether anything changed, so a caller can skip a
    /// redraw — a viewer dragging a pen sends an op per few milliseconds, and
    /// most of them do change something, but `undo` of an unknown id does not.
    @discardableResult
    public mutating func apply(_ op: AnnotationOp, nowNs: UInt64) -> Bool {
        switch op {
        case .add(let annotation):
            // Upsert, not append: a drag re-sends the SAME id with a longer
            // point list as it grows, so appending would stack hundreds of
            // copies of one stroke and redraw them all.
            if let index = annotations.firstIndex(where: { $0.id == annotation.id }) {
                annotations[index] = annotation
            } else {
                annotations.append(annotation)
            }
            if let lifetime = Self.ephemeralLifetimeNs(for: annotation.tool) {
                expiries[annotation.id] = nowNs &+ lifetime
            }
            return true

        case .undo(let id):
            guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
            annotations.remove(at: index)
            expiries.removeValue(forKey: id)
            return true

        case .clearAll:
            guard !annotations.isEmpty else { return false }
            annotations.removeAll()
            expiries.removeAll()
            return true
        }
    }

    /// Drop anything past its deadline. Returns whether anything went.
    @discardableResult
    public mutating func expire(nowNs: UInt64) -> Bool {
        guard !expiries.isEmpty else { return false }
        let dead = expiries.filter { $0.value <= nowNs }.keys
        guard !dead.isEmpty else { return false }
        let deadSet = Set(dead)
        annotations.removeAll { deadSet.contains($0.id) }
        for id in deadSet { expiries.removeValue(forKey: id) }
        return true
    }

    /// When the next expiry falls due, for a caller that would rather sleep
    /// until then than poll.
    public var nextExpiryNs: UInt64? { expiries.values.min() }
}
