import SwiftUI

extension View {
    /// Record that this surface is what the user is looking at.
    ///
    /// The macOS app has no stored "current view" to observe: `MainWindowView`
    /// derives its pane per render from `sharingState` and `connectionState`,
    /// and `.claude/rules/macos-app.md` is explicit that even
    /// `NodeBringUpPhase` is a projection rather than a source of truth. So a
    /// surface reports itself. Deriving it centrally instead would mean
    /// re-implementing the pane logic in a second place, where it would
    /// silently fall out of step with the first — and "silently out of step"
    /// is precisely the class of bug a diagnostics trail exists to catch.
    ///
    /// Attach it to the surfaces worth naming in a report — the pane the hub
    /// is showing, the viewer window, an approval prompt — not to every row
    /// and card. A `view.shown` for something the user would not think of as a
    /// screen is noise in the one place noise is most expensive.
    ///
    /// SwiftUI may call `onAppear` again for a surface that never left (a
    /// re-parented view, a window regaining focus), so a repeat of the same
    /// surface is suppressed: a timeline that says the user opened Settings
    /// four times when they opened it once is worse than one that says nothing.
    func recordsDiagnosticSurface(_ name: String) -> some View {
        modifier(DiagnosticSurfaceModifier(name: name))
    }
}

private struct DiagnosticSurfaceModifier: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content
            .onAppear { DiagnosticSurfaceTracker.shared.shown(name) }
            .onDisappear { DiagnosticSurfaceTracker.shared.hidden(name) }
            // A surface whose NAME changes while the view stays mounted is the
            // normal case for a host that derives its pane from state — the
            // hub swaps between idle, starting, sharing and viewing without
            // ever unmounting the container. Without this the recorder would
            // report the first pane of the session and nothing after it.
            .onChange(of: name) { previous, current in
                DiagnosticSurfaceTracker.shared.hidden(previous)
                DiagnosticSurfaceTracker.shared.shown(current)
            }
    }
}

/// Suppresses repeat `view.shown` events for a surface that is already showing,
/// and a `view.hidden` for one that never was.
///
/// Not private: `AppState` reports the viewer's `NSWindow` through it too. That
/// window is AppKit, so the SwiftUI modifier cannot reach it, but it must go
/// through the same bookkeeping or its shown/hidden pairing would not hold
/// against the SwiftUI surfaces'.
///
/// `@MainActor` because SwiftUI's `onAppear`/`onDisappear` already run there,
/// so the isolation is free and buys a plain non-locking `Set`.
@MainActor
final class DiagnosticSurfaceTracker {
    static let shared = DiagnosticSurfaceTracker()

    /// How many live instances of each named surface there are.
    ///
    /// A count, not a set, because **the same surface can be on screen twice**.
    /// CLAUDE.md is explicit that while a share is live the whole sharing view
    /// — preview, controls, roster, approvals — renders on BOTH the main window
    /// and the menubar, out of the same components, so a sharer never has to
    /// hop between them. `PendingViewersList` is therefore mounted twice, and
    /// with a set the first one to disappear recorded `view.hidden` for a
    /// surface that was still right there in the other window.
    private var visible: [String: Int] = [:]

    func shown(_ name: String) {
        let count = (visible[name] ?? 0) + 1
        visible[name] = count
        // Only the 0→1 transition is the surface appearing.
        guard count == 1 else { return }
        AppDiagnostics.emitViewShown(name)
    }

    func hidden(_ name: String) {
        guard let count = visible[name] else { return }
        if count > 1 {
            visible[name] = count - 1
            return
        }
        visible.removeValue(forKey: name)
        AppDiagnostics.emitViewHidden(name)
    }
}
