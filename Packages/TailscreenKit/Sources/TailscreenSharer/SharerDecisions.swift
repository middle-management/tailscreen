// Admission / roster / lifecycle / helper-supervision decisions for
// `TailscaleScreenShareServer`, moved verbatim out of
// TailscaleScreenShareServer.swift. Everything here is a pure
// `static func` on the server (plus the value types it consumes/returns):
// no instance state, no locks, no callbacks — the unit-testable decision
// layer behind the admission gate, the pending cap, the expelled-addr quiet
// window, the idle sweeps, and the helper crash budget.
// `ViewerLifecycleDecisionTests` and `HelperRestartDecisionTests` exercise
// it through the public API.

import Foundation
import TailscreenProtocol

extension TailscaleScreenShareServer {
    /// Pure pending-cap gate: a HELLO is admitted to the pending set when it
    /// refreshes an existing slot, or when the set is below `cap`. Extracted
    /// so the DoS bound is unit testable.
    public static func canAcceptPending(currentCount: Int, isExisting: Bool, cap: Int = maxPendingViewers) -> Bool {
        isExisting || currentCount < cap
    }

    /// What to do about a helper process that exited without being asked to.
    public enum HelperExitDisposition: Equatable {
        /// replayd refused the capture slot (another same-bundle process
        /// already holds one). Respawning hits the exact same wall — bail
        /// straight to teardown instead of burning the crash budget.
        case slotRefused
        /// The captured window / display / app no longer resolves — the user
        /// closed it (`writeFatal("source-gone: …")`). Non-retryable, but an
        /// *expected* stop the UI reports as a gentle notice, not an error.
        case sourceGone
        /// The helper tagged its own death as non-retryable (decode failure,
        /// startup-watchdog timeout, …) via `writeFatal("permanent: …")`.
        case permanent
        /// Anything else — worth respawning, subject to the crash budget.
        case retryable
    }

    /// Pure classification of a helper's unexpected-exit reason string.
    /// -3805 ("application connection being interrupted") on the helper's
    /// first SCStream startup is replayd refusing the slot; `permanent:` is
    /// the helper's own non-retryable marker. Extracted from
    /// `onUnexpectedExit` so the routing is unit testable.
    public static func classifyHelperExit(reason: String) -> HelperExitDisposition {
        if reason.contains("-3805") || reason.localizedCaseInsensitiveContains("being interrupted") {
            return .slotRefused
        }
        if reason.contains("source-gone:") {
            return .sourceGone
        }
        if reason.contains("permanent:") {
            return .permanent
        }
        return .retryable
    }

    /// Crash budget: give up after this many helper exits inside the sliding
    /// window (see `slidingWindowCrashCount`).
    public static let maxHelperCrashesPerWindow = TransportTuning.maxHelperCrashesPerWindow

    /// Pure sliding-window crash accounting: prune timestamps older than
    /// `windowNs`, record `nowNs`, and return how many crashes the window now
    /// holds (including this one). The caller gives up once the result
    /// exceeds `maxHelperCrashesPerWindow`. Extracted from `onUnexpectedExit`
    /// so the budget math is unit testable.
    public static func slidingWindowCrashCount(
        _ stamps: inout [UInt64],
        appending nowNs: UInt64,
        windowNs: UInt64 = TransportTuning.helperCrashWindowNs
    ) -> Int {
        stamps.removeAll { nowNs &- $0 > windowNs }
        stamps.append(nowNs)
        return stamps.count
    }

    /// Pure inbound-audio relay decision. The sender must be a registered
    /// viewer AND the embedded SSRC must match the one we assigned to that
    /// address — without the SSRC check, a registered viewer could spoof
    /// another viewer's audio by stuffing its SSRC into the RTP header. On
    /// success, returns every *other* viewer as a relay recipient. Extracted
    /// from `handleInboundAudioRTP` so the anti-spoof gate is unit testable.
    public static func audioRelayDecision(
        viewerAudioSSRCs: [String: UInt32],
        sender: String,
        headerSSRC: UInt32
    ) -> (valid: Bool, recipients: [String]) {
        guard let assigned = viewerAudioSSRCs[sender], assigned == headerSSRC else {
            return (false, [])
        }
        return (true, viewerAudioSSRCs.keys.filter { $0 != sender })
    }

    /// What to do with a not-yet-connected viewer's HELLO.
    public enum Admission: Equatable {
        /// Join the fan-out set immediately (remembered allow, or gate off).
        case admit
        /// Park in `pendingViewers` awaiting the sharer's Accept / Deny.
        case park
        /// Reject outright (remembered deny) — HELLO_DENY + SERVER_BYE.
        case reject
    }

    /// Pure admission gate: remembered `deny` always rejects (a blocked
    /// peer stays blocked even in open-door mode), remembered `allow`
    /// always admits, and an unremembered peer parks behind the approval
    /// gate when it's on. Extracted so the precedence
    /// (blocklist > allowlist > gate) is unit testable — same pattern as
    /// `audioRelayDecision`.
    public static func admissionDecision(policy: PeerPolicy?, requireApproval: Bool) -> Admission {
        switch policy {
        case .deny:
            return .reject
        case .allow:
            return .admit
        case nil:
            return requireApproval ? .park : .admit
        }
    }

    /// Pure drain decision for `setRequireApproval(false)`: everyone parked
    /// pending gets admitted *except* remembered-deny peers, who are denied
    /// instead. Peers whose StableNodeID never resolved (`nil`) can't match
    /// a policy and are admitted — the post-resolution deny check in
    /// `applyResolvedIdentity` still expels them if they turn out to be
    /// blocked. Results are sorted for determinism.
    public static func drainDecision(
        pendingStableIDs: [String: String?],
        policies: [String: PeerPolicy]
    ) -> (approve: [String], deny: [String]) {
        var approve: [String] = []
        var deny: [String] = []
        for (addr, stableID) in pendingStableIDs {
            let policy = stableID.flatMap { policies[$0] }
            if policy == .deny {
                deny.append(addr)
            } else {
                approve.append(addr)
            }
        }
        return (approve.sorted(), deny.sorted())
    }

    /// Pure connected-roster deny sweep: which currently-connected
    /// addresses now resolve to a remembered `deny`? Used by
    /// `setAccessPolicies` so a "Deny & Block" applied to an
    /// already-connected peer expels it instead of only blocking future
    /// HELLOs. Unresolved (`nil`) StableNodeIDs can't match a policy and
    /// are left alone. Sorted for determinism.
    public static func connectedDenyList(
        viewerStableIDs: [String: String?],
        policies: [String: PeerPolicy]
    ) -> [String] {
        viewerStableIDs.compactMap { (addr, stableID) -> String? in
            guard let stableID, policies[stableID] == .deny else { return nil }
            return addr
        }.sorted()
    }

    /// Pure kicked-viewer quiet-window decision: prune entries older than
    /// `quietNs` and report whether `addr` is still inside its window (its
    /// straggler KEEPALIVEs must be answered with denial, not re-run
    /// through the admission gate). Extracted from `registerOrRefresh` so
    /// the window math is unit testable.
    public static func expelledQuietDecision(
        expelledAtNs: [String: UInt64], addr: String, nowNs: UInt64, quietNs: UInt64
    ) -> (remaining: [String: UInt64], isQuieted: Bool) {
        let remaining = expelledAtNs.filter { nowNs &- $0.value <= quietNs }
        return (remaining, remaining[addr] != nil)
    }

    /// Pure staleness computation: which addresses have been silent longer
    /// than `timeoutNs` as of `nowNs`? Shared by the connected-viewer and
    /// pending-viewer sweeps (which differ only in their timeout). Extracted
    /// from `sweepIdleViewers` so the timeout math is unit testable.
    public static func staleAddrs(
        lastSeenNs: [String: UInt64], nowNs: UInt64, timeoutNs: UInt64
    ) -> [String] {
        lastSeenNs.filter { nowNs &- $0.value > timeoutNs }.map(\.key)
    }

    /// Pure hung-helper predicate: a helper is considered wedged when it has
    /// produced *something* before (`lastActivityNs != 0` — 0 means no helper
    /// yet) but nothing within `timeoutNs`. Extracted from the watchdog in
    /// `sweepIdleViewers` so the liveness math is unit testable.
    public static func helperLooksHung(
        lastActivityNs: UInt64, nowNs: UInt64, timeoutNs: UInt64
    ) -> Bool {
        lastActivityNs != 0 && nowNs &- lastActivityNs > timeoutNs
    }
}
