import Foundation
import CoreGraphics

/// Drawing tool the user has selected.
enum AnnotationTool: String, Codable, Sendable, CaseIterable {
    case pen
    case line
    case arrow
    case rectangle
    case oval
}

/// A single drawn shape. All coordinates are normalized to [0, 1] in the video
/// frame's coordinate space (origin top-left). The sharer's overlay panel and
/// the viewer's overlay subview both render against the same normalized space,
/// so viewer-originated ops land in the right place on the sharer's screen.
struct Annotation: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let tool: AnnotationTool
    let points: [CGPoint]
    /// Stroke color as sRGB components.
    let color: RGBA
    /// Stroke width in points, relative to the video's short edge.
    let width: Double

    struct RGBA: Codable, Sendable, Equatable {
        let r: Double
        let g: Double
        let b: Double
        let a: Double
    }

    static let defaultColor = RGBA(r: 1.0, g: 0.1, b: 0.15, a: 1.0)
    static let defaultWidth: Double = 3.0
}

extension Annotation.RGBA {
    /// Curated, visually-distinct palette for per-author drawing colors.
    /// Indexed deterministically off a stable identity string so each
    /// participant always draws in the same color across reconnects.
    static let palette: [Annotation.RGBA] = [
        .init(r: 0.95, g: 0.20, b: 0.25, a: 1.0),  // red
        .init(r: 0.20, g: 0.55, b: 1.00, a: 1.0),  // blue
        .init(r: 0.20, g: 0.78, b: 0.35, a: 1.0),  // green
        .init(r: 1.00, g: 0.65, b: 0.10, a: 1.0),  // orange
        .init(r: 0.70, g: 0.30, b: 0.95, a: 1.0),  // purple
        .init(r: 0.10, g: 0.78, b: 0.85, a: 1.0),  // teal
        .init(r: 0.95, g: 0.40, b: 0.70, a: 1.0),  // pink
        .init(r: 0.85, g: 0.75, b: 0.10, a: 1.0),  // yellow
    ]

    /// Pick a palette color deterministically from any string identity.
    /// Uses the truncated SipHash-style hash Swift exposes via String.hashValue
    /// (per-launch random salt) — *don't* use this here. Instead fold the
    /// UTF-8 bytes ourselves so the same identity → the same color across
    /// process launches and across machines.
    static func paletteColor(forIdentity identity: String) -> Annotation.RGBA {
        var h: UInt64 = 1469598103934665603 // FNV-1a offset basis
        for byte in identity.utf8 {
            h ^= UInt64(byte)
            h &*= 1099511628211
        }
        let idx = Int(h % UInt64(palette.count))
        return palette[idx]
    }
}

/// Operation on the shared annotation canvas. Only `.add`, `.undo` and
/// `.clearAll` exist today. The wire format is JSON inside the framed
/// `ScreenShareMessage.annotation` envelope.
enum AnnotationOp: Codable, Sendable, Equatable {
    case add(Annotation)
    case undo(UUID)
    case clearAll

    private enum CodingKeys: String, CodingKey { case type, annotation, id }
    private enum Kind: String, Codable { case add, undo, clearAll }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .add:
            self = .add(try c.decode(Annotation.self, forKey: .annotation))
        case .undo:
            self = .undo(try c.decode(UUID.self, forKey: .id))
        case .clearAll:
            self = .clearAll
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .add(let ann):
            try c.encode(Kind.add, forKey: .type)
            try c.encode(ann, forKey: .annotation)
        case .undo(let id):
            try c.encode(Kind.undo, forKey: .type)
            try c.encode(id, forKey: .id)
        case .clearAll:
            try c.encode(Kind.clearAll, forKey: .type)
        }
    }
}
