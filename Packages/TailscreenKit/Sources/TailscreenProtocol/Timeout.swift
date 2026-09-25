import Foundation

/// Shared timeout marker thrown by `withTimeout` (and peer-discovery's
/// continuation helpers).
public struct TimeoutError: Error {
    public init() {}
}

/// Run `operation` and return its result, but throw `TimeoutError` if it
/// hasn't completed within `seconds`.
///
/// Caveat: the losing task is cancelled, but cancellation doesn't
/// necessarily interrupt a blocking call that never checks
/// `Task.isCancelled` (notably tsnet's `node.up()`, which blocks down in
/// Go) — the operation keeps running in the background, but the *caller*
/// regains control instead of hanging forever.
public func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        guard let result = try await group.next() else {
            throw TimeoutError()
        }
        group.cancelAll()
        return result
    }
}
