import Foundation
import TailscaleKit
import TailscreenProtocol

extension FramedResponseDrain {
    /// Drain an `OutgoingConnection` until the frame `match` wants arrives.
    ///
    /// The socket half of `FramedResponseDrain`: it supplies the clock, the
    /// poll, and — the part worth having in exactly one place — the
    /// classification of a `readFailed`. tsnet reports "the poll interval
    /// expired" and "this socket is dead" as the SAME error, and the only
    /// thing separating them is how long the call took
    /// (`ReceiveLoopPolicy.classifyReadFailedAsError`: near-instant ⇒ dead,
    /// a full interval ⇒ just the interval). Getting that backwards either
    /// hot-spins against a closed connection for the whole timeout or
    /// abandons a peer that simply had not answered yet.
    ///
    /// - Parameters:
    ///   - pollMilliseconds: how long one `receive` waits. Sized to the
    ///     overall timeout — a two-minute wait polled every second wakes 120
    ///     times to learn nothing — but always well above the dead-socket
    ///     threshold, or every poll would read as a dead socket.
    /// - Returns: the matched payload, or nil for every failure mode. See the
    ///   type's note: nil is status-unknown, never a positive answer.
    static func awaitResponse<Response>(
        on conn: OutgoingConnection,
        timeout: TimeInterval,
        pollMilliseconds: Int32,
        maximumLength: Int = 16 * 1024,
        match: (ScreenShareMessage) -> Response?
    ) async -> Response? {
        let now = { DispatchTime.now().uptimeNanoseconds }
        return await awaitResponse(
            deadlineNs: now() &+ UInt64(timeout * 1_000_000_000),
            now: now,
            read: {
                let startNs = now()
                do {
                    let chunk = try await conn.receive(
                        maximumLength: maximumLength, timeout: pollMilliseconds)
                    return chunk.isEmpty ? .eof : .bytes(chunk)
                } catch TailscaleError.readFailed {
                    return ReceiveLoopPolicy.classifyReadFailedAsError(
                        elapsedNs: now() &- startNs) ? .failed : .pollTimedOut
                } catch {
                    return .failed
                }
            },
            match: match)
    }
}
