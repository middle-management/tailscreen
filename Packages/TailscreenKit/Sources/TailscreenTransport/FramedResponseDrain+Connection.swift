import Foundation
import TailscaleKit
import TailscreenProtocol

extension FramedResponseDrain {
    /// Drain an `OutgoingConnection` until the frame `match` wants arrives.
    ///
    /// The socket half of `FramedResponseDrain`: supplies the clock, poll,
    /// and the `readFailed` classification — tsnet reports "poll expired"
    /// and "socket dead" as the SAME error, distinguished only by elapsed
    /// time (`ReceiveLoopPolicy.classifyReadFailedAsError`). Getting that
    /// backwards either hot-spins against a dead connection or abandons a
    /// peer that just hasn't answered yet.
    ///
    /// - Parameters:
    ///   - pollMilliseconds: how long one `receive` waits, sized well above
    ///     the dead-socket threshold or every poll reads as dead.
    /// - Returns: the matched payload, or nil for every failure mode — nil is
    ///   status-unknown, never a positive answer.
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
