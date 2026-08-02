import Foundation

/// The glue between a sharer's roster and what it remembers about people:
/// remember a decision, forget one, apply the ones that were made before the
/// peer's identity had resolved, and keep the live server's policy map in step.
///
/// It exists because Linux and Windows both needed exactly this and macOS had
/// grown it inline in `AppState` — five behaviours spread across a view model,
/// none of them testable, all of them silent when wrong. Putting it here makes
/// it one implementation that Linux CI runs, and leaves each host with nothing
/// to do but render rows and forward taps.
///
/// **It lives in this tier, not in `TailscreenSharer`**, and the closure below
/// is why. Nothing here imports the server: it reads a store and hands back a
/// policy map. Putting it beside the server would have dragged libtailscale
/// into `linux-protocol` — a leg that deliberately builds no Go archive — for
/// a type that never touches a node.
///
/// **Not observable and not `Sendable`**, the same two decisions
/// `AccountProfileStore` documents and for the same reasons: `ObservableObject`
/// means a different protocol on each host, and this owns an unlocked store, so
/// Swift 6's strict checking keeping it inside one `@MainActor` model is a
/// stronger guarantee than annotating it here. Mutators return whether anything
/// changed, so a host's reactive wrapper re-publishes only on a real change.
///
/// The server is reached through a closure rather than a reference. Not
/// squeamishness about retain cycles: it is what lets every case below be
/// tested with no tsnet node, no network and no share — which is the whole
/// difference between this logic being checked and being hoped about.
public final class SharerAccessCoordinator {
    private let store: PeerAccessStore
    private var intents = ViewerRosterDecision.PendingIntents()

    /// Called whenever the effective policy map changes, with the whole map.
    ///
    /// Whole map rather than a delta because that is the server's own API
    /// (`setAccessPolicies`), and because the server does more with it than
    /// apply one row: it re-runs the admission gate over everyone parked, and
    /// sweeps the connected roster for anyone newly denied. A delta would make
    /// this side responsible for knowing that.
    public var onPoliciesChanged: (([String: PeerPolicy]) -> Void)?

    public init(store: PeerAccessStore) {
        self.store = store
    }

    /// Everything remembered, for pushing at a server that has just started.
    public var policies: [String: PeerPolicy] { store.policiesByStableID }

    /// What is remembered about the peer behind a roster row, if anything.
    ///
    /// Takes the resolved StableNodeID rather than the row id, because the row
    /// id is a connection (`"ip:port"`) and the memory is about a machine.
    /// Passing the wrong one compiles — they are both `String` — which is why
    /// the parameter is named for what it must be.
    public func remembered(stableID: String?) -> PeerPolicy? {
        stableID.flatMap { store.policy(for: $0) }
    }

    /// Whether a decision for this row is queued behind identity resolution.
    public func isDeferred(rowID: String) -> Bool { intents.queued(id: rowID) != nil }

    /// Record "Always Allow" or "Deny & Block" for a roster row.
    ///
    /// - Returns: true when it was persisted immediately, false when it was
    ///   queued because the peer's StableNodeID has not resolved yet. Both are
    ///   success; the caller uses the answer to word the row.
    ///
    /// The queue is the interesting half. A sharer who wants somebody gone
    /// wants it *now*, and the netmap lookup that produces the only key safe to
    /// remember them under is asynchronous — so "not yet identified" must not
    /// mean "your decision was dropped".
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

    /// Drop what is remembered about a peer, and cancel any queued decision for
    /// its row.
    ///
    /// Both halves are needed: forgetting the stored policy while leaving an
    /// intent queued would silently re-apply the decision the moment the
    /// identity resolved, which is the opposite of what Forget means.
    @discardableResult
    public func forget(rowID: String, stableID: String?) -> Bool {
        intents.cancel(id: rowID)
        guard let stableID, store.remove(stableID: stableID) else { return false }
        onPoliciesChanged?(store.policiesByStableID)
        return true
    }

    /// Feed the coordinator a roster snapshot.
    ///
    /// Called on every `onViewersChanged` / `onPendingViewersChanged`, which is
    /// also when a hostname or StableNodeID finishes resolving — the event the
    /// queue is waiting for. Three things happen, in this order and for
    /// reasons:
    ///
    ///   1. queued decisions whose identity just resolved are persisted;
    ///   2. display names are refreshed, so a settings list shows machine names
    ///      rather than the IP a decision happened to be made against;
    ///   3. queued decisions for rows that have gone are dropped — otherwise a
    ///      Deny & Block on a peer that leaves before resolving would land on
    ///      *the next connection from that address*, which can be a different
    ///      machine behind one NAT.
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

    /// Forget every queued decision. Called when a share stops: the rows are
    /// gone, and an intent that outlived the share it was made during would
    /// apply to whoever connects to the *next* one from the same address.
    public func reset() {
        intents = ViewerRosterDecision.PendingIntents()
    }
}
