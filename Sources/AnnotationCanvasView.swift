import SwiftUI
import QuartzCore

/// SwiftUI renderer for the shared annotation canvas. Used by both the
/// sharer's borderless overlay panel and the viewer's window overlay; the
/// shape data is pulled from an ``AnnotationCanvasModel`` injected by the
/// host.
///
/// Rendering uses ``Canvas`` for the static + in-progress shapes and a
/// ``TimelineView(.animation)`` layered on top that only exists while
/// ephemeral click ripples are live — so an idle overlay holds no recurring
/// runloop work.
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
                Canvas { ctx, size in
                    for ann in model.annotations {
                        Self.draw(annotation: ann, in: &ctx, size: size)
                    }
                    if let ip = model.inProgress {
                        Self.draw(annotation: ip, in: &ctx, size: size)
                    }
                }

                if !model.ephemeralClicks.isEmpty {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { _ in
                        Canvas { ctx, size in
                            let now = CACurrentMediaTime()
                            for click in model.ephemeralClicks {
                                let elapsed = now - click.startTime
                                let progress = max(0, min(1, elapsed / AnnotationCanvasModel.clickAnimationDuration))
                                Self.drawEphemeralClick(click.annotation, progress: progress, in: &ctx, size: size)
                            }
                        }
                    }
                    .allowsHitTesting(false)
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

    // MARK: - Coordinates

    private static func normalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let w = max(size.width, 1)
        let h = max(size.height, 1)
        return CGPoint(
            x: max(0, min(1, point.x / w)),
            y: max(0, min(1, point.y / h))
        )
    }

    private static func denormalize(_ p: CGPoint, in size: CGSize) -> CGPoint {
        // Canvas coords are top-left origin, same as our normalized space.
        CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    private static func swiftUIColor(_ rgba: Annotation.RGBA) -> Color {
        Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    // MARK: - Shape drawing

    private static func draw(annotation: Annotation, in ctx: inout GraphicsContext, size: CGSize) {
        let color = swiftUIColor(annotation.color)
        let lineWidth = CGFloat(annotation.width)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        let pts = annotation.points.map { denormalize($0, in: size) }
        guard let first = pts.first else { return }

        switch annotation.tool {
        case .pen:
            var path = Path()
            path.move(to: first)
            for p in pts.dropFirst() { path.addLine(to: p) }
            ctx.stroke(path, with: .color(color), style: style)

        case .line:
            guard let last = pts.last, pts.count >= 2 else { return }
            var path = Path()
            path.move(to: first)
            path.addLine(to: last)
            ctx.stroke(path, with: .color(color), style: style)

        case .arrow:
            guard let last = pts.last, pts.count >= 2 else { return }
            var shaft = Path()
            shaft.move(to: first)
            shaft.addLine(to: last)
            ctx.stroke(shaft, with: .color(color), style: style)
            // Arrowhead: two short segments at ±150° from the shaft direction.
            let dx = last.x - first.x
            let dy = last.y - first.y
            let ang = atan2(dy, dx)
            let headLen = max(12.0, lineWidth * 4)
            let headAng = CGFloat.pi * 5 / 6
            var head = Path()
            head.move(to: last)
            head.addLine(to: CGPoint(
                x: last.x + cos(ang + headAng) * headLen,
                y: last.y + sin(ang + headAng) * headLen
            ))
            head.move(to: last)
            head.addLine(to: CGPoint(
                x: last.x + cos(ang - headAng) * headLen,
                y: last.y + sin(ang - headAng) * headLen
            ))
            ctx.stroke(head, with: .color(color), style: style)

        case .rectangle:
            guard let last = pts.last, pts.count >= 2 else { return }
            let rect = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
            ctx.stroke(Path(rect), with: .color(color), style: style)

        case .oval:
            guard let last = pts.last, pts.count >= 2 else { return }
            let rect = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width: abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
            ctx.stroke(Path(ellipseIn: rect), with: .color(color), style: style)

        case .click:
            // Bullseye marker: filled center dot + outer ring. Sized off
            // the stroke width so the marker scales with pen width.
            let outerRadius = max(14.0, lineWidth * 6)
            let innerRadius = max(3.0, lineWidth * 1.2)
            let outer = CGRect(
                x: first.x - outerRadius,
                y: first.y - outerRadius,
                width: outerRadius * 2,
                height: outerRadius * 2
            )
            ctx.stroke(Path(ellipseIn: outer), with: .color(color), lineWidth: lineWidth)
            let inner = CGRect(
                x: first.x - innerRadius,
                y: first.y - innerRadius,
                width: innerRadius * 2,
                height: innerRadius * 2
            )
            ctx.fill(Path(ellipseIn: inner), with: .color(color))
        }
    }

    // MARK: - Ripple

    /// Two staggered expanding rings + a fading center dot. Same shape as
    /// the original AppKit drawing — tweaked thresholds match the previous
    /// behaviour 1:1 so the ripple visual reads identical.
    private static func drawEphemeralClick(_ annotation: Annotation, progress: Double, in ctx: inout GraphicsContext, size: CGSize) {
        let pts = annotation.points.map { denormalize($0, in: size) }
        guard let center = pts.first else { return }
        let baseColor = annotation.color
        let lineWidth = CGFloat(annotation.width)
        let startRadius = max(8.0, lineWidth * 3)
        let endRadius = max(48.0, lineWidth * 14)

        for stagger in [0.0, 0.25] {
            let local = (progress - stagger) / (1.0 - stagger)
            guard local > 0, local < 1 else { continue }
            let eased = 1 - pow(1 - local, 2) // ease-out quad
            let radius = startRadius + CGFloat(eased) * (endRadius - startRadius)
            let alpha = (1.0 - local) * baseColor.a
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let ringColor = Color(.sRGB, red: baseColor.r, green: baseColor.g, blue: baseColor.b, opacity: alpha)
            ctx.stroke(Path(ellipseIn: rect), with: .color(ringColor), lineWidth: lineWidth)
        }

        // Center dot pulses for the first ~60% of the animation, then fades.
        let dotProgress = min(1.0, progress / 0.6)
        let dotAlpha = (1.0 - dotProgress) * baseColor.a
        if dotAlpha > 0 {
            let innerR = max(3.0, lineWidth * 1.5)
            let inner = CGRect(
                x: center.x - innerR,
                y: center.y - innerR,
                width: innerR * 2,
                height: innerR * 2
            )
            let dotColor = Color(.sRGB, red: baseColor.r, green: baseColor.g, blue: baseColor.b, opacity: dotAlpha)
            ctx.fill(Path(ellipseIn: inner), with: .color(dotColor))
        }
    }
}
