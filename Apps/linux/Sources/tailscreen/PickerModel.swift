import Foundation
import SwiftCrossUI
import TailscreenHubUI
import TailscreenL10n
import TailscreenViewerTsnet

// Targeted imports: bringing in all of TailscreenProtocol would collide with
// SwiftCrossUI's own `Published` / `ObservableObject` (both ship reactive shims
// on Linux, where Combine is absent). We only need a handful of value types.
import struct TailscreenProtocol.PeerListFilter
import enum TailscreenProtocol.PeerListFilterStore
import struct TailscreenProtocol.TailscreenMetadata

/// Drives the sharer-picker chrome: node bring-up → discovery → a native list
/// of sharers → connect. Only used when the app is launched WITHOUT a host
/// argument (the CLI host path skips straight to connecting). All of this is
/// live-only (a real tailnet with sharers), so it's compile-verified here; the
/// render self-test never enters picker mode.
@MainActor
final class PickerModel: ObservableObject {
    enum Phase: Equatable {
        case startingNode  // bringing the tsnet node up (maybe awaiting login)
        case discovering  // listing sharers
        case picking  // showing the list, waiting for a choice
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
    /// Round-trip time of the last successful probe, by `DiscoveredSharer.id`.
    ///
    /// Free: it times the metadata sweep that already runs, rather than adding
    /// a second dial. Absent means no probe has completed — never "fast".
    @Published var latencyMs: [String: Int] = [:]

    /// The header filter menu's state — hide-offline ∧ only-sharing ∧
    /// any-of-selected-tags. `sharers` stays the RAW discovery result (the tag
    /// menu enumerates it, and a filter that ate its own input could never be
    /// undone); `filteredSharers` is the projection the list renders, exactly
    /// as the macOS hub keeps `availablePeers` raw beside `filteredPeers`.
    ///
    /// Persisted through `PeerListFilterStore`, the same store the macOS hub
    /// uses — not a new persistence layer. On Linux that is
    /// swift-corelibs-foundation's `UserDefaults`, which writes a plist under
    /// `$XDG_CONFIG_HOME`; the profile registry's JSON file is deliberately
    /// left alone, since a filter is not an account. Best-effort by design: if
    /// the write fails the filter is simply per-session, which is a far better
    /// failure than refusing to filter.
    @Published private(set) var filter = PickerModel.loadFilter()

    /// `persist: false` is for `--ui-preview`, which seeds a filter to
    /// screenshot and has no business overwriting the filter of whoever's
    /// machine it is running on.
    func setFilter(_ new: PeerListFilter, persist: Bool = true) {
        guard new != filter else { return }
        filter = new
        if persist { PeerListFilterStore.save(new) }
    }

    /// First run seeds hide-offline ON.
    ///
    /// The picker has always listed online machines only — that was a hard-coded
    /// `filter { $0.isOnline }` at discovery, which this filter now owns. Taking
    /// the portable `.default` (hide-offline off) would have upgraders open the
    /// app to every machine they have ever owned and call it a regression. The
    /// key's presence is what distinguishes "never chose" from "chose off".
    private static func loadFilter() -> PeerListFilter {
        guard UserDefaults.standard.data(forKey: PeerListFilterStore.key) != nil else {
            return PeerListFilter(hideOffline: true, selectedTags: [], includeUntagged: true)
        }
        return PeerListFilterStore.load()
    }

    /// `sharers` narrowed by `filter` — what the Screens list renders.
    ///
    /// The projection itself is `PeerListFilter.narrow`, shared with the
    /// Windows hub and the macOS one, so the "no sweep answer ⇒ unknown, never
    /// not-sharing" rule is stated once rather than three times.
    var filteredSharers: [DiscoveredSharer] {
        filter.narrow(sharers, shareInfo: shareInfo)
    }

    /// The tags the filter menu offers: every tag across the RAW list, plus
    /// any currently selected — see `PeerListFilter.knownTags(in:)` for why
    /// the second half matters.
    var knownTags: [String] {
        filter.knownTags(in: sharers)
    }

    /// How many discovered machines the filter is currently hiding — the
    /// footnote under the list, so rows never vanish unexplained.
    var hiddenByFilter: Int { sharers.count - filteredSharers.count }

    /// Screens with an outstanding "please share" ask, by `DiscoveredSharer.id`.
    ///
    /// A set, not a flag: nothing stops somebody asking two machines, and a
    /// single-slot version would show the second ask's state on the first row.
    @Published private(set) var asking: Set<String> = []
    /// The last answer per screen, so the row can say what happened rather
    /// than silently reverting to a button — which is what an ask that was
    /// *declined* would otherwise look like.
    @Published private(set) var askOutcome: [String: String] = [:]

    func beginAsking(_ id: String) {
        asking.insert(id)
        askOutcome[id] = nil
    }

    func finishAsking(_ id: String, outcome: String?) {
        asking.remove(id)
        askOutcome[id] = outcome
    }

    /// Set by `main` — invoked on the main actor when the user taps a row.
    var onSelect: ((DiscoveredSharer) -> Void)?
    /// Set by `main` — asks the given machine to start sharing.
    var onAskToShare: ((DiscoveredSharer) -> Void)?
    /// Set by `main` — re-runs discovery when the header Refresh is tapped.
    var onRefresh: (@MainActor @Sendable () -> Void)?

    /// The tailnet this node joined, and the login it authenticated as — set by
    /// `main` once bring-up resolves them. Both optional: neither is required
    /// for the picker to work, and headscale commonly reports no tailnet name.
    var tailnetName: String?
    var accountIdentity: String?

    /// A short human-readable line for the placard while the picker works.
    ///
    /// Settled on the list, this shows the tailnet rather than "Choose a
    /// screen to view" — matching the macOS hub. The guidance was worth having
    /// when the header said nothing else, but a list of machines already
    /// implies choosing one, whereas *which tailnet those machines are on* is
    /// not deducible from anything else on screen.
    var statusLine: String {
        switch phase {
        case .startingNode:
            return loginURL == nil ? L("Starting Tailscale…") : L("Waiting for login…")
        case .discovering: return L("Looking for screens…")
        case .picking:
            return hubSignedInSubtitle(tailnet: tailnetName, account: accountIdentity)
        case .connecting(let host): return L("Connecting to \(host)…")
        }
    }

    func select(_ sharer: DiscoveredSharer) {
        guard case .picking = phase else { return }
        phase = .connecting(sharer.displayName)
        onSelect?(sharer)
    }

    /// Ask a machine to start sharing.
    ///
    /// Unlike `select`, this does NOT move the picker out of `.picking`: the
    /// ask parks for up to two minutes on the other person, and locking the
    /// window for that would be worse than useless — it would stop somebody
    /// viewing a screen that came free while they waited.
    func askToShare(_ sharer: DiscoveredSharer) {
        guard case .picking = phase, !asking.contains(sharer.id) else { return }
        onAskToShare?(sharer)
    }

    /// Header Refresh: re-run discovery, but only from the settled picking
    /// state (ignored mid-bring-up / mid-connect).
    func refresh() {
        guard case .picking = phase else { return }
        onRefresh?()
    }
}
