import Foundation

/// Retry policy shared by the server's and the client's UDP receive loops
/// (also the client's TCP annotation back-channel reconnect).
///
/// A non-timeout receive error used to `break` both loops permanently,
/// leaving the share looking healthy while the viewer froze on its last
/// frame. Instead the loops retry with capped exponential backoff and give
/// up after `maxConsecutiveErrors` in a row, or, as a backstop for a
/// flapping socket whose errors interleave with timeouts, after
/// `maxErrorsPerWindow` inside the trailing `errorWindowNs`. Pure, CI-tested
/// by `ReceiveLoopPolicyTests`.
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

    /// `TailscaleError.readFailed` is thrown both for a benign poll timeout
    /// and for a dead socket (poll returns instantly with POLLHUP). errno
    /// never crosses the bridge, but wall time does: a genuine timeout only
    /// returns after its full poll interval, while a dead socket fails in
    /// microseconds. A `readFailed` observed faster than this classifies as
    /// an error, not a timeout.
    public static let readFailedErrorMaxElapsedNs: UInt64 = 200_000_000

    /// Classify a `readFailed` thrown `elapsedNs` after the recv call
    /// started: `true` means a genuine error (count it and back off),
    /// `false` a benign poll timeout (reset the consecutive run).
    public static func classifyReadFailedAsError(elapsedNs: UInt64) -> Bool {
        elapsedNs < readFailedErrorMaxElapsedNs
    }

    /// Delay before retry number `consecutiveErrors` (1-based): 250ms ·
    /// 2^(n−1), capped at 5s. Exponent clamped against shift overflow on
    /// absurd inputs.
    public static func retryDelayNs(consecutiveErrors: Int) -> UInt64 {
        let baseNs: UInt64 = 250_000_000
        let capNs: UInt64 = 5_000_000_000
        let exponent = min(max(consecutiveErrors - 1, 0), 5)
        return min(baseNs << exponent, capNs)
    }

    /// Pure sliding-window error accounting: prune stamps older than
    /// `windowNs`, record `nowNs`, return how many errors the window now
    /// holds. The caller gives up once the result reaches
    /// `maxErrorsPerWindow`.
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
