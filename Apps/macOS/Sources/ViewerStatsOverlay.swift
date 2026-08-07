import AppKit
import Combine
import SwiftUI

/// Small "always-on-top" diagnostics overlay drawn in the viewer window's
/// top-left corner. Bound to a ``ViewerStatsModel`` (owned by the renderer)
/// so it follows real-time stat updates with no extra plumbing.
///
/// Toggled by the toolbar's chart button — see `ViewerToolbar`. The view's
/// `isHidden` is driven by `model.isVisible` so toggling on a live session
/// just flips the hosting view in and out without rebuilding state.
struct ViewerStatsOverlay: View {
    @ObservedObject var model: ViewerStatsModel

    var body: some View {
        let stats = model.stats
        VStack(alignment: .leading, spacing: 4) {
            if stats.isDegraded {
                Label(L("Connection degraded"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
            }
            row(L("Latency"), formatLatency(stats.latencyMs), color: latencyColor(stats.latencyMs))
            row(L("FPS"), String(format: "%.1f", stats.fps), color: fpsColor(stats.fps))
            row(
                L("Dropped"), formatDropped(stats.droppedPct, total: stats.framesDropped),
                color: dropColor(stats.droppedPct))
            row(L("Decode errs"), "\(stats.decodeFailures)", color: countColor(stats.decodeFailures))
            row(L("PLIs sent"), "\(stats.plisSent)")
            row(L("FEC recovered"), "\(stats.fecRecovered)")
            row(L("Bitrate"), formatBitrate(stats.bitrateBps))
            row(L("Codec"), stats.codec.map(formatCodec) ?? "—")
            row(L("Connection"), "Tailscale")
            chartSection
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(stats))
    }

    /// Two stacked sparklines — latency (top) and bitrate (bottom). Both
    /// share the same x-axis (1 sample per second, oldest left, newest right).
    /// Auto-scaled per chart so a quiet bitrate doesn't squash latency spikes.
    private var chartSection: some View {
        let history = model.history
        return VStack(alignment: .leading, spacing: 4) {
            Divider()
                .background(Color.white.opacity(0.18))
                .padding(.vertical, 2)
            chartRow(
                label: L("Latency"),
                samples: history.map(\.latencyMs),
                tint: Color(red: 0.55, green: 0.78, blue: 1.0),
                formatter: { String(format: "%.0f ms", $0) }
            )
            chartRow(
                label: L("Bitrate"),
                samples: history.map(\.bitrateBps),
                tint: Color(red: 0.65, green: 0.95, blue: 0.65),
                formatter: { bps in
                    if bps >= 1_000_000 { return String(format: "%.1fM", bps / 1_000_000) }
                    if bps >= 1_000 { return String(format: "%.0fk", bps / 1_000) }
                    return String(format: "%.0f", bps)
                }
            )
        }
        .frame(width: 200)
    }

    private func chartRow(
        label: String,
        samples: [Double?],
        tint: Color,
        formatter: (Double) -> String
    ) -> some View {
        let nonNil = samples.compactMap { $0 }
        let minV = nonNil.min() ?? 0
        let maxV = nonNil.max() ?? 0
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                if !nonNil.isEmpty {
                    Text("\(formatter(minV))–\(formatter(maxV))")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            Sparkline(samples: samples, minValue: minV, maxValue: maxV, tint: tint)
                .frame(height: 30)
        }
    }

    private func row(_ label: String, _ value: String, color: Color = .white) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 84, alignment: .leading)
            Text(value)
                .foregroundStyle(color)
        }
    }

    private func latencyColor(_ ms: Double?) -> Color {
        guard let ms else { return .white }
        if ms < 60 { return Color(red: 0.45, green: 1.0, blue: 0.55) }
        if ms < 150 { return Color(red: 1.0, green: 0.78, blue: 0.32) }
        return Color(red: 1.0, green: 0.45, blue: 0.45)
    }

    private func fpsColor(_ fps: Double) -> Color {
        if fps >= 50 { return Color(red: 0.45, green: 1.0, blue: 0.55) }
        if fps >= 24 { return Color(red: 1.0, green: 0.78, blue: 0.32) }
        return Color(red: 1.0, green: 0.45, blue: 0.45)
    }

    private func dropColor(_ pct: Double?) -> Color {
        guard let pct else { return .white }
        if pct < 1 { return Color(red: 0.45, green: 1.0, blue: 0.55) }
        if pct < 10 { return Color(red: 1.0, green: 0.78, blue: 0.32) }
        return Color(red: 1.0, green: 0.45, blue: 0.45)
    }

    /// White while the counter is zero, red once anything has gone wrong —
    /// a nonzero decode-failure count deserves attention even when small.
    private func countColor(_ count: Int) -> Color {
        count == 0 ? .white : Color(red: 1.0, green: 0.45, blue: 0.45)
    }

    private func formatLatency(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return String(format: "%.0f ms", ms)
    }

    private func formatDropped(_ pct: Double?, total: Int) -> String {
        guard let pct else { return "—" }
        return String(format: "%.1f%% (%d)", pct, total)
    }

    private func formatBitrate(_ bps: Double?) -> String {
        guard let bps, bps.isFinite else { return "—" }
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", bps / 1_000_000)
        }
        if bps >= 1_000 {
            return String(format: "%.0f kbps", bps / 1_000)
        }
        return String(format: "%.0f bps", bps)
    }

    private func formatCodec(_ codec: VideoCodec) -> String {
        switch codec {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    /// VoiceOver summary for the combined overlay element. Every fragment
    /// routes through `L(...)`; numbers that need printf precision are
    /// pre-formatted into a `String` first so the catalog key carries a
    /// plain `%@` / `%lld` (interpolating a raw Double would emit a
    /// specifier the catalog doesn't use).
    private func accessibilitySummary(_ stats: ViewerStats) -> String {
        var parts: [String] = []
        if let ms = stats.latencyMs {
            parts.append(L("latency \(Int(ms.rounded())) milliseconds"))
        }
        parts.append(L("\(Int(stats.fps.rounded())) frames per second"))
        if let pct = stats.droppedPct {
            let pctText = String(format: "%.1f", pct)
            parts.append(L("\(pctText) percent dropped"))
        }
        if stats.decodeFailures > 0 { parts.append(L("\(stats.decodeFailures) decode errors")) }
        if stats.plisSent > 0 { parts.append(L("\(stats.plisSent) keyframe requests sent")) }
        if stats.fecRecovered > 0 { parts.append(L("\(stats.fecRecovered) packets repaired")) }
        if let bps = stats.bitrateBps {
            let kbpsText = String(format: "%.0f", bps / 1000)
            parts.append(L("\(kbpsText) kilobits per second"))
        }
        if let codec = stats.codec { parts.append(L("codec \(formatCodec(codec))")) }
        let prefix = stats.isDegraded ? L("Stream stats, connection degraded: ") : L("Stream stats: ")
        return prefix + parts.joined(separator: ", ")
    }
}

/// Filled sparkline backed by an optional-Double sample buffer. Renders
/// a tinted area under the line, breaks across `nil` gaps, and draws a
/// dot on the most recent sample so a flat line still tells you whether
/// the stream is live or stale.
struct Sparkline: View {
    let samples: [Double?]
    let minValue: Double
    let maxValue: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let points = mappedPoints(in: size)
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.06))
                if points.count >= 2 {
                    areaPath(points: points, in: size)
                        .fill(tint.opacity(0.22))
                    linePath(points: points)
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                if let last = points.compactMap({ $0 }).last {
                    Circle()
                        .fill(tint)
                        .frame(width: 4, height: 4)
                        .position(x: last.x, y: last.y)
                }
            }
        }
    }

    private func mappedPoints(in size: CGSize) -> [CGPoint?] {
        guard !samples.isEmpty else { return [] }
        let denom = max(maxValue - minValue, 0.0001)
        let stepX: CGFloat =
            samples.count == 1
            ? size.width
            : size.width / CGFloat(samples.count - 1)
        return samples.enumerated().map { idx, value in
            guard let value else { return nil }
            let normalized = (value - minValue) / denom
            let y = size.height - CGFloat(normalized) * size.height
            return CGPoint(x: CGFloat(idx) * stepX, y: y)
        }
    }

    private func linePath(points: [CGPoint?]) -> Path {
        var path = Path()
        var pendingMove = true
        for p in points {
            guard let p else {
                pendingMove = true
                continue
            }
            if pendingMove {
                path.move(to: p)
                pendingMove = false
            } else {
                path.addLine(to: p)
            }
        }
        return path
    }

    private func areaPath(points: [CGPoint?], in size: CGSize) -> Path {
        var path = Path()
        var run: [CGPoint] = []
        func flush() {
            guard let first = run.first, let last = run.last, run.count >= 2 else {
                run.removeAll()
                return
            }
            path.move(to: CGPoint(x: first.x, y: size.height))
            for p in run { path.addLine(to: p) }
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
            run.removeAll()
        }
        for p in points {
            if let p { run.append(p) } else { flush() }
        }
        flush()
        return path
    }
}

/// Wraps `ViewerStatsOverlay` in an `NSHostingView` so AppKit code in
/// `AppState.ensureViewer()` can pin it as a subview of the viewer's
/// content view. The hosting view observes `model.isVisible` and toggles
/// `isHidden` on itself so the overlay disappears immediately on toggle —
/// no SwiftUI animation lag.
@MainActor
final class ViewerStatsOverlayHost {
    let view: NSHostingView<ViewerStatsOverlay>
    private let model: ViewerStatsModel
    private var visibilityCancellable: AnyCancellable?
    private var contentCancellable: AnyCancellable?
    /// Parent the overlay is pinned into. Weak so the host never retains
    /// the viewer's content view.
    private weak var parent: NSView?
    private var inset: CGFloat = 12

    init(model: ViewerStatsModel) {
        self.model = model
        let host = NSHostingView(rootView: ViewerStatsOverlay(model: model))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = []
        host.isHidden = !model.isVisible
        self.view = host
        // Drive isHidden off the model's `isVisible` via Combine so the
        // toolbar toggle is reflected the next runloop tick. The hosting
        // view stays attached either way — only its visibility flips —
        // which keeps the overlay's @ObservedObject subscription live.
        // Becoming visible also re-measures: the frame may be stale from
        // content that changed while hidden.
        self.visibilityCancellable = model.$isVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                self?.view.isHidden = !isVisible
                if isVisible { self?.applyLayout() }
            }
        // Re-measure on every stats snapshot. The frame used to be
        // measured once from `fittingSize` at build time, so the
        // degraded-warning row clipped when it appeared later. Snapshots
        // land ~1 Hz and `applyLayout` no-ops on an unchanged frame, so
        // this stays cheap.
        self.contentCancellable = model.$stats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyLayout()
            }
    }

    /// Pin the overlay to the top-left of `parent`, below the unified
    /// toolbar. Caller is expected to add `view` as a subview before
    /// calling; the placement then re-runs on every stats snapshot so the
    /// frame tracks content size changes.
    func layout(in parent: NSView, inset: CGFloat = 12) {
        self.parent = parent
        self.inset = inset
        applyLayout()
    }

    private func applyLayout() {
        guard let parent else { return }
        let size = view.fittingSize
        // The video lays out in the window's `contentLayoutRect` (the
        // toolbar-excluded subregion — see `AspectFitHostView.usableRect`);
        // raw `parent.bounds` spans the full window height with the
        // unified toolbar floating over its top, which parked the
        // overlay's first rows underneath the toolbar. Anchor below it.
        var top = parent.bounds.maxY
        if let window = parent.window {
            let usable = window.contentLayoutRect
            if !usable.isEmpty { top = min(top, usable.maxY) }
        }
        let frame = NSRect(
            x: inset,
            y: top - size.height - inset,
            width: size.width,
            height: size.height
        )
        if frame != view.frame { view.frame = frame }
        view.autoresizingMask = [.minYMargin, .maxXMargin]
    }
}
