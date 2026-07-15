import Foundation

/// Retry policy shared by the server's and the client's UDP receive loops.
///
/// A non-timeout receive error used to `break` both loops permanently: the
/// server stopped reading HELLOs/KEEPALIVEs/PLIs/viewer audio while the share
/// still looked healthy, and the viewer froze on its last frame with a
/// live-looking UI. Instead of dying on the first error, the loops now retry
/// with this capped exponential backoff and only give up (through their
/// existing teardown paths) after `maxConsecutiveErrors` in a row. The
/// 250 ms → 5 s doubling matches the annotation back-channel's proven
/// reconnect backoff. Pure and CI-tested by `ReceiveLoopPolicyTests`.
enum ReceiveLoopPolicy {
    /// Consecutive non-timeout errors before a receive loop gives up and
    /// tears its session down. Any successful receive (or an ordinary poll
    /// timeout) resets the run.
    static let maxConsecutiveErrors = 10

    /// Delay before retry number `consecutiveErrors` (1-based):
    /// 250 ms · 2^(n−1), capped at 5 s. The exponent is clamped so the
    /// shift can't overflow on absurd inputs; non-positive counts get the
    /// base delay.
    static func retryDelayNs(consecutiveErrors: Int) -> UInt64 {
        let baseNs: UInt64 = 250_000_000
        let capNs: UInt64 = 5_000_000_000
        let exponent = min(max(consecutiveErrors - 1, 0), 5)
        return min(baseNs << exponent, capNs)
    }
}
