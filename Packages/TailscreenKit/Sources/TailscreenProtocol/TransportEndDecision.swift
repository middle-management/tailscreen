import Foundation

/// The viewer transport's pure end-of-session decisions — the idle timeout
/// and the receive-error storm — extracted from `TsnetTransport` so they can
/// be unit-tested with no socket, no tailnet, and no clock.
///
/// They live in this tier rather than beside the transport for a link-time
/// reason, not a taste one: the tsnet tier needs only the patched libtailscale
/// *header* to compile, but a test target that depends on it must LINK
/// `libtailscale.a` — which the `linux-protocol` CI job (and `make
/// test-protocol`) deliberately never builds. Everything these decisions
/// consume (`ReceiveLoopPolicy`, `TransportTuning`) already lives here, so the
/// extraction costs nothing and the tests run wherever Swift does.
///
/// Both decisions exist because their absence was a frozen frame forever: a
/// sharer that crashed without a BYE left the portable viewer ticking against
/// a silent socket, and a dead socket's recv errors were swallowed by a bare
/// `continue` in the receive task.
public enum TransportEndDecision {
    /// The receive task's error bookkeeping — a consecutive run plus the
    /// sliding-window stamps behind `ReceiveLoopPolicy`'s two give-up
    /// thresholds. A value type so `receiveFailureIsFatal` stays a pure
    /// function a test can drive without a socket.
    public struct ReceiveFailureTally: Sendable {
        public var consecutiveErrors = 0
        public var errorStampsNs: [UInt64] = []

        public init() {}
    }

    /// Fold one failed receive into the tally and decide whether the socket is
    /// dead. Mirrors the macOS client's receive loop: a benign poll timeout
    /// resets the consecutive run (but never the window — the windowed
    /// backstop exists precisely for a flapping socket whose errors interleave
    /// with timeouts), a genuine error counts against both thresholds, and
    /// either threshold reached means give up and end with `.connectionLost`.
    public static func receiveFailureIsFatal(
        _ tally: inout ReceiveFailureTally, benignTimeout: Bool, nowNs: UInt64
    ) -> Bool {
        if benignTimeout {
            tally.consecutiveErrors = 0
            return false
        }
        tally.consecutiveErrors += 1
        let windowCount = ReceiveLoopPolicy.slidingWindowErrorCount(
            &tally.errorStampsNs, appending: nowNs)
        return tally.consecutiveErrors >= ReceiveLoopPolicy.maxConsecutiveErrors
            || windowCount >= ReceiveLoopPolicy.maxErrorsPerWindow
    }

    /// One run-loop pass's idle-timeout decision: nothing from the sharer for
    /// longer than the threshold means the sharer is gone (crashed, or its BYE
    /// was lost — UDP makes no promises), so the session ends with `.timedOut`
    /// instead of freezing on its last frame forever.
    ///
    /// Suppressed while parked at the approval prompt, mirroring the macOS
    /// client's guard: a sharer deliberating over Accept/Deny sends nothing,
    /// and timing the wait out would turn every slow approval into a phantom
    /// disconnect (the sharer side prunes stale pending viewers on its own,
    /// longer clock).
    public static func idleTimedOut(
        nowNs: UInt64, lastDatagramNs: UInt64, isPendingApproval: Bool,
        timeoutNs: UInt64 = TransportTuning.clientIdleDisconnectNs
    ) -> Bool {
        guard !isPendingApproval else { return false }
        return nowNs &- lastDatagramNs > timeoutNs
    }
}
