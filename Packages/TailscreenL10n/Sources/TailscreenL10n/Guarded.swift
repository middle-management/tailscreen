import Foundation

/// A mutual-exclusion box: guarded state reachable only from inside
/// `withLock`, over an `NSLock`.
///
/// This is a deliberate copy of `TailscreenProtocol.Guarded`, which carries
/// the full argument for why this repo's multi-threaded types use `NSLock`
/// rather than `Synchronization.Mutex` (short version: ThreadSanitizer models
/// the pthread primitives it interposes on and not `Mutex`'s futex, so every
/// `withLock` body reads to it as an unsynchronised access and a
/// `Mutex`-guarded type cannot be checked by the sanitiser at all). Copied
/// rather than imported because `TailscreenL10n` has **no** dependencies on
/// purpose — all three apps and `TailscreenHubUI` read it, and making the
/// string catalog depend on a tier full of RTP machinery to say "Sign in to
/// Tailscale" would be the wrong edge. Fifteen lines is the cheaper side of
/// that trade; keep the two in step if either changes.
///
/// `.claude/rules/portable-packages.md` states the repo-wide rule.
final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// Run `body` with exclusive access to the guarded value. Non-reentrant,
    /// and not a place to suspend — the lock is held across the whole call.
    func withLock<Result, E: Error>(
        _ body: (inout Value) throws(E) -> Result
    ) throws(E) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
