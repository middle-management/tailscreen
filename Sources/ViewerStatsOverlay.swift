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
        VStack(alignment: .leading, spacing: 2) {
            row("Latency", formatLatency(stats.latencyMs))
            row("FPS", String(format: "%.1f", stats.fps))
            row("Dropped", formatDropped(stats.droppedPct, total: stats.framesDropped))
            row("Bitrate", formatBitrate(stats.bitrateBps))
            row("Codec", stats.codec.map(formatCodec) ?? "—")
            row("Connection", "Tailscale")
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.55))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(stats))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 70, alignment: .leading)
            Text(value)
                .foregroundStyle(.white)
        }
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

    private func accessibilitySummary(_ stats: ViewerStats) -> String {
        var parts: [String] = []
        if let ms = stats.latencyMs { parts.append(String(format: "latency %.0f milliseconds", ms)) }
        parts.append(String(format: "%.0f frames per second", stats.fps))
        if let pct = stats.droppedPct { parts.append(String(format: "%.1f percent dropped", pct)) }
        if let bps = stats.bitrateBps { parts.append(String(format: "%.0f kilobits per second", bps / 1000)) }
        if let codec = stats.codec { parts.append("codec \(formatCodec(codec))") }
        return "Stream stats: " + parts.joined(separator: ", ")
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
        self.visibilityCancellable = model.$isVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak host] isVisible in
                host?.isHidden = !isVisible
            }
    }

    /// Place the overlay in the top-left of `parent`. Caller is expected
    /// to add `view` as a subview before calling.
    func layout(in parent: NSView, inset: CGFloat = 12) {
        let size = view.fittingSize
        view.frame = NSRect(
            x: inset,
            y: parent.bounds.height - size.height - inset,
            width: size.width,
            height: size.height
        )
        view.autoresizingMask = [.minYMargin, .maxXMargin]
    }
}
