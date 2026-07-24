import Foundation
import SwiftCrossUI
import TailscreenViewerTsnet

// Targeted import: bringing in all of TailscreenProtocol would collide with
// SwiftCrossUI's own `Published` / `ObservableObject` (both ship reactive shims
// on Linux, where Combine is absent). We only need the metadata value type.
import struct TailscreenProtocol.TailscreenMetadata

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
    /// Per-sharer live share status (name / resolution / `isSharing`), keyed by
    /// `DiscoveredSharer.id`. Populated by a lazy metadata sweep after discovery;
    /// a missing entry means status-unknown (never rendered as "not sharing").
    @Published var shareInfo: [String: TailscreenMetadata] = [:]

    /// Set by `main` — invoked on the main actor when the user taps a row.
    var onSelect: ((DiscoveredSharer) -> Void)?
    /// Set by `main` — re-runs discovery when the header Refresh is tapped.
    var onRefresh: (@MainActor @Sendable () -> Void)?

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

    /// Header Refresh: re-run discovery, but only from the settled picking
    /// state (ignored mid-bring-up / mid-connect).
    func refresh() {
        guard case .picking = phase else { return }
        onRefresh?()
    }
}
