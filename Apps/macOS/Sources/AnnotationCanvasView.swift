import AppKit
import SwiftUI

/// SwiftUI renderer for the shared annotation canvas, used by both the
/// sharer's borderless overlay panel and the viewer's window overlay.
///
/// Each annotation is its own view via `ForEach`, so only the changed shape
/// re-renders during a drag. Ephemeral tools (clicks) animate themselves via
/// `withAnimation` in `onAppear` (static under Reduce Motion); the model
/// removes them from the list after their lifetime.
///
/// Pointer input is a single zero-distance ``DragGesture`` (fires for taps
/// and drags). Keyboard and right-click go through the AppKit host (see
/// ``AnnotationOverlayHostView``) — SwiftUI has no `rightMouseDown`
/// equivalent, and `.onKeyPress` doesn't reliably fire in a borderless panel.
struct AnnotationCanvasView: View {
    @ObservedObject var model: AnnotationCanvasModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Without this fill, an empty annotations list collapses the
                // ZStack to zero size — no hit area, first click never lands.
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
            CGPoint(
                x: rect.minX + $0.x * rect.width,
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
            // Shared `AnnotationGeometry` so the Linux/GTK viewer derives an
            // identical arrowhead for relayed strokes.
            let barbs = AnnotationGeometry.arrowBarbs(
                from: first, to: last,
                headLength: AnnotationGeometry.arrowHeadLength(
                    strokeWidth: Double(annotation.width)))
            path.move(to: last)
            path.addLine(to: barbs.left)
            path.move(to: last)
            path.addLine(to: barbs.right)

        case .rectangle:
            guard let last = pts.last, pts.count >= 2 else { return path }
            path.addRect(
                CGRect(
                    x: min(first.x, last.x),
                    y: min(first.y, last.y),
                    width: abs(last.x - first.x),
                    height: abs(last.y - first.y)
                ))

        case .oval:
            guard let last = pts.last, pts.count >= 2 else { return path }
            path.addEllipse(
                in: CGRect(
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
        // Shared `AnnotationGeometry` so a relayed click marker is the same
        // size on both ends.
        let outerR = CGFloat(AnnotationGeometry.clickOuterRadius(strokeWidth: annotation.width))
        let innerR = CGFloat(AnnotationGeometry.clickInnerRadius(strokeWidth: annotation.width))
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

/// Two staggered expanding rings + a fading center dot, each animated via
/// `withAnimation` in `onAppear`.
///
/// Under Reduce Motion the ripple never scales: it falls back to the same
/// static bullseye as the in-progress preview (``ClickMarker``), on the same
/// lifetime-driven schedule.
private struct ClickRippleView: View {
    let annotation: Annotation

    /// Eased progress 0→1 for each component. Driving them as separate
    /// state values lets the easing curves and durations differ.
    @State private var ring1: Double = 0
    @State private var ring2: Double = 0
    @State private var dotFade: Double = 0

    private static let totalDuration: Double = AnnotationCanvasModel.clickAnimationDuration

    /// Read the workspace value directly rather than the SwiftUI environment:
    /// this view lives inside the borderless overlay panels' hosting views.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        if reduceMotion {
            ClickMarker(annotation: annotation)
                .allowsHitTesting(false)
        } else {
            animatedRipple
        }
    }

    @ViewBuilder
    private var animatedRipple: some View {
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
            withAnimation(
                .easeOut(duration: Self.totalDuration * 0.75)
                    .delay(Self.totalDuration * 0.25)
            ) {
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
    private func ring(
        progress: Double, lineWidth: CGFloat, color: Annotation.RGBA,
        startR: CGFloat, endR: CGFloat
    ) -> some View {
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
