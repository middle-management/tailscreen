import Foundation
import TailscreenProtocol

/// The bookkeeping a share ENGINE needs around `TailscaleScreenShareServer`,
/// as a value type both hosts can hold under whatever guards them.
///
/// The GTK engine (`LinuxShareSession`) and the WinUI one
/// (`TailscreenSharerWGC.WindowsShareSession`) do the same job through
/// deliberately different isolation models — the first is `@MainActor`, the
/// second is lock-guarded, and `.claude/rules/linux.md` explains why that
/// difference is load-bearing rather than an accident. So what is shared here
/// is **not** the mutable session: it is the pure state machine those two
/// sessions each guard their own way. A `struct` rather than a class for
/// exactly that reason — the Linux engine keeps one as an actor-isolated
/// property and the Windows engine keeps one behind `NSLock`, and neither
/// choice leaks into the other.
///
/// Two concerns, both of which were written twice and both of which fail
/// silently when they are wrong:
///
///   * **Which share attempt an inbound callback belongs to** (`beginShare` …
///     `isCurrentShare`), plus the grant-snapshot high-water mark layered on
///     top of it. This is PR #244's fix, and the reason it needs two guards
///     rather than one is spelled out on ``shouldApplyGrant``.
///   * **Invitations accepted before there was a server to tell**
///     (``noteInvite`` / ``drainInvites``). Accepting somebody's ask to share
///     necessarily happens before the share exists — that is what accepting
///     means — so the IP has to be held and replayed, or the person this
///     machine just invited arrives at its own approval gate and is asked to
///     wait.
public struct SharerSessionCore: Equatable, Sendable {

    // MARK: Share generation

    /// Which share attempt the engine is on.
    ///
    /// Every callback the server makes, and both engines' post-`start()` tails,
    /// carry the generation they were created under and drop themselves when it
    /// no longer matches. Without that, a snapshot from a server the engine has
    /// let go of repopulates a roster for a share nobody is running — and on
    /// Windows the `start()` await spans tsnet bring-up, which on an interactive
    /// browser login is minutes.
    public private(set) var shareGeneration: UInt64 = 0

    /// The generation of the last control-grant snapshot applied.
    ///
    /// Resets at both ends of a share, because a fresh server starts its own
    /// `onControlGrantChanged` sequence at zero and a mark carried over would
    /// discard the next share's first snapshots as stale — a grant that
    /// silently never appears.
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
    /// **Both guards, not either.** `SharerNoticeDecision.isStale` only rejects
    /// a generation at or below the high-water mark, and ``endShare`` resets
    /// that mark to zero — it has to, since a fresh server counts from zero. So
    /// a snapshot still in flight from the OLD server (generation 7, say) is
    /// not stale against 0: it lands, telling the sharer somebody is driving a
    /// machine they just stopped sharing, and it leaves the mark at 7, which
    /// then swallows the next share's first snapshots. The share stamp is what
    /// rejects it; the high-water mark is what handles reordering *within* a
    /// share, where a host that hops the callback to its UI thread can deliver
    /// an older snapshot last and clear a grant that is still live.
    ///
    /// Equal generations are NOT stale: two racing notifies can observe the
    /// same pair, and re-applying it is idempotent.
    public mutating func shouldApplyGrant(share: UInt64, generation: UInt64) -> Bool {
        guard isCurrentShare(share) else { return false }
        guard
            !SharerNoticeDecision.isStale(
                generation: generation, lastApplied: lastGrantGeneration)
        else { return false }
        lastGrantGeneration = generation
        return true
    }

    /// Forget which grant snapshot was last applied, without ending the share.
    ///
    /// What a teardown's "clear the control rows" step needs: the rows go, and
    /// the next server's generation-1 snapshot must not be discarded as stale
    /// against this one's.
    public mutating func clearGrantHistory() {
        lastGrantGeneration = 0
    }

    // MARK: Invitations

    /// Record that `ip` was invited past the approval gate.
    ///
    /// Held **iff there is no server yet**. That condition is the whole rule:
    /// an invite made during a live share is delivered to that server directly
    /// and is finished, so holding it as well would replay it into the NEXT
    /// share — a free pass through the gate for a share nobody invited them to.
    /// The GTK engine held unconditionally and had exactly that leak.
    ///
    /// The caller still tells a live server itself; this only decides what to
    /// remember.
    public mutating func noteInvite(_ ip: String, hasServer: Bool) {
        guard !hasServer else { return }
        heldInvites.insert(ip)
    }

    /// Take the held invitations, leaving none behind.
    ///
    /// Replayed at the one moment that works: after the server exists and
    /// **before `start()`**, so an invitee's HELLO cannot arrive before the
    /// gate knows about them.
    public mutating func drainInvites() -> Set<String> {
        let invited = heldInvites
        heldInvites.removeAll()
        return invited
    }
}
