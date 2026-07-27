import DefaultBackend
import Foundation
import SwiftCrossUI

// Targeted import: pulling all of TailscreenProtocol collides with
// SwiftCrossUI's own `Published` / `ObservableObject` shims, the same collision
// the GTK app hits and solves the same way.
import struct TailscreenProtocol.QualitySettings

// NOT named main.swift on purpose: Swift rejects `@main` in a file with that
// name, because main.swift is itself top-level code.

/// Stage W2 of the Windows port: prove the chrome builds and runs on WinUI
/// before wiring transport or video to it.
///
/// Deliberately not a stub that only prints. It renders a real window and a
/// real control, so "runs on a Windows machine" is something a human can look
/// at and judge. What it does not do yet is reach a tailnet or decode video —
/// those arrive once this is green on a runner and confirmed by eye.
///
/// Every view construct here is one the GTK app already uses at this same
/// pinned swift-cross-ui revision. That is a deliberate constraint: nothing in
/// this repo had ever been compiled for Windows, so the first build should fail
/// (if it fails) on the platform, not on a modifier that doesn't exist.
@main
struct TailscreenWindowsApp: App {
    @State var state = AppUIState()

    var body: some Scene {
        WindowGroup("Tailscreen") {
            VStack(spacing: 12) {
                Text("Tailscreen")
                    .font(.title2)

                Text(state.status)
                    .font(.caption)

                // A control rather than a label: it exercises the event loop,
                // the observable update and a repaint — three things a first UI
                // build can plausibly get wrong, and none of which a static
                // first paint would catch.
                Button(state.probeRan ? "Environment checked" : "Check environment") {
                    state.runProbe()
                }

                Text(state.details)
                    .font(.caption)
            }
            .padding(12)
        }
        .defaultSize(width: 460, height: 360)
    }
}

/// The window's observable state, kept out of the scene so the next stage can
/// replace `runProbe` with a real tsnet bring-up without reshaping the views.
final class AppUIState: ObservableObject {
    @Published var status = "Windows build — UI stage"
    @Published var details = ""
    @Published var probeRan = false

    /// Reports what the app can see of its own environment, and reaches into
    /// the portable protocol tier while doing so — which is the part worth
    /// proving. A window that renders but can't touch `TailscreenProtocol`
    /// would be a dead end.
    func runProbe() {
        let quality = QualitySettings.default
        details = """
            arch \(archDescription) · fps cap \(quality.fpsCap) · \
            codec \(quality.codecPreference)
            """
        status = "Portable protocol types are reachable from the UI"
        probeRan = true
    }

    private var archDescription: String {
        #if arch(x86_64)
            return "x86_64"
        #elseif arch(arm64)
            return "arm64"
        #else
            return "unknown"
        #endif
    }
}
