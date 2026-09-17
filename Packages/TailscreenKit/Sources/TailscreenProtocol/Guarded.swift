import Foundation

/// A mutual-exclusion box with `Synchronization.Mutex`'s shape and `NSLock`'s
/// machinery: guarded state reachable only from inside `withLock`, but behind
/// a lock ThreadSanitizer actually understands.
///
/// **This is the lock to reach for in any type touched by more than one
/// thread.** Not `Synchronization.Mutex`, for the reason below.
///
/// ### Why not `Synchronization.Mutex`
///
/// `Mutex` is the better primitive on paper — a futex on Linux, no class box
/// to allocate, `~Copyable` so it cannot be copied out from under its own
/// state. The problem is that TSan cannot see it. TSan learns happens-before
/// from the pthread primitives it interposes on (`pthread_mutex_lock` and
/// friends); `Mutex` bypasses those and parks on the futex directly, so the
/// sanitiser never observes the release/acquire pair. Every
/// `withLock { $0.field = … }` then reads to TSan as an unsynchronised
/// `inout` access to the guarded value, and it reports a "Swift access race"
/// *inside the lock body* — on correct code.
///
/// The noise is not the real cost. The real cost is that a type guarded by
/// `Mutex` cannot be checked by the sanitiser at all: it is not that such a
/// type fails the gate, it is that the gate has nothing to say about it, and
/// a green `linux-tsan` is silent about every race it might hold. That is
/// exactly backwards for the hot, genuinely multi-threaded types the gate
/// exists to protect — and it is a trap, because the first concurrency test
/// added to such a type fails on correct code and sends whoever wrote it off
/// investigating their own change.
///
/// Measured rather than assumed: a bare `Mutex<S>` hammered by
/// `DispatchQueue.concurrentPerform`, with no Tailscreen code involved,
/// reports the race on Swift 6.3 (the toolchain CI runs) and identically on a
/// Swift 6.5 development snapshot two majors ahead — so this is not a
/// toolchain bug about to age out, and waiting for one is not a plan. The
/// same hammer over `Guarded` is clean, and a genuine unsynchronised race
/// through the same shape is still caught. `.claude/rules/testing.md` carries
/// the reproduction.
///
/// ### Why not a bare `NSLock` beside a `private var`
///
/// That is the older pattern here and it is correct, but it splits the
/// guarded state from its lock across two declarations: nothing stops a later
/// edit from reading the `var` without taking the lock, and nothing in the
/// type says which lock covers which field. `Guarded` keeps the one real
/// safety property `Mutex` had — the value is reachable only through
/// `withLock` — which is also why moving a type across is a one-word change
/// at the declaration and no change at all at the call sites.
///
/// ### Cost
///
/// One class allocation per guarded property, and `pthread_mutex` rather than
/// a raw futex per acquisition (tens of nanoseconds, uncontended). On the RTP
/// path that is thousands of lock pairs a second against a link carrying
/// megabits — far below the noise floor, and the reason the trade goes this
/// way: a lock the sanitiser can verify is worth more than a marginally
/// faster one it cannot.
public final class Guarded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    /// Run `body` with exclusive access to the guarded value.
    ///
    /// Non-reentrant, exactly like `Mutex.withLock`: calling back into the
    /// same box from inside `body` deadlocks. Don't suspend in here either —
    /// the lock is held across the whole call, so an `await` inside it parks
    /// a thread that every other holder is waiting on.
    public func withLock<Result, E: Error>(
        _ body: (inout Value) throws(E) -> Result
    ) throws(E) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
