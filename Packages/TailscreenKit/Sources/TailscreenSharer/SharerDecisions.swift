// Admission / roster / lifecycle / helper-supervision decisions for
// `TailscaleScreenShareServer`: the admission gate, pending cap,
// expelled-addr quiet window, idle sweeps, helper crash budget. Pure
// `static func`s, no instance state. See `ViewerLifecycleDecisionTests`,
// `HelperRestartDecisionTests`.

import Foundation
import TailscreenProtocol

extension TailscaleScreenShareServer {
    /// Pending-cap gate: admitted when it refreshes an existing slot, or the
    /// set is below `cap`.
    public static func canAcceptPending(currentCount: Int, isExisting: Bool, cap: Int = maxPendingViewers) -> Bool {
        isExisting || currentCount < cap
    }

    /// Synthetic-addr derivation for a stream (reliable-transport, spec
    /// §2.2) viewer. Every per-viewer map keys on an addr string; a UDP
    /// viewer's is its real `ip:port`, but a stream viewer's TCP peer address
    /// carries no port (`tailscale_getremoteaddr` strips it), so two viewers
    /// on one machine would collide on bare IP. The synthetic
    /// connection-derived `tcp-…` suffix is deliberately non-numeric so it
    /// can never equal a real UDP `ip:port` key.
    ///
    /// Invariants (pinned by `StreamViewerDecisionTests`):
    /// `ipFromAddr(streamViewerAddr(ip, _)) == ip` for IPv4/bracketed IPv6,
    /// and distinct connections from one IP yield distinct addrs.
    public static func streamViewerAddr(peerIP: String?, connectionID: UUID) -> String {
        let suffix = "tcp-" + connectionID.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        guard let peerIP, !peerIP.isEmpty else { return suffix }
        // Re-bracket IPv6 so the addr round-trips through `ipFromAddr`'s
        // bracket-first rule; `peerIP` arrives bare (already reduced).
        let host = peerIP.contains(":") ? "[\(peerIP)]" : peerIP
        return "\(host):\(suffix)"
    }

    /// TS-STM-005: capabilities a stream viewer is allowed to hold. NACK/FEC
    /// recover lost datagrams, but the stream transport loses none — pure
    /// overhead there, so they're masked off. RR and tenBit pass through
    /// untouched (RTT/jitter/liveness and bit depth don't depend on transport).
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

    /// Classifies a helper's unexpected-exit reason string. -3805
    /// ("application connection being interrupted") on the helper's first
    /// SCStream startup is replayd refusing the slot; `permanent:` is the
    /// helper's own non-retryable marker.
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

    /// Sliding-window crash accounting: prune timestamps older than
    /// `windowNs`, record `nowNs`, return the crash count including this one.
    /// Caller gives up once the result exceeds `maxHelperCrashesPerWindow`.
    public static func slidingWindowCrashCount(
        _ stamps: inout [UInt64],
        appending nowNs: UInt64,
        windowNs: UInt64 = TransportTuning.helperCrashWindowNs
    ) -> Int {
        stamps.removeAll { nowNs &- $0 > windowNs }
        stamps.append(nowNs)
        return stamps.count
    }

    /// Inbound-audio relay decision. The sender must be a registered viewer
    /// AND its embedded SSRC must match the assigned one — else a registered
    /// viewer could spoof another's audio. On success, returns every other
    /// viewer as a relay recipient.
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

    /// Admission gate: remembered `deny` always rejects (even in open-door
    /// mode), remembered `allow` always admits, an unremembered peer parks
    /// when the approval gate is on. Precedence: blocklist > allowlist > gate.
    public static func admissionDecision(
        policy: PeerPolicy?, requireApproval: Bool, isGuest: Bool = false
    ) -> Admission {
        // A guest never auto-admits — not by remembered allow, open-door, or
        // pre-approval. Holding the token is capability to knock, never to
        // watch. A deny still rejects outright.
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

    /// Drain decision for `setRequireApproval(false)`: everyone parked gets
    /// admitted except remembered-deny peers. Peers with unresolved
    /// StableNodeID (`nil`) are admitted — `applyResolvedIdentity`'s
    /// post-resolution deny check still expels them if blocked. Sorted for
    /// determinism.
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

    /// Connected-roster deny sweep: which connected addresses now resolve to
    /// a remembered `deny`? Used by `setAccessPolicies` so "Deny & Block" on
    /// an already-connected peer expels it, not just future HELLOs.
    /// Unresolved StableNodeIDs are left alone. Sorted for determinism.
    public static func connectedDenyList(
        viewerStableIDs: [String: String?],
        policies: [String: PeerPolicy]
    ) -> [String] {
        viewerStableIDs.compactMap { (addr, stableID) -> String? in
            guard let stableID, policies[stableID] == .deny else { return nil }
            return addr
        }.sorted()
    }

    /// Kicked-viewer quiet-window decision: prune entries older than
    /// `quietNs`, report whether `addr` is still inside its window (its
    /// straggler KEEPALIVEs must be answered with denial, not re-run through
    /// the admission gate).
    public static func expelledQuietDecision(
        expelledAtNs: [String: UInt64], addr: String, nowNs: UInt64, quietNs: UInt64
    ) -> (remaining: [String: UInt64], isQuieted: Bool) {
        let remaining = expelledAtNs.filter { nowNs &- $0.value <= quietNs }
        return (remaining, remaining[addr] != nil)
    }

    /// Which addresses have been silent longer than `timeoutNs` as of
    /// `nowNs`? Shared by the connected-viewer and pending-viewer sweeps
    /// (differ only in timeout).
    public static func staleAddrs(
        lastSeenNs: [String: UInt64], nowNs: UInt64, timeoutNs: UInt64
    ) -> [String] {
        lastSeenNs.filter { nowNs &- $0.value > timeoutNs }.map(\.key)
    }

    /// A helper is wedged when it produced something before
    /// (`lastActivityNs != 0` — 0 means no helper yet) but nothing within
    /// `timeoutNs`.
    public static func helperLooksHung(
        lastActivityNs: UInt64, nowNs: UInt64, timeoutNs: UInt64
    ) -> Bool {
        lastActivityNs != 0 && nowNs &- lastActivityNs > timeoutNs
    }
}
