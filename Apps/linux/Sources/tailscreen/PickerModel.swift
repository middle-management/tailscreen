import Foundation
import SwiftCrossUI
import TailscreenHubUI
import TailscreenL10n
import TailscreenViewerTsnet

// Targeted imports: importing all of TailscreenProtocol would collide with
// SwiftCrossUI's own `Published`/`ObservableObject` shims (Combine is absent
// on Linux).
import enum TailscreenProtocol.NodeBringUpPhase
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
    /// The shared bring-up vocabulary (also used by the WinUI and macOS hubs).
    /// `isDialing` below carries the part that's actually this model's own
    /// business (dialing a peer is `ViewerSessionPhase.connecting`, not a
    /// `Phase` case).
    typealias Phase = NodeBringUpPhase

    /// Starts signed-out. `main` moves it on at launch only for a profile
    /// whose state directory already holds a login to restore — the same
    /// silent-restore rule as the macOS hub's `attemptSessionRestore`.
    @Published var phase: Phase = .signedOut

    /// True from the moment a row is tapped until the session UI owns the
    /// window. Own flag rather than a `phase` case: it suppresses picker
    /// activity (a second dial, an ask, a refresh) during the beat before
    /// `ViewerUIState.inSession` publishes, which is not itself a bring-up
    /// state.
    @Published private(set) var isDialing = false

    /// Whether the bring-up in flight is an account switch rather than a
    /// fresh sign-in — not a `phase` case since `startingNode` is the same
    /// state either way, only the reason differs. Mirrors macOS's
    /// `isSwitchingProfile`.
    @Published var isSwitchingAccount = false

    @Published var sharers: [DiscoveredSharer] = []
    /// An interactive-login URL to show in-window (nil once logged in).
    @Published var loginURL: String?
    /// Why the welcome pane shows something other than first-run wording — a
    /// failed bring-up, or a saved sign-in needing the browser again. A
    /// projection of `phase` (not its own slot) so it can't outlive or
    /// disagree with the failure it describes.
    var signInNote: String? { phase.failureReason }
    /// Per-sharer live share status, keyed by `DiscoveredSharer.id`. Populated
    /// by a lazy metadata sweep; a missing entry means status-unknown, never
    /// "not sharing".
    @Published var shareInfo: [String: TailscreenMetadata] = [:]
    /// Round-trip time of the last successful probe. Absent means no probe
    /// completed yet — never "fast".
    @Published var latencyMs: [String: Int] = [:]

    /// The header filter menu's state. `sharers` stays the RAW discovery
    /// result (the tag menu enumerates it); `filteredSharers` is the
    /// projection the list renders.
    ///
    /// Persisted through the shared `PeerListFilterStore` (same as the macOS
    /// hub) — `UserDefaults` under `$XDG_CONFIG_HOME` on Linux, separate from
    /// the profile registry's JSON since a filter isn't an account.
    /// Best-effort: a write failure just makes the filter per-session.
    @Published private(set) var filter = PickerModel.loadFilter()

    /// `persist: false` is for `--ui-preview`, which seeds a filter to
    /// screenshot and has no business overwriting the filter of whoever's
    /// machine it is running on.
    func setFilter(_ new: PeerListFilter, persist: Bool = true) {
        guard new != filter else { return }
        filter = new
        if persist { PeerListFilterStore.save(new) }
    }

    /// First run seeds hide-offline ON (this filter replaced a hard-coded
    /// `filter { $0.isOnline }` at discovery; the portable `.default` would
    /// regress upgraders to seeing every machine they've ever owned). The
    /// key's presence distinguishes "never chose" from "chose off".
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
    /// Once settled, shows the tailnet rather than "Choose a screen to view"
    /// (matching macOS) — a list of machines already implies choosing one.
    var statusLine: String {
        switch phase {
        case .signedOut: return L("Not signed in")
        case .startingNode:
            if isSwitchingAccount { return L("Switching account…") }
            return loginURL == nil ? L("Starting Tailscale…") : L("Waiting for login…")
        case .discovering: return L("Looking for screens…")
        case .ready:
            return hubSignedInSubtitle(tailnet: tailnetName, account: accountIdentity)
        // Already localized at the bring-up site that knows what went wrong.
        case .failed(let reason): return reason
        }
    }

    func select(_ sharer: DiscoveredSharer) {
        guard phase.isReady, !isDialing else { return }
        isDialing = true
        onSelect?(sharer)
    }

    /// Leave the dialing gate — the two ways back to a usable list: a session
    /// that ended (`gReturnToPicker`) and a node coming up fresh (`bringUp`).
    func endDialing() {
        isDialing = false
    }

    /// Unlike `select`, does NOT set `isDialing`: the ask parks for up to two
    /// minutes, and locking the window for that would stop viewing a screen
    /// that came free while waiting.
    func askToShare(_ sharer: DiscoveredSharer) {
        guard phase.isReady, !isDialing, !asking.contains(sharer.id) else { return }
        onAskToShare?(sharer)
    }

    /// Header Refresh: re-run discovery, but only from the settled state
    /// (ignored mid-bring-up / mid-connect).
    func refresh() {
        guard phase.isReady, !isDialing else { return }
        onRefresh?()
    }
}
