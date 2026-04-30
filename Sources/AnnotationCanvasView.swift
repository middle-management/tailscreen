import SwiftUI

/// SwiftUI renderer for the shared annotation canvas. Used by both the
/// sharer's borderless overlay panel and the viewer's window overlay; the
/// shape data is pulled from an ``AnnotationCanvasModel`` injected by the
/// host.
///
/// Each annotation is its own `Shape` view composed via `ForEach`, so
/// SwiftUI diffs the list and only the changed shape re-renders during a
/// drag (the in-progress stroke). Click ripples animate themselves via
/// `withAnimation` in `onAppear`, no timer needed.
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
                ForEach(model.annotations) { ann in
                    annotationView(ann)
                }
                if let ip = model.inProgress {
                    annotationView(ip)
                }
                ForEach(model.ephemeralClicks) { click in
                    EphemeralClickView(click: click)
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

    @ViewBuilder
    private func annotationView(_ ann: Annotation) -> some View {
        if ann.tool == .click {
            // In-progress click marker (bullseye). Committed clicks live in
            // `ephemeralClicks` instead and animate via EphemeralClickView.
            ClickMarker(annotation: ann)
                .allowsHitTesting(false)
        } else {
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
            path.move(to: first)
            for p in pts.dropFirst() { path.addLine(to: p) }

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
            // Drawn by ClickMarker (stroke + fill) instead of a single Shape.
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

/// Animated click ripple — two staggered expanding rings + a fading center
/// dot. Each component animates via `withAnimation` in `onAppear`; the
/// model removes the click from `ephemeralClicks` after the lifetime
/// elapses, at which point SwiftUI removes the view.
private struct EphemeralClickView: View {
    let click: AnnotationCanvasModel.EphemeralClick

    /// Eased progress 0→1 for each component. Driving them as separate
    /// state values lets the easing curves and durations differ.
    @State private var ring1: Double = 0
    @State private var ring2: Double = 0
    @State private var dotFade: Double = 0

    private static let totalDuration: Double = AnnotationCanvasModel.clickAnimationDuration

    var body: some View {
        let ann = click.annotation
        let color = ann.color
        let lineWidth = CGFloat(ann.width)
        let startR = max(8.0, lineWidth * 3)
        let endR = max(48.0, lineWidth * 14)
        let dotR = max(3.0, lineWidth * 1.5)
        let center = ann.points.first ?? .zero

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
