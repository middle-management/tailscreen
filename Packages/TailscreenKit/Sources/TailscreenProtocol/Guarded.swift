import Foundation

/// A mutual-exclusion box with `Synchronization.Mutex`'s shape and `NSLock`'s
/// machinery: guarded state reachable only from inside `withLock`, but behind
/// a lock ThreadSanitizer actually understands.
///
/// **Never `Synchronization.Mutex`** — TSan learns happens-before from the
/// pthread primitives it interposes on; `Mutex` parks on a futex directly and
/// bypasses them, so `withLock { $0.field = … }` reads as an unsynchronised
/// access and TSan reports a race *inside the lock body* on correct code.
/// Worse, a `Mutex`-guarded type can't be checked by the sanitiser at all —
/// a green `linux-tsan` says nothing about it. Measured on both Swift 6.3 and
/// a 6.5 snapshot two majors ahead, so this isn't a toolchain bug about to
/// age out; see `.claude/rules/testing.md` for the reproduction.
///
/// A bare `NSLock` beside a `private var` is still correct but splits the
/// state from its lock across two declarations with nothing enforcing the
/// pairing; `Guarded` is the default for new state. It stays right where the
/// locking genuinely isn't one scoped body (`DiagnosticsRecorder` releases
/// early inside `record`; `DiagnosticsBundle` guards two separate statics).
///
/// Cost: one class allocation per property, `pthread_mutex` instead of a raw
/// futex per acquisition — negligible next to what it buys.
public final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    /// Run `body` with exclusive access to the guarded value.
    ///
    /// Non-reentrant: calling back into the same box from inside `body`
    /// deadlocks. Don't suspend in here either — the lock is held across the
    /// whole call.
    public func withLock<Result, E: Error>(
        _ body: (inout Value) throws(E) -> Result
    ) throws(E) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
