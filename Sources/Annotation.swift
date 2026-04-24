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
