import Foundation

/// Retry policy shared by the server's and the client's UDP receive loops
/// (the client's TCP annotation back-channel reconnect reuses the same
/// backoff so the constants live in one place).
///
/// A non-timeout receive error used to `break` both loops permanently: the
/// server stopped reading HELLOs/KEEPALIVEs/PLIs/viewer audio while the share
/// still looked healthy, and the viewer froze on its last frame with a
/// live-looking UI. Instead of dying on the first error, the loops now retry
/// with this capped exponential backoff and only give up (through their
/// existing teardown paths) after `maxConsecutiveErrors` in a row — or, as a
/// backstop for a flapping socket whose errors interleave with timeouts and
/// so keep resetting the consecutive counter, after `maxErrorsPerWindow`
/// errors inside the trailing `errorWindowNs`. Pure and CI-tested by
/// `ReceiveLoopPolicyTests`.
public enum ReceiveLoopPolicy {
    /// Consecutive non-timeout errors before a receive loop gives up and
    /// tears its session down. Any successful receive (or an ordinary poll
    /// timeout) resets the run.
    public static let maxConsecutiveErrors = 10

    /// Windowed give-up backstop: even when the consecutive counter keeps
    /// resetting (error → timeout → error alternation), this many errors
    /// inside the trailing `errorWindowNs` still means the socket is too
    /// sick to keep polling.
    public static let maxErrorsPerWindow = 30

    /// Trailing window for `maxErrorsPerWindow`.
    public static let errorWindowNs: UInt64 = 60_000_000_000

    /// `TailscaleError.readFailed` is thrown both for the benign poll
    /// timeout and for dead-socket conditions (poll returns instantly with
    /// POLLHUP; the subsequent read fails). errno never crosses the bridge,
    /// but wall time does: a genuine timeout only returns after its full
    /// poll interval (1 s in both loops), while a dead socket fails in
    /// microseconds. A `readFailed` observed faster than this is classified
    /// as an error, not a timeout.
    public static let readFailedErrorMaxElapsedNs: UInt64 = 200_000_000

    /// Classify a `readFailed` thrown `elapsedNs` after the recv call
    /// started: `true` means a genuine error (count it and back off),
    /// `false` a benign poll timeout (reset the consecutive run).
    public static func classifyReadFailedAsError(elapsedNs: UInt64) -> Bool {
        elapsedNs < readFailedErrorMaxElapsedNs
    }

    /// Delay before retry number `consecutiveErrors` (1-based):
    /// 250 ms · 2^(n−1), capped at 5 s. The exponent is clamped so the
    /// shift can't overflow on absurd inputs; non-positive counts get the
    /// base delay.
    public static func retryDelayNs(consecutiveErrors: Int) -> UInt64 {
        let baseNs: UInt64 = 250_000_000
        let capNs: UInt64 = 5_000_000_000
        let exponent = min(max(consecutiveErrors - 1, 0), 5)
        return min(baseNs << exponent, capNs)
    }

    /// Pure sliding-window error accounting (same shape as
    /// `TailscaleScreenShareServer.slidingWindowCrashCount`): prune stamps
    /// older than `windowNs`, record `nowNs`, and return how many errors
    /// the window now holds (including this one). The caller gives up once
    /// the result reaches `maxErrorsPerWindow`.
    public static func slidingWindowErrorCount(
        _ stamps: inout [UInt64],
        appending nowNs: UInt64,
        windowNs: UInt64 = errorWindowNs
    ) -> Int {
        stamps.removeAll { nowNs &- $0 > windowNs }
        stamps.append(nowNs)
        return stamps.count
    }
}
