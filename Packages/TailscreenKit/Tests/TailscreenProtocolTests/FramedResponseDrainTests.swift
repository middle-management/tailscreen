import Foundation
import XCTest

@testable import TailscreenProtocol

/// `FramedResponseDrain` — the read-until-the-answer loop shared by the
/// metadata client and the request-to-share client: which outcomes end the
/// wait vs. keep it going, and that every failure mode yields nil. Clock and
/// read are injected, so this needs no socket and runs on Linux CI.
final class FramedResponseDrainTests: XCTestCase {
    /// A two-case value rather than `Bool?`: the drain already spends nil on
    /// "not the frame I'm waiting for", so a decline must not share that spelling.
    private enum Answer: Equatable {
        case accepted
        case declined
    }

    /// Scripted read outcomes plus a clock that advances one tick per read,
    /// so a deadline is reached deterministically rather than by sleeping.
    private final class Wire {
        var outcomes: [FramedResponseDrain.ReadOutcome]
        var nowNs: UInt64 = 0
        var tickNs: UInt64
        /// Asserts the loop stopped rather than spun.
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

    /// A frame this caller isn't waiting for is skipped, not fatal — lets new message types ship without breaking old peers.
    func testUnrelatedFramesAreIgnoredRatherThanFatal() async {
        let noise =
            ScreenShareMessage.controlRequest.encode()
            + ScreenShareMessage.controlReleased.encode()
        let wire = Wire([
            .bytes(noise),
            .bytes(ScreenShareMessage.metadataResponse(metadata(isSharing: false)).encode())
        ])
        let result = await drain(wire)
        XCTAssertEqual(result?.isSharing, false)
    }

    /// The parser accumulates across reads; resetting it per read would never answer an MTU-sized response.
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

    /// Separates `pollTimedOut` (keep waiting) from `failed`.
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

    /// A caller that dialed slowly must not get one free poll past its own timeout.
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

    /// An oversized declared length poisons the parser: the stream can never resync.
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

    /// `.shareResponse(false)` is a real answer, not a falsy "keep looking".
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
