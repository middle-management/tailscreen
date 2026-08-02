import Foundation

/// The sharer's decisions about the people currently connected to — or asking
/// to connect to — their screen.
///
/// This is the layer the alignment plan calls the worst gap: Linux and Windows
/// could *admit* a viewer and then had no way to change their mind. The
/// decisions themselves were never the hard part — most of them already exist
/// on the server (`disconnectViewer`, `setAccessPolicies`) and in
/// ``PeerAccessStore``. What was missing is the small amount of logic *between*
/// the roster and the store, which macOS had grown inline in `AppState` and the
/// other two hosts had not grown at all.
///
/// So it lives here, tested, and each host renders it. Three things it decides:
///
///   * which actions a row can offer, given whether the peer's identity has
///     resolved yet;
///   * what happens to a decision made *before* it resolves;
///   * how a policy change maps onto the live roster.
public enum ViewerRosterDecision {
    /// What a roster row can offer right now.
    ///
    /// `remember` is conditional and that is the entire point: the persistent
    /// store is keyed by Tailscale StableNodeID — never by hostname or any
    /// other wire-supplied claim, since remembering "allow" against something a
    /// peer can choose is a trivially forgeable allow-list. The ID arrives from
    /// the sharer's *own* LocalAPI netmap lookup, which is asynchronous, so for
    /// the first moments of a connection there is nothing safe to key on.
    public struct Actions: Sendable, Equatable {
        /// One-time disconnect. Always available for a connected viewer: it is
        /// keyed by the connection's `"ip:port"`, which is known immediately,
        /// and nothing is remembered.
        public let canKick: Bool
        /// Accept / deny a viewer parked at the approval gate.
        public let canDecide: Bool
        /// "Always Allow" / "Deny & Block" — persist a decision about this
        /// *peer*, not this connection.
        public let canRemember: Bool
        /// Whether choosing to remember will take effect immediately or be
        /// queued until the identity resolves.
        ///
        /// The UI should say so. A button that silently does nothing for two
        /// seconds and then works is worse than one that says "will apply when
        /// this peer is identified" — and much worse than one that is simply
        /// absent, which is what a host without this flag would have to do.
        public let rememberIsDeferred: Bool

        public init(
            canKick: Bool, canDecide: Bool, canRemember: Bool, rememberIsDeferred: Bool
        ) {
            self.canKick = canKick
            self.canDecide = canDecide
            self.canRemember = canRemember
            self.rememberIsDeferred = rememberIsDeferred
        }
    }

    /// Actions for a row in the **connected** roster.
    ///
    /// Remembering is always offered, deferred when the identity has not
    /// resolved — rather than hidden. Hiding it would mean the affordance
    /// blinks into existence a moment after someone connects, which reads as a
    /// glitch and, worse, means a sharer who reaches for it in the first second
    /// of an unwanted connection finds nothing there.
    public static func connectedActions(stableID: String?) -> Actions {
        Actions(
            canKick: true, canDecide: false, canRemember: true,
            rememberIsDeferred: stableID == nil)
    }

    /// Actions for a row **parked at the approval gate**.
    ///
    /// No kick: there is nothing to disconnect yet. Accept and Deny are the
    /// one-time answers; Always Allow and Deny & Block are the same answers
    /// plus a memory.
    public static func pendingActions(stableID: String?) -> Actions {
        Actions(
            canKick: false, canDecide: true, canRemember: true,
            rememberIsDeferred: stableID == nil)
    }

    /// Queued "remember this peer" decisions, keyed by the roster row's
    /// `"ip:port"` id, waiting for that peer's StableNodeID to resolve.
    ///
    /// A value type with no clock and no storage: the host holds one, feeds it
    /// roster snapshots, and persists whatever comes back. The macOS app grew
    /// this inline as `queuedPolicyIntents` + `resolvableIntents`; this is the
    /// same decision, portable, so all three hosts behave identically and Linux
    /// CI checks it.
    public struct PendingIntents: Sendable, Equatable {
        private var intents: [String: PeerPolicy] = [:]

        public init() {}

        public var isEmpty: Bool { intents.isEmpty }
        public var count: Int { intents.count }

        /// Record a decision made before the peer's identity resolved.
        ///
        /// Last write wins: a sharer who clicks Deny & Block after Always Allow
        /// means the second one. Queueing both and applying them in arrival
        /// order would end with the first.
        public mutating func queue(id: String, policy: PeerPolicy) {
            intents[id] = policy
        }

        /// Drop a queued decision — the row went away, or the sharer changed
        /// their mind back.
        public mutating func cancel(id: String) {
            intents.removeValue(forKey: id)
        }

        /// The queued decision for a row, if any. Lets a host show the pending
        /// choice on the row rather than leaving the button looking unpressed.
        public func queued(id: String) -> PeerPolicy? { intents[id] }

        /// Given a roster snapshot, everything that can now be persisted —
        /// and remove it from the queue.
        ///
        /// Takes the WHOLE snapshot rather than one row, because that is what
        /// the host has: the server hands over the full roster whenever
        /// anything about it changes, including a hostname or StableNodeID
        /// resolving, which is exactly the event this is waiting for.
        ///
        /// - Returns: `(id, stableID, displayName, policy)` per applicable row.
        public mutating func drain(
            snapshot: [RosterIdentity]
        ) -> [(id: String, stableID: String, displayName: String, policy: PeerPolicy)] {
            guard !intents.isEmpty else { return [] }
            var applied: [(String, String, String, PeerPolicy)] = []
            for row in snapshot {
                guard let policy = intents[row.id], let stableID = row.stableID else { continue }
                applied.append((row.id, stableID, row.displayName, policy))
                intents.removeValue(forKey: row.id)
            }
            return applied.map {
                (id: $0.0, stableID: $0.1, displayName: $0.2, policy: $0.3)
            }
        }

        /// Forget queued decisions for rows that are no longer present.
        ///
        /// Without this a queue grows for the life of a share: a peer that
        /// connects, gets a Deny & Block the sharer then reconsiders, and
        /// leaves before its identity resolves would have that intent applied
        /// to *the next connection from the same address* — which may be a
        /// different machine behind the same NAT, or the same one the sharer
        /// has since decided to allow.
        public mutating func prune(presentIDs: Set<String>) {
            intents = intents.filter { presentIDs.contains($0.key) }
        }
    }

    /// The identity fields a roster row carries, for the queue above.
    ///
    /// A small struct rather than a tuple so the drain result is readable at
    /// the call site and so a host cannot silently pass hostname where
    /// stableID belongs — the two are both `String?` and only one of them is
    /// safe to key a policy on.
    public struct RosterIdentity: Sendable, Equatable {
        public let id: String
        public let stableID: String?
        public let displayName: String

        public init(id: String, stableID: String?, displayName: String) {
            self.id = id
            self.stableID = stableID
            self.displayName = displayName
        }
    }

    /// What a just-made policy decision means for the CONNECTED roster.
    ///
    /// "Deny & Block" on someone already watching has to expel them, not merely
    /// stop them coming back — a block that leaves the blocked person watching
    /// is not a block. The server's `connectedDenyList` already does this
    /// sweep; this is the host-side answer to the narrower question "did what I
    /// just clicked apply to anyone on screen right now", which is what decides
    /// whether the roster needs redrawing and whether to say so.
    public static func expelledByPolicy(
        policies: [String: PeerPolicy], connected: [RosterIdentity]
    ) -> [String] {
        connected.compactMap { row in
            guard let stableID = row.stableID, policies[stableID] == .deny else { return nil }
            return row.id
        }
    }
}
