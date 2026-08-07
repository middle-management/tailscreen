import Foundation

/// Read framed `ScreenShareMessage`s off a connection until one of them is the
/// answer that was asked for, the peer closes, or a deadline passes.
///
/// The shape both one-shot TCP/7447 request/response clients need — the
/// metadata query (`TailscreenMetadataClient`) and the ask-to-share
/// (`TailscreenRequestToShareClient`). They differ only in their poll interval
/// and in which frame they are waiting for, and they had each grown their own
/// copy of the loop, which meant two places for the EOF / corrupt-parser /
/// dead-socket rules to disagree.
///
/// **Every failure mode collapses to nil, and nil means STATUS UNKNOWN.** EOF,
/// deadline, an oversized frame, a dead socket, a legacy peer that drops the
/// request byte on the floor — the caller cannot tell them apart and must not
/// try: rendering any of them as a positive fact ("not sharing", "declined")
/// would be a claim the wire never made.
///
/// Pure on purpose: the loop takes an injected clock and an injected read, so
/// the ordering rules above are unit-testable with no socket. The
/// `OutgoingConnection` adapter that supplies both lives in
/// `TailscreenTransport`, written once rather than once per client.
public enum FramedResponseDrain {
    /// What one read attempt produced.
    ///
    /// `pollTimedOut` and `failed` are separate cases because the transport
    /// tells them apart by ELAPSED TIME, not by error kind: the same
    /// `readFailed` means "the poll interval expired, keep waiting" when it
    /// took the full interval and "this socket is dead" when it returned
    /// nearly instantly (`ReceiveLoopPolicy.classifyReadFailedAsError`).
    /// Collapsing them would either hot-spin against a closed connection or
    /// give up on the first quiet interval.
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
    ///   - match: the frame this caller is waiting for, or nil to keep
    ///     draining. Anything unrecognized is IGNORED rather than fatal, which
    ///     is what makes this forward compatible with frames added later.
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
                // A peer that framed an oversized (bogus) length poisons the
                // parser; the stream cannot resync, so the answer is never
                // coming.
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
