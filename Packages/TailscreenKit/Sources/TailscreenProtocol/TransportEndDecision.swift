import Foundation

/// The viewer transport's pure end-of-session decisions — the idle timeout
/// and the receive-error storm — extracted from `TsnetTransport` so they can
/// be unit-tested with no socket, no tailnet, and no clock.
///
/// Lives in this tier for a link-time reason: a test target depending on the
/// tsnet tier must LINK `libtailscale.a`, which `linux-protocol` deliberately
/// never builds. Everything these decisions consume already lives here, so
/// the extraction is free.
///
/// Both decisions exist because their absence was a frozen frame forever: a
/// sharer that crashed without a BYE left the portable viewer ticking against
/// a silent socket, and a dead socket's recv errors were swallowed by a bare
/// `continue`.
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

    /// Fold one failed receive into the tally and decide whether the socket
    /// is dead. Mirrors the macOS client's receive loop: a benign poll
    /// timeout resets the consecutive run (never the window — that backstop
    /// exists for a flapping socket interleaving errors with timeouts); a
    /// genuine error counts against both, and either threshold reached ends
    /// with `.connectionLost`.
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

    /// One run-loop pass's idle-timeout decision: nothing from the sharer
    /// past the threshold means it's gone (crashed, or its BYE was lost),
    /// ending the session with `.timedOut` instead of freezing forever.
    ///
    /// Suppressed while parked at the approval prompt: a sharer deliberating
    /// over Accept/Deny sends nothing, and timing that out would turn every
    /// slow approval into a phantom disconnect.
    public static func idleTimedOut(
        nowNs: UInt64, lastDatagramNs: UInt64, isPendingApproval: Bool,
        timeoutNs: UInt64 = TransportTuning.clientIdleDisconnectNs
    ) -> Bool {
        guard !isPendingApproval else { return false }
        return nowNs &- lastDatagramNs > timeoutNs
    }
}
