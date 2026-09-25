import Foundation

/// Read framed `ScreenShareMessage`s off a connection until one of them is the
/// answer that was asked for, the peer closes, or a deadline passes.
///
/// Shared loop for the one-shot TCP/7447 request/response clients
/// (`TailscreenMetadataClient`, `TailscreenRequestToShareClient`), which
/// otherwise each grow their own copy of the EOF/corrupt-parser/dead-socket
/// rules and drift apart.
///
/// **Every failure mode collapses to nil, meaning STATUS UNKNOWN** — EOF,
/// deadline, oversized frame, dead socket, legacy peer — the caller must not
/// render any of them as a positive fact ("not sharing", "declined").
///
/// Pure: takes an injected clock and read, so it's unit-testable with no
/// socket. The `OutgoingConnection` adapter lives in `TailscreenTransport`.
public enum FramedResponseDrain {
    /// What one read attempt produced.
    ///
    /// `pollTimedOut` vs `failed`: the transport tells them apart by ELAPSED
    /// TIME, not error kind — the same underlying failure means "keep
    /// waiting" after a full poll interval and "socket is dead" if it
    /// returned instantly (`ReceiveLoopPolicy.classifyReadFailedAsError`).
    public enum ReadOutcome: Sendable, Equatable {
        /// Bytes arrived — append and re-parse.
        case bytes(Data)
        /// The peer closed the connection without answering.
        case eof
        /// Nothing arrived within the poll interval; the deadline decides.
        case pollTimedOut
        /// The connection is unusable; stop.
        case failed
    }

    /// Drain until `match` claims a frame, the peer closes, the parser is
    /// poisoned, or `deadlineNs` passes.
    ///
    /// - Parameters:
    ///   - deadlineNs: absolute time on `now`'s clock after which the wait ends.
    ///   - now: the clock. Injected so tests can step it.
    ///   - read: one read attempt, already classified into `ReadOutcome`.
    ///   - match: the frame this caller is waiting for. Anything unrecognized
    ///     is ignored rather than fatal, for forward compatibility.
    /// - Returns: the matched payload, or nil for every failure mode.
    public static func awaitResponse<Response>(
        deadlineNs: UInt64,
        now: () -> UInt64,
        read: () async -> ReadOutcome,
        match: (ScreenShareMessage) -> Response?
    ) async -> Response? {
        var parser = ScreenShareMessageParser()
        while now() < deadlineNs {
            switch await read() {
            case .bytes(let chunk):
                parser.append(chunk)
                while let message = parser.next() {
                    if let response = match(message) { return response }
                }
                // An oversized/bogus length poisons the parser; it can't resync.
                if parser.isCorrupt { return nil }
            case .eof:
                return nil
            case .pollTimedOut:
                continue
            case .failed:
                return nil
            }
        }
        return nil
    }
}
