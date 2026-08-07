import Foundation
import XCTest

@testable import TailscreenProtocol

/// Unit tests for `FramedResponseDrain` — the read-until-the-answer loop the
/// metadata client and the request-to-share client share.
///
/// Every leg here is one of the ways the two hand-rolled copies could have
/// drifted: which outcomes end the wait, which one keeps it going, whether an
/// unrecognized frame is fatal, and — the important one — that no failure mode
/// produces anything but nil. The clock and the read are injected, so this
/// needs no socket and runs on Linux CI.
final class FramedResponseDrainTests: XCTestCase {
    /// What a matched `.shareResponse` means, as a two-case value rather than a
    /// `Bool?`. The drain already spends nil on "not the frame I am waiting
    /// for", so a decline must not share a spelling with it — which is exactly
    /// what `testDeclinedShareResponseIsAnAnswerNotAMiss` exists to catch.
    private enum Answer: Equatable {
        case accepted
        case declined
    }

    /// A scripted sequence of read outcomes plus a clock that advances one
    /// "tick" per read, so a deadline is reached deterministically rather than
    /// by sleeping.
    private final class Wire {
        var outcomes: [FramedResponseDrain.ReadOutcome]
        var nowNs: UInt64 = 0
        var tickNs: UInt64
        /// How many times `read` was actually called — the only way to assert
        /// that the loop stopped rather than spun.
        private(set) var reads = 0

        init(_ outcomes: [FramedResponseDrain.ReadOutcome], tickNs: UInt64 = 1_000_000_000) {
            self.outcomes = outcomes
            self.tickNs = tickNs
        }

        func read() -> FramedResponseDrain.ReadOutcome {
            reads += 1
            nowNs &+= tickNs
            guard !outcomes.isEmpty else { return .pollTimedOut }
            return outcomes.removeFirst()
        }
    }

    private func metadata(isSharing: Bool) -> TailscreenMetadata {
        TailscreenMetadata(
            shareName: "screen", hostname: "peer",
            screenResolution: .init(width: 1920, height: 1080),
            isSharing: isSharing, timestamp: Date(), videoCodec: .h264)
    }

    /// The drain both clients use: pull the metadata out of a
    /// `.metadataResponse`, ignore everything else.
    private func drain(
        _ wire: Wire, deadlineNs: UInt64 = 10_000_000_000
    ) async -> TailscreenMetadata? {
        await FramedResponseDrain.awaitResponse(
            deadlineNs: deadlineNs,
            now: { wire.nowNs },
            read: { wire.read() },
            match: { message in
                guard case .metadataResponse(let metadata) = message else { return nil }
                return metadata
            })
    }

    func testReturnsTheMatchedFrame() async {
        let wire = Wire([.bytes(ScreenShareMessage.metadataResponse(metadata(isSharing: true)).encode())])
        let result = await drain(wire)
        XCTAssertEqual(result?.isSharing, true)
        XCTAssertEqual(wire.reads, 1, "the answer must end the wait immediately")
    }

    /// A frame this caller is not waiting for is skipped, not fatal — the
    /// property that lets new message types ship without breaking old peers.
    func testUnrelatedFramesAreIgnoredRatherThanFatal() async {
        let noise = ScreenShareMessage.controlRequest.encode()
            + ScreenShareMessage.controlReleased.encode()
        let wire = Wire([
            .bytes(noise),
            .bytes(ScreenShareMessage.metadataResponse(metadata(isSharing: false)).encode())
        ])
        let result = await drain(wire)
        XCTAssertEqual(result?.isSharing, false)
    }

    /// A frame split across two reads still parses — the parser accumulates,
    /// and a copy of this loop that reset it per read would silently never
    /// answer against an MTU-sized response.
    func testFrameSplitAcrossReadsIsReassembled() async {
        let encoded = ScreenShareMessage.metadataResponse(metadata(isSharing: true)).encode()
        let cut = encoded.count / 2
        let wire = Wire([
            .bytes(encoded.prefix(cut)),
            .bytes(encoded.suffix(from: cut))
        ])
        let result = await drain(wire)
        XCTAssertEqual(result?.isSharing, true)
    }

    /// A quiet interval is not an answer: the loop keeps waiting until the
    /// deadline. This is the leg that separates `pollTimedOut` from `failed`.
    func testPollTimeoutKeepsWaiting() async {
        let wire = Wire([
            .pollTimedOut, .pollTimedOut,
            .bytes(ScreenShareMessage.metadataResponse(metadata(isSharing: true)).encode())
        ])
        let result = await drain(wire)
        XCTAssertEqual(result?.isSharing, true)
        XCTAssertEqual(wire.reads, 3)
    }

    func testDeadlineEndsTheWaitWithNil() async {
        // Three ticks of 1 s each fit inside a 3 s deadline; the fourth does not.
        let wire = Wire([.pollTimedOut, .pollTimedOut, .pollTimedOut, .pollTimedOut])
        let result = await drain(wire, deadlineNs: 3_000_000_000)
        XCTAssertNil(result)
        XCTAssertEqual(wire.reads, 3, "the loop must stop at the deadline, not spin")
    }

    /// A deadline already in the past reads nothing at all — a caller that
    /// dialed slowly must not get one free poll past its own timeout.
    func testExpiredDeadlineReadsNothing() async {
        let wire = Wire([.bytes(ScreenShareMessage.metadataResponse(metadata(isSharing: true)).encode())])
        let result = await drain(wire, deadlineNs: 0)
        XCTAssertNil(result)
        XCTAssertEqual(wire.reads, 0)
    }

    func testEOFEndsTheWaitWithNil() async {
        let wire = Wire([.eof, .bytes(ScreenShareMessage.metadataResponse(metadata(isSharing: true)).encode())])
        let result = await drain(wire)
        XCTAssertNil(result, "a peer that closed unanswered is unknown, never an answer")
        XCTAssertEqual(wire.reads, 1)
    }

    func testDeadSocketEndsTheWaitWithNil() async {
        let wire = Wire([.failed])
        let result = await drain(wire)
        XCTAssertNil(result)
        XCTAssertEqual(wire.reads, 1)
    }

    /// An oversized declared length poisons the parser — the stream can never
    /// resync, so continuing to read would burn the whole timeout on bytes
    /// that can no longer be framed.
    func testCorruptFrameEndsTheWaitWithNil() async {
        var poison = Data([ScreenShareMessage.MessageType.metadataResponse.rawValue])
        poison.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // 4 GiB payload length
        let wire = Wire([
            .bytes(poison),
            .bytes(ScreenShareMessage.metadataResponse(metadata(isSharing: true)).encode())
        ])
        let result = await drain(wire)
        XCTAssertNil(result)
        XCTAssertEqual(wire.reads, 1)
    }

    /// The request-to-share client's own match closure: a `.shareResponse`
    /// carrying `false` is a REAL answer, so the drain must return it rather
    /// than treating the falsy payload as "keep looking".
    func testDeclinedShareResponseIsAnAnswerNotAMiss() async {
        let wire = Wire([.bytes(ScreenShareMessage.shareResponse(accepted: false).encode())])
        let answer = await FramedResponseDrain.awaitResponse(
            deadlineNs: 10_000_000_000,
            now: { wire.nowNs },
            read: { wire.read() },
            match: { message -> Answer? in
                guard case .shareResponse(let accepted) = message else { return nil }
                return accepted ? .accepted : .declined
            })
        XCTAssertEqual(answer, .declined)
        XCTAssertEqual(wire.reads, 1)
    }
}
