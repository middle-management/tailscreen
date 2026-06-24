import Foundation

/// Thrown by `withTimeout(seconds:operation:)` when `operation` doesn't finish
/// within the deadline.
struct TimeoutError: Error, CustomStringConvertible {
    let seconds: TimeInterval
    var description: String { "operation timed out after \(seconds)s" }
}

/// Run `operation` and return its result, but throw `TimeoutError` if it hasn't
/// completed within `seconds`.
///
/// Caveat: the losing task is cancelled, but cancellation does not necessarily
/// interrupt a blocking call that never checks `Task.isCancelled` — notably
/// tsnet's `node.up()`, which blocks down in Go. In that case the operation
/// keeps running in the background; the value of this wrapper is that the
/// *caller* regains control and can surface an error (or move on) instead of
/// hanging forever.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError(seconds: seconds)
        }
        guard let result = try await group.next() else {
            throw TimeoutError(seconds: seconds)
        }
        group.cancelAll()
        return result
    }
}
