import Foundation

/// The glue between a sharer's roster and what it remembers about people:
/// remember a decision, forget one, apply the ones made before the peer's
/// identity resolved, and keep the live server's policy map in step.
///
/// Shared because Linux and Windows both needed it and macOS had grown it
/// inline in `AppState` — untestable and silent when wrong. Lives in this
/// tier, not `TailscreenSharer`: nothing here imports the server, only reads
/// a store and hands back a policy map, so putting it beside the server
/// would drag libtailscale into `linux-protocol` for no reason.
///
/// Not observable and not `Sendable`, same reasoning as `AccountProfileStore`.
/// Mutators return whether anything changed, so a host's reactive wrapper
/// re-publishes only on a real change. The server is reached via closure
/// rather than reference, so every case below is testable with no tsnet
/// node, no network, no share.
public final class SharerAccessCoordinator {
    private let store: PeerAccessStore
    private var intents = ViewerRosterDecision.PendingIntents()

    /// Called whenever the effective policy map changes, with the whole map
    /// (matches the server's own `setAccessPolicies` API, which re-runs the
    /// admission gate over everyone parked rather than applying one row).
    public var onPoliciesChanged: (([String: PeerPolicy]) -> Void)?

    public init(store: PeerAccessStore) {
        self.store = store
    }

    /// Everything remembered, for pushing at a server that has just started.
    public var policies: [String: PeerPolicy] { store.policiesByStableID }

    /// What is remembered about the peer behind a roster row, if anything.
    /// Takes the resolved StableNodeID, not the row id — the row id is a
    /// connection (`"ip:port"`) while the memory is about a machine, and
    /// both are `String` so the parameter is named for what it must be.
    public func remembered(stableID: String?) -> PeerPolicy? {
        stableID.flatMap { store.policy(for: $0) }
    }

    /// Whether a decision for this row is queued behind identity resolution.
    public func isDeferred(rowID: String) -> Bool { intents.queued(id: rowID) != nil }

    /// Record "Always Allow" or "Deny & Block" for a roster row.
    ///
    /// - Returns: true when persisted immediately, false when queued because
    ///   the peer's StableNodeID hasn't resolved yet — both are success; the
    ///   caller uses the answer to word the row. Queuing exists because the
    ///   netmap lookup that produces the safe-to-remember key is async, so
    ///   "not yet identified" must not mean "dropped".
    @discardableResult
    public func remember(
        rowID: String, stableID: String?, displayName: String, policy: PeerPolicy
    ) -> Bool {
        guard let stableID else {
            intents.queue(id: rowID, policy: policy)
            return false
        }
        if store.upsert(stableID: stableID, displayName: displayName, policy: policy) {
            onPoliciesChanged?(store.policiesByStableID)
        }
        return true
    }

    /// Drop what is remembered about a peer, and cancel any queued decision
    /// for its row. Both halves needed: leaving an intent queued would
    /// silently re-apply the decision once identity resolved.
    @discardableResult
    public func forget(rowID: String, stableID: String?) -> Bool {
        intents.cancel(id: rowID)
        guard let stableID, store.remove(stableID: stableID) else { return false }
        onPoliciesChanged?(store.policiesByStableID)
        return true
    }

    /// Feed the coordinator a roster snapshot, called on every
    /// `onViewersChanged`/`onPendingViewersChanged` (also when identity
    /// finishes resolving). In order: persist queued decisions whose
    /// identity just resolved; refresh display names; drop queued decisions
    /// for rows that have gone (otherwise a Deny & Block could land on the
    /// next connection from that address — a different machine behind NAT).
    ///
    /// - Returns: true if anything was persisted, so a host can re-render.
    @discardableResult
    public func noteRoster(_ rows: [ViewerRosterDecision.RosterIdentity]) -> Bool {
        var changed = false
        for applied in intents.drain(snapshot: rows) {
            changed =
                store.upsert(
                    stableID: applied.stableID, displayName: applied.displayName,
                    policy: applied.policy) || changed
        }
        for row in rows {
            guard let stableID = row.stableID else { continue }
            changed =
                store.refreshDisplayName(stableID: stableID, displayName: row.displayName)
                || changed
        }
        intents.prune(presentIDs: Set(rows.map(\.id)))
        if changed { onPoliciesChanged?(store.policiesByStableID) }
        return changed
    }

    /// Forget every queued decision. Called when a share stops, since an
    /// intent outliving it would apply to whoever connects to the next one
    /// from the same address.
    public func reset() {
        intents = ViewerRosterDecision.PendingIntents()
    }
}
