import Foundation
import TailscreenProtocol

/// The bookkeeping a share ENGINE needs around `TailscaleScreenShareServer`,
/// as a value type both hosts can hold under whatever guards them (the GTK
/// engine is `@MainActor`, the WinUI one lock-guarded, per
/// `.claude/rules/linux.md`) — a `struct` so neither isolation choice leaks
/// into the other.
///
/// Two concerns, each of which was written twice and fails silently when
/// wrong:
///
///   * **Which share attempt an inbound callback belongs to** (`beginShare` …
///     `isCurrentShare`), plus the grant-snapshot high-water mark on top —
///     why it needs two guards is on ``shouldApplyGrant``.
///   * **Invitations accepted before there was a server to tell**
///     (``noteInvite`` / ``drainInvites``): accepting necessarily happens
///     before the share exists, so the IP must be held and replayed or the
///     invitee is parked at their own approval gate.
public struct SharerSessionCore: Equatable, Sendable {

    // MARK: Share generation

    /// Which share attempt the engine is on. Callbacks and post-`start()`
    /// tails carry the generation they were created under and drop
    /// themselves when it no longer matches — without this, a stale server's
    /// snapshot could repopulate a roster for a share nobody is running (the
    /// Windows `start()` await spans tsnet bring-up, minutes on browser login).
    public private(set) var shareGeneration: UInt64 = 0

    /// Generation of the last control-grant snapshot applied. Resets at both
    /// ends of a share, since a fresh server starts its own
    /// `onControlGrantChanged` sequence at zero.
    public private(set) var lastGrantGeneration: UInt64 = 0

    /// IPs invited before there was a server to tell. See ``noteInvite``.
    public private(set) var heldInvites: Set<String> = []

    public init() {}

    /// Open a share attempt: everything stamped with an older one is ignored
    /// from here on, and the grant high-water mark restarts with it.
    ///
    /// - Returns: the generation to stamp this attempt's callbacks with.
    @discardableResult
    public mutating func beginShare() -> UInt64 {
        shareGeneration &+= 1
        lastGrantGeneration = 0
        return shareGeneration
    }

    /// Close the current share attempt — a stop, a capture death, or a start
    /// that failed. Anything still in flight from the server that just ended is
    /// dropped when it lands.
    ///
    /// Deliberately does NOT drop `heldInvites`: an ask accepted while the last
    /// share was winding down is an invitation to the share that is about to
    /// start, and forgetting it parks the invitee at the gate.
    public mutating func endShare() {
        shareGeneration &+= 1
        lastGrantGeneration = 0
    }

    /// Whether `generation` is still the live share attempt.
    public func isCurrentShare(_ generation: UInt64) -> Bool {
        generation == shareGeneration
    }

    /// Whether one control-grant snapshot should be applied, recording it when
    /// it should.
    ///
    /// **Both guards, not either.** `isStale` alone rejects only generations
    /// at or below the high-water mark, which `endShare` resets to zero — so
    /// a stale snapshot from the OLD server (e.g. generation 7) reads as not
    /// stale against 0, lands after the share ended, and then poisons the
    /// mark against the next share's own generation-1 snapshots. The share
    /// stamp rejects cross-share leaks; the high-water mark handles
    /// within-share reordering (a UI-thread hop can deliver an older
    /// snapshot last).
    ///
    /// Equal generations are NOT stale — two racing notifies can observe the
    /// same pair, and re-applying is idempotent.
    public mutating func shouldApplyGrant(share: UInt64, generation: UInt64) -> Bool {
        guard isCurrentShare(share) else { return false }
        guard
            !SharerNoticeDecision.isStale(
                generation: generation, lastApplied: lastGrantGeneration)
        else { return false }
        lastGrantGeneration = generation
        return true
    }

    /// Forget which grant snapshot was last applied, without ending the
    /// share — so the next server's generation-1 snapshot isn't discarded as
    /// stale against this one's.
    public mutating func clearGrantHistory() {
        lastGrantGeneration = 0
    }

    // MARK: Invitations

    /// Record that `ip` was invited past the approval gate. Held **iff there
    /// is no server yet** — an invite during a live share is delivered
    /// directly and finished, so holding it too would replay it into the
    /// NEXT share. The caller still tells a live server itself; this only
    /// decides what to remember.
    public mutating func noteInvite(_ ip: String, hasServer: Bool) {
        guard !hasServer else { return }
        heldInvites.insert(ip)
    }

    /// Take the held invitations, leaving none behind. Replay after the
    /// server exists and **before `start()`**, so an invitee's HELLO can't
    /// arrive before the gate knows about them.
    public mutating func drainInvites() -> Set<String> {
        let invited = heldInvites
        heldInvites.removeAll()
        return invited
    }
}
