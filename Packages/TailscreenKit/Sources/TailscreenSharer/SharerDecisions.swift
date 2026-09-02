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

    /// Pure synthetic-addr derivation for a stream (reliable-transport,
    /// spec §2.2) viewer. The viewer roster, the send routing, and every
    /// per-viewer map key on an addr string; a UDP viewer's is its real
    /// `ip:port` source. A stream viewer has no UDP flow — its transport is
    /// a framed TCP connection whose peer address carries **no port**
    /// (`tailscale_getremoteaddr` strips it), so two viewers on one machine
    /// would collide on bare IP. The synthetic addr appends a
    /// connection-derived `tcp-…` suffix in the port position, chosen
    /// non-numeric ON PURPOSE: it can never equal a real UDP `ip:port` key,
    /// so the stream route lookup can be checked first without ever
    /// shadowing a UDP viewer.
    ///
    /// Two invariants, pinned by `StreamViewerDecisionTests`:
    /// `ipFromAddr(streamViewerAddr(ip, _)) == ip` for both IPv4 and
    /// bracketed IPv6 (the admitted-viewer gates anchor on that reduction),
    /// and distinct connections from one IP yield distinct addrs.
    public static func streamViewerAddr(peerIP: String?, connectionID: UUID) -> String {
        let suffix = "tcp-" + connectionID.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        guard let peerIP, !peerIP.isEmpty else { return suffix }
        // Re-bracket IPv6 so the addr round-trips through `ipFromAddr`'s
        // bracket-first rule; `peerIP` arrives bare (already reduced).
        let host = peerIP.contains(":") ? "[\(peerIP)]" : peerIP
        return "\(host):\(suffix)"
    }

    /// TS-STM-005: the capabilities a stream viewer is allowed to hold.
    /// NACK retransmission and FEC parity recover *lost* datagrams, and the
    /// stream transport loses none — on it they are pure overhead (and the
    /// retransmit budget is charged for nothing). The receiver-report and
    /// tenBit bits pass through untouched; RR still carries RTT/jitter and
    /// liveness, and bit depth has nothing to do with the transport.
    public static func streamHelloCaps(_ advertised: ScreenShareCaps) -> ScreenShareCaps {
        advertised.subtracting([.nack, .fec])
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
    public static func admissionDecision(
        policy: PeerPolicy?, requireApproval: Bool, isGuest: Bool = false
    ) -> Admission {
        // A guest (share-by-token viewer) never auto-admits: not by a
        // remembered allow, not by open-door mode, not by pre-approval
        // (the caller guards that path). Holding the token is capability
        // to KNOCK, never to watch — the sharer's explicit approval is the
        // only way in, every join. A deny still rejects outright.
        if isGuest {
            return policy == .deny ? .reject : .park
        }
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
        policies: [String: PeerPolicy],
        guestAddrs: Set<String> = []
    ) -> (approve: [String], deny: [String]) {
        var approve: [String] = []
        var deny: [String] = []
        for (addr, stableID) in pendingStableIDs {
            let policy = stableID.flatMap { policies[$0] }
            if policy == .deny {
                deny.append(addr)
            } else if guestAddrs.contains(addr) {
                // Turning the approval gate off opens the door to the
                // tailnet, not to token holders: parked guests stay
                // parked until the sharer answers their prompt.
                continue
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
