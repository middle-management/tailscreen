import AppKit
import SwiftUI

/// SwiftUI bridge to `NSVisualEffectView` so overlays read as real macOS
/// material panels — blurred, vibrant, and aware of light/dark mode and the
/// user's "Reduce transparency" setting — instead of a flat
/// `Color.black.opacity(…)` rectangle. Used by the viewer's stats HUD and the
/// keyboard-shortcuts cheat-sheet; the sharer-side waiting placard builds its
/// own `NSVisualEffectView` directly in AppKit (`AppState.makeWaitingPlacard`).
///
/// `.hudWindow` is the dark, vibrant HUD material — the right fit for a panel
/// floating over live video, and it keeps the existing white-on-dark text
/// legible without a colour rework.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
