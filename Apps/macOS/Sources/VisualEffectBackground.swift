import AppKit
import SwiftUI

/// SwiftUI bridge to `NSVisualEffectView`, used by the viewer's stats HUD and
/// shortcuts cheat-sheet (the sharer-side waiting placard builds its own
/// `NSVisualEffectView` in `AppState.makeWaitingPlacard`).
/// Default `.hudWindow` material keeps existing white-on-dark text legible.
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
