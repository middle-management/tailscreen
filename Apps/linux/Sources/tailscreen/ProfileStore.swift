import Foundation
import SwiftCrossUI

// Targeted imports: pulling all of TailscreenProtocol collides with
// SwiftCrossUI's own `Published` / `ObservableObject` shims, and this file
// declares a conformance to one of them.
import struct TailscreenProtocol.AccountProfile
import struct TailscreenProtocol.AccountProfileLayout
import class TailscreenProtocol.AccountProfileStore

/// One viewer account — a distinct Tailscale identity backed by its own tsnet
/// state directory. The type itself is portable now (the Windows app keeps the
/// same registry against `%LOCALAPPDATA%`); the alias keeps this app's own
/// vocabulary.
typealias ViewerProfile = AccountProfile

/// SwiftCrossUI-observable façade over the portable `AccountProfileStore`.
///
/// The registry — the JSON, the XDG root, the one-time adoption of the
/// pre-rename `tailscreen-viewer-gtk` directory — lives in TailscreenProtocol
/// and is unit-tested on Linux CI. What is left here is the one genuinely
/// per-UI-framework part: republishing on change, so the header's account menu
/// re-renders on switch/add/rename. It cannot live in the package, because the
/// `ObservableObject` this app observes is SwiftCrossUI's and the one that
/// module ships on Linux is its own.
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ViewerProfile]
    @Published private(set) var activeID: String

    private let store: AccountProfileStore

    /// The active profile (falls back to the first — `profiles` is never empty).
    var active: ViewerProfile { store.active }

    init() {
        store = AccountProfileStore(layout: .xdg())
        profiles = store.profiles
        activeID = store.activeID
    }

    /// Switch the active profile. No-op if already active or unknown.
    func setActive(_ id: String) {
        if store.setActive(id) { republish() }
    }

    /// Create a new profile (fresh state dir → interactive login on bring-up),
    /// make it active, and return it.
    @discardableResult
    func addProfile() -> ViewerProfile {
        let profile = store.addProfile()
        republish()
        return profile
    }

    /// Update a profile's display name (e.g. to the resolved tailnet/login once
    /// the node is up). Republishes only on a real change.
    func rename(_ id: String, to name: String) {
        if store.rename(id, to: name) { republish() }
    }

    private func republish() {
        profiles = store.profiles
        activeID = store.activeID
    }
}
