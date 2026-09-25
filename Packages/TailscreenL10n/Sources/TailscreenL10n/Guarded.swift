import Foundation

/// A mutual-exclusion box: guarded state reachable only from inside
/// `withLock`, over an `NSLock`.
///
/// Deliberate copy of `TailscreenProtocol.Guarded` (never `Synchronization
/// .Mutex` — ThreadSanitizer can't see through it; see
/// `.claude/rules/portable-packages.md`). Copied rather than imported because
/// this package has no dependencies on purpose; keep the two in step.
final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// Run `body` with exclusive access to the guarded value. Non-reentrant;
    /// do not suspend inside — the lock is held across the whole call.
    func withLock<Result, E: Error>(
        _ body: (inout Value) throws(E) -> Result
    ) throws(E) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
