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
    }
}

/// Suppresses repeat `view.shown` events for a surface that is already showing.
///
/// `@MainActor` because SwiftUI's `onAppear`/`onDisappear` already run there,
/// so the isolation is free and buys the plain non-locking `Set`.
@MainActor
private final class DiagnosticSurfaceTracker {
    static let shared = DiagnosticSurfaceTracker()

    private var visible: Set<String> = []

    func shown(_ name: String) {
        guard visible.insert(name).inserted else { return }
        AppDiagnostics.viewShown(name)
    }

    func hidden(_ name: String) {
        guard visible.remove(name) != nil else { return }
        AppDiagnostics.viewHidden(name)
    }
}
