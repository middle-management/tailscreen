import SwiftUI

/// SwiftUI renderer for the shared annotation canvas. Used by both the
/// sharer's borderless overlay panel and the viewer's window overlay; the
/// shape data is pulled from an ``AnnotationCanvasModel`` injected by the
/// host.
///
/// Each annotation is its own SwiftUI view composed via `ForEach`, so the
/// list diffs and only the changed shape re-renders during a drag (the
/// in-progress stroke). Ephemeral tools (clicks today) live in the same
/// `annotations` list and animate themselves via `withAnimation` in
/// `onAppear`; the model removes them from the list after their lifetime,
/// at which point SwiftUI tears their views down.
///
/// Pointer input arrives via a single zero-distance ``DragGesture``, which
/// fires for both taps and drags. Keyboard and right-click are handled by
/// the AppKit host (see ``AnnotationOverlayHostView``) — SwiftUI's gesture
/// system has no `rightMouseDown` equivalent and `.onKeyPress` doesn't
/// reliably receive events inside a borderless `NSPanel`.
struct AnnotationCanvasView: View {
    @ObservedObject var model: AnnotationCanvasModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Fully transparent fill so the ZStack always occupies the
                // GeometryReader. Without it, an empty annotations list
                // would collapse the ZStack to zero size, leaving no hit
                // area for the DragGesture — first click never lands and
                // the canvas can never gain its first annotation.
                Color.clear
                ForEach(model.annotations) { ann in
                    committedView(ann)
                }
                if let ip = model.inProgress {
                    inProgressView(ip)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let p = Self.normalize(value.location, in: geo.size)
                        if model.inProgress == nil {
                            model.pointerDown(at: p)
                        } else {
                            model.pointerMoved(to: p)
                        }
                    }
                    .onEnded { _ in
                        model.pointerUp()
                    }
            )
            .allowsHitTesting(model.isInputEnabled)
        }
    }

    /// Render a committed annotation. Ephemeral tools get their animated
    /// view; everything else falls through to ``AnnotationShape``.
    @ViewBuilder
    private func committedView(_ ann: Annotation) -> some View {
        if AnnotationCanvasModel.ephemeralLifetime(for: ann.tool) != nil {
            EphemeralAnnotationView(annotation: ann)
                .allowsHitTesting(false)
        } else {
            strokedShape(ann)
        }
    }

    /// Render the in-progress shape. For ephemeral tools the user sees a
    /// static preview during the drag (e.g. the click bullseye following
    /// the cursor); the animated form fires on `pointerUp` once the
    /// annotation moves into the committed list.
    @ViewBuilder
    private func inProgressView(_ ann: Annotation) -> some View {
        switch ann.tool {
        case .click:
            ClickMarker(annotation: ann)
                .allowsHitTesting(false)
        default:
            strokedShape(ann)
        }
    }

    @ViewBuilder
    private func strokedShape(_ ann: Annotation) -> some View {
        AnnotationShape(annotation: ann)
            .stroke(
                ann.color.swiftUI,
                style: StrokeStyle(
                    lineWidth: CGFloat(ann.width),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .allowsHitTesting(false)
    }

    private static func normalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let w = max(size.width, 1)
        let h = max(size.height, 1)
        return CGPoint(
            x: max(0, min(1, point.x / w)),
            y: max(0, min(1, point.y / h))
        )
    }
}

// MARK: - Shapes

/// A single committed or in-progress annotation as a SwiftUI `Shape`. The
/// path stays in normalized coordinates internally and scales itself to
/// whatever rect SwiftUI lays it out in.
private struct AnnotationShape: Shape {
    let annotation: Annotation

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let pts = annotation.points.map {
            CGPoint(x: rect.minX + $0.x * rect.width,
                    y: rect.minY + $0.y * rect.height)
        }
        guard let first = pts.first else { return path }

        switch annotation.tool {
        case .pen:
            // Quadratic-midpoint smoothing: each input sample becomes a
            // control point and the curve passes through the midpoints
            // between samples. Cheap, requires no extra state, and turns
            // the polyline of mouse-sample dots into a smooth stroke
            // without introducing perceptible lag.
            path.move(to: first)
            if pts.count == 2 {
                path.addLine(to: pts[1])
            } else if pts.count > 2 {
                for i in 1..<pts.count - 1 {
                    let mid = CGPoint(
                        x: (pts[i].x + pts[i + 1].x) / 2,
                        y: (pts[i].y + pts[i + 1].y) / 2
                    )
                    path.addQuadCurve(to: mid, control: pts[i])
                }
                if let last = pts.last { path.addLine(to: last) }
            }

        case .line:
            guard let last = pts.last, pts.count >= 2 else { return path }
            path.move(to: first)
            path.addLine(to: last)

        case .arrow:
            guard let last = pts.last, pts.count >= 2 else { return path }
            path.move(to: first)
            path.addLine(to: last)
            // Arrowhead: two short segments at ±150° from the shaft direction.
            let dx = last.x - first.x
            let dy = last.y - first.y
            let ang = atan2(dy, dx)
            let headLen = max(12.0, CGFloat(annotation.width) * 4)
            let headAng = CGFloat.pi * 5 / 6
            path.move(to: last)
            path.addLine(to: CGPoint(
                x: last.x + cos(ang + headAng) * headLen,
                y: last.y + sin(ang + headAng) * headLen
            ))
            path.move(to: last)
            path.addLine(to: CGPoint(
                x: last.x + cos(ang - headAng) * headLen,
                y: last.y + sin(ang - headAng) * headLen
            ))

        case .rectangle:
            guard let last = pts.last, pts.count >= 2 else { return path }
            path.addRect(CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            ))

        case .oval:
            guard let last = pts.last, pts.count >= 2 else { return path }
            path.addEllipse(in: CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            ))

        case .click:
            // Click is rendered by ClickMarker / EphemeralAnnotationView,
            // not as a stroked path.
            break
        }
        return path
    }
}

/// Static bullseye for an in-progress click annotation: outer stroked ring +
/// filled center dot. Sized off the stroke width so a thicker pen draws a
/// louder marker.
private struct ClickMarker: View {
    let annotation: Annotation

    var body: some View {
        let lineWidth = CGFloat(annotation.width)
        let outerR = max(14.0, lineWidth * 6)
        let innerR = max(3.0, lineWidth * 1.2)
        let color = annotation.color.swiftUI
        let center = annotation.points.first ?? .zero

        GeometryReader { geo in
            let cx = center.x * geo.size.width
            let cy = center.y * geo.size.height
            ZStack {
                Circle()
                    .stroke(color, lineWidth: lineWidth)
                    .frame(width: outerR * 2, height: outerR * 2)
                    .position(x: cx, y: cy)
                Circle()
                    .fill(color)
                    .frame(width: innerR * 2, height: innerR * 2)
                    .position(x: cx, y: cy)
            }
        }
    }
}

/// Animated view for a committed ephemeral annotation. Today only handles
/// `.click` (two staggered expanding rings + a fading center dot). When new
/// ephemeral tools land, dispatch off `annotation.tool` here.
private struct EphemeralAnnotationView: View {
    let annotation: Annotation

    var body: some View {
        switch annotation.tool {
        case .click:
            ClickRippleView(annotation: annotation)
        default:
            // Permanent tools shouldn't end up here, but render statically
            // as a safe fallback if a new ephemeral tool is added without
            // a view to match.
            EmptyView()
        }
    }
}

/// Two staggered expanding rings + a fading center dot. Each component
/// animates via `withAnimation` in `onAppear`; the model removes the
/// annotation from the canvas list after the lifetime elapses, at which
/// point SwiftUI tears this view down.
private struct ClickRippleView: View {
    let annotation: Annotation

    /// Eased progress 0→1 for each component. Driving them as separate
    /// state values lets the easing curves and durations differ.
    @State private var ring1: Double = 0
    @State private var ring2: Double = 0
    @State private var dotFade: Double = 0

    private static let totalDuration: Double = AnnotationCanvasModel.clickAnimationDuration

    var body: some View {
        let color = annotation.color
        let lineWidth = CGFloat(annotation.width)
        let startR = max(8.0, lineWidth * 3)
        let endR = max(48.0, lineWidth * 14)
        let dotR = max(3.0, lineWidth * 1.5)
        let center = annotation.points.first ?? .zero

        GeometryReader { geo in
            let cx = center.x * geo.size.width
            let cy = center.y * geo.size.height
            ZStack {
                ring(progress: ring1, lineWidth: lineWidth, color: color, startR: startR, endR: endR)
                    .position(x: cx, y: cy)
                ring(progress: ring2, lineWidth: lineWidth, color: color, startR: startR, endR: endR)
                    .position(x: cx, y: cy)
                Circle()
                    .fill(color.swiftUI.opacity((1 - dotFade) * color.a))
                    .frame(width: dotR * 2, height: dotR * 2)
                    .position(x: cx, y: cy)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            // Ring 1: full lifetime, ease-out, opacity 1→0.
            withAnimation(.easeOut(duration: Self.totalDuration)) {
                ring1 = 1
            }
            // Ring 2: starts at 25% of the lifetime, runs for the rest.
            withAnimation(.easeOut(duration: Self.totalDuration * 0.75)
                .delay(Self.totalDuration * 0.25)) {
                ring2 = 1
            }
            // Center dot: fades out over the first 60% of the lifetime.
            withAnimation(.easeOut(duration: Self.totalDuration * 0.6)) {
                dotFade = 1
            }
        }
    }

    /// Single expanding ring driven by `progress` 0→1.
    @ViewBuilder
    private func ring(progress: Double, lineWidth: CGFloat, color: Annotation.RGBA,
                      startR: CGFloat, endR: CGFloat) -> some View {
        let radius = startR + CGFloat(progress) * (endR - startR)
        let alpha = (1.0 - progress) * color.a
        Circle()
            .stroke(color.swiftUI.opacity(alpha), lineWidth: lineWidth)
            .frame(width: radius * 2, height: radius * 2)
    }
}

// MARK: - Color bridge

extension Annotation.RGBA {
    var swiftUI: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
