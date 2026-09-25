import SwiftUI

extension View {
    /// Record that this surface is what the user is looking at. Self-reported
    /// because the app has no stored "current view" (see `.claude/rules/macos-app.md`
    /// on `MainWindowView`'s per-render pane derivation) — deriving it
    /// centrally would duplicate the pane logic and risk drifting from it.
    ///
    /// Attach to surfaces worth naming in a report (hub pane, viewer window,
    /// an approval prompt), not every row/card. Repeat `onAppear`s for the
    /// same surface (re-parented view, refocus) are suppressed.
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
            // The hub swaps panes without unmounting the container, so `name`
            // changes while the view stays mounted — a normal case, not a bug.
            .onChange(of: name) { previous, current in
                DiagnosticSurfaceTracker.shared.hidden(previous)
                DiagnosticSurfaceTracker.shared.shown(current)
            }
    }
}

/// Suppresses repeat `view.shown`/`view.hidden` events.
///
/// Not private: `AppState` reports the viewer's AppKit `NSWindow` through it
/// too, so its shown/hidden pairing holds against the SwiftUI surfaces'.
///
/// `@MainActor` because `onAppear`/`onDisappear` already run there, buying a
/// plain non-locking `Set`.
@MainActor
final class DiagnosticSurfaceTracker {
    static let shared = DiagnosticSurfaceTracker()

    /// A count, not a set: while a share is live the whole sharing view
    /// renders on both the main window and the menubar simultaneously, so
    /// `PendingViewersList` is mounted twice — a set would report `view.hidden`
    /// when only one of the two disappeared.
    private var visible: [String: Int] = [:]

    func shown(_ name: String) {
        let count = (visible[name] ?? 0) + 1
        visible[name] = count
        guard count == 1 else { return }  // only the 0->1 transition is new
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

    /// Re-emit `view.shown` for everything on screen, called when recording
    /// turns on — the table survives the toggle, so a surface that appeared
    /// while recording was off needs a synthetic `view.shown` or its later
    /// `view.hidden` is unmatched. Sorted for a stable baseline.
    func replayVisible() {
        for name in visible.keys.sorted() {
            AppDiagnostics.emitViewShown(name)
        }
    }

    /// Idempotent presence, for the viewer's `NSWindow`: `orderFrontRegardless`
    /// fires on every refocus while `orderOut` fires once, so counting would
    /// never come back to zero.
    func setVisible(_ name: String, _ isVisible: Bool) {
        if isVisible {
            guard visible[name] == nil else { return }
            visible[name] = 1
            AppDiagnostics.emitViewShown(name)
        } else {
            guard visible.removeValue(forKey: name) != nil else { return }
            AppDiagnostics.emitViewHidden(name)
        }
    }
}
