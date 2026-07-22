import Foundation
import SwiftCrossUI
import TailscreenViewerTsnet

/// Drives the sharer-picker chrome: node bring-up → discovery → a native list
/// of sharers → connect. Only used when the app is launched WITHOUT a host
/// argument (the CLI host path skips straight to connecting). All of this is
/// live-only (a real tailnet with sharers), so it's compile-verified here; the
/// render self-test never enters picker mode.
@MainActor
final class PickerModel: ObservableObject {
    enum Phase: Equatable {
        case startingNode      // bringing the tsnet node up (maybe awaiting login)
        case discovering       // listing sharers
        case picking           // showing the list, waiting for a choice
        case connecting(String)  // dialing the chosen sharer (by hostname, for display)
    }

    @Published var phase: Phase = .startingNode
    @Published var sharers: [DiscoveredSharer] = []
    /// An interactive-login URL to show in-window (nil once logged in).
    @Published var loginURL: String?

    /// Set by `main` — invoked on the main actor when the user taps a row.
    var onSelect: ((DiscoveredSharer) -> Void)?

    /// A short human-readable line for the placard while the picker works.
    var statusLine: String {
        switch phase {
        case .startingNode: return loginURL == nil ? "Starting Tailscale…" : "Waiting for login…"
        case .discovering: return "Looking for screens…"
        case .picking: return sharers.isEmpty ? "No screens found" : "Choose a screen to view"
        case .connecting(let host): return "Connecting to \(host)…"
        }
    }

    func select(_ sharer: DiscoveredSharer) {
        guard case .picking = phase else { return }
        phase = .connecting(sharer.hostname)
        onSelect?(sharer)
    }
}
