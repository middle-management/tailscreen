import XCTest

@testable import TailscreenProtocol
@testable import TailscreenViewer

/// What a viewer bundle says about the picture — the media events
/// `ViewerSession` records into its `recorder`, driven exactly as
/// `ViewerSessionTests` (real packetizers, an explicit clock, no socket).
///
/// Recorded in the session rather than per host so macOS/GTK/WinUI bundles
/// agree; this is the only place it's pinned. Two legs are about NOT
/// recording: `decode.failed` once per failing run (not per frame), and
/// `transport.summary` only once admitted and once per window.
final class ViewerSessionDiagnosticsTests: XCTestCase {

    // MARK: - Test doubles

    /// Frame size changeable between decodes (for `render.size.changed`);
    /// flippable to fail (for the decode events).
    private final class StubDecoder: VideoDecoding {
        var onDecodedFrame: ((any DecodedFrame) -> Void)?
        var onDecodeFailure: (() -> Void)?
        var shouldThrow = false
        var frameSize = (width: 4, height: 4)

        func decode(accessUnit: Data, codec: VideoCodec, isKeyframe: Bool) {
            if shouldThrow {
                onDecodeFailure?()
                return
            }
            let (w, h) = frameSize
            onDecodedFrame?(
                DecodedVideoFrame(
                    width: w, height: h,
                    yPlane: [UInt8](repeating: 0x10, count: w * h),
                    uPlane: [UInt8](repeating: 0x80, count: (w / 2) * (h / 2)),
                    vPlane: [UInt8](repeating: 0x80, count: (w / 2) * (h / 2))))
        }
    }

    private final class NullSink: VideoSink {
        func present(_ frame: any DecodedFrame) {}
    }

    private final class UncheckedSendableBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private struct Harness {
        let session: ViewerSession
        let decoder: StubDecoder
        let recorder: DiagnosticsRecorder

        func events(named name: DiagnosticEventName) -> [DiagnosticEvent] {
            recorder.events().filter { $0.name == name.rawValue }
        }
    }

    private func makeHarness(caps: ScreenShareCaps = [.nack, .receiverReport, .fec]) -> Harness {
        let decoder = StubDecoder()
        let recorder = DiagnosticsRecorder(defaultRole: .viewer, deviceLabel: "viewer", enabled: true)
        let session = ViewerSession(
            caps: caps, decoder: decoder, videoSink: NullSink(), audioSink: nil,
            onControlToSend: { _ in })
        session.recorder = recorder
        return Harness(session: session, decoder: decoder, recorder: recorder)
    }

    private func makeAVCC(byteCount: Int = 200) -> Data {
        var nal = Data([0x65])  // IDR slice, so the keyframe gate opens
        nal.append(contentsOf: (0..<(byteCount - 1)).map { UInt8($0 & 0xFF) })
        var avcc = Data()
        let len = UInt32(nal.count)
        avcc.append(UInt8((len >> 24) & 0xFF))
        avcc.append(UInt8((len >> 16) & 0xFF))
        avcc.append(UInt8((len >> 8) & 0xFF))
        avcc.append(UInt8(len & 0xFF))
        avcc.append(nal)
        return avcc
    }

    @discardableResult
    private func feedAUs(_ session: ViewerSession, count: Int, startSeq: UInt16 = 0) -> UInt16 {
        let packetizer = H264Packetizer()
        let nals = AVCCParser.nalUnits(from: makeAVCC())
        var seq = startSeq
        for _ in 0..<count {
            let packets = packetizer.packetize(
                nals: nals, timestamp: 9000 &+ UInt32(seq) &* 3000, ssrc: 7, startSequence: seq)
            for packet in packets { session.receiveRTP(packet) }
            seq &+= 1
        }
        return seq
    }

    private func admit(_ session: ViewerSession, ssrc: UInt32 = 5) {
        session.receiveRTP(
            ScreenShareControlMessage.encodeHelloAck(ssrc: ssrc, caps: [.nack, .receiverReport, .fec]))
    }

    private let second: UInt64 = 1_000_000_000

    // MARK: - First frame

    func testFirstFrameRecordedOnceWithTimeSinceAdmission() {
        let h = makeHarness()
        h.session.tick(nowNs: 2 * second)
        admit(h.session)
        h.session.tick(nowNs: 2 * second + 500_000_000)

        feedAUs(h.session, count: 3)

        let first = h.events(named: .decodeFirstFrame)
        XCTAssertEqual(first.count, 1, "once, not per frame")
        XCTAssertEqual(first.first?.role, .viewer)
        XCTAssertEqual(first.first?.category, .media)
        XCTAssertEqual(first.first?.fields["size"], .string("4x4"))
        XCTAssertEqual(first.first?.fields["codec"], .string("h264"))
        XCTAssertEqual(first.first?.fields["ms_since_ack"], .int(500))
        XCTAssertEqual(first.first?.fields["pre_keyframe_drops"], .int(0))
        XCTAssertEqual(first.first?.fields["keyframe_requests"], .int(1))
    }

    // MARK: - Size change

    func testRenderSizeChangeRecordedOnlyOnChange() {
        let h = makeHarness()
        admit(h.session)
        var seq = feedAUs(h.session, count: 2)
        XCTAssertEqual(h.events(named: .renderSizeChanged).count, 0, "same size: nothing")

        h.decoder.frameSize = (8, 6)
        seq = feedAUs(h.session, count: 2, startSeq: seq)
        let changes = h.events(named: .renderSizeChanged)
        XCTAssertEqual(changes.count, 1, "one change, however many frames follow at the new size")
        XCTAssertEqual(changes.first?.fields["from"], .string("4x4"))
        XCTAssertEqual(changes.first?.fields["to"], .string("8x6"))

        h.decoder.frameSize = (4, 4)
        feedAUs(h.session, count: 1, startSeq: seq)
        // Accounted for at the next receive-side call, never inside the
        // decoder callback (may run on another thread).
        XCTAssertEqual(h.events(named: .renderSizeChanged).count, 1, "not yet drained")
        _ = h.session.diagnostics
        XCTAssertEqual(h.events(named: .renderSizeChanged).count, 2, "and back is a second change")
    }

    // MARK: - Decode failures

    /// Once per failing run, not once per frame — a decoded frame closes
    /// the run so the next failure opens a new one.
    func testDecodeFailedRecordedOncePerEpisode() {
        let h = makeHarness()
        admit(h.session)
        h.decoder.shouldThrow = true
        var seq = feedAUs(h.session, count: 10)
        XCTAssertEqual(h.events(named: .decodeFailed).count, 1, "ten failures, one event")
        XCTAssertEqual(h.session.diagnostics.decodeFailures, 10, "…while every failure is still counted")
        XCTAssertEqual(h.events(named: .decodeFailed).first?.fields["failures_total"], .int(1))
        XCTAssertEqual(h.events(named: .decodeFailed).first?.fields["codec"], .string("h264"))

        h.decoder.shouldThrow = false
        seq = feedAUs(h.session, count: 1, startSeq: seq)
        h.decoder.shouldThrow = true
        feedAUs(h.session, count: 3, startSeq: seq)
        let failures = h.events(named: .decodeFailed)
        XCTAssertEqual(failures.count, 2, "a success in between opens a second episode")
        XCTAssertEqual(failures.last?.fields["failures_total"], .int(11))
        XCTAssertEqual(failures.last?.fields["frames_total"], .int(1))
    }

    /// Each rung is recorded once in order; the terminal rung also records
    /// `video.stalled` at `error` severity.
    func testLadderRungsAndStallAreRecorded() {
        let h = makeHarness()
        admit(h.session)
        h.session.onDecodeFatal = {}
        h.decoder.shouldThrow = true

        let seq = feedAUs(h.session, count: DecodeRecovery.surfaceErrorFailureThreshold)

        let rungs = h.events(named: .decodeRecoveryAction)
        XCTAssertEqual(
            rungs.map { $0.fields["action"] },
            [
                .string("request_keyframe"), .string("recreate_session"),
                .string("signal_degraded"), .string("surface_error")
            ])
        XCTAssertEqual(
            rungs.map { $0.fields["consecutive_failures"] },
            [
                .int(Int64(DecodeRecovery.requestKeyframeFailureThreshold)),
                .int(Int64(DecodeRecovery.recreateSessionFailureThreshold)),
                .int(Int64(DecodeRecovery.signalDegradedFailureThreshold)),
                .int(Int64(DecodeRecovery.surfaceErrorFailureThreshold))
            ])
        let stalls = h.events(named: .videoStalled)
        XCTAssertEqual(stalls.count, 1)
        XCTAssertEqual(stalls.first?.severity, .error)
        XCTAssertEqual(
            stalls.first?.fields["consecutive_failures"],
            .int(Int64(DecodeRecovery.surfaceErrorFailureThreshold)))

        // Latched: more failures add no rung and no second stall.
        feedAUs(h.session, count: 100, startSeq: seq)
        XCTAssertEqual(h.events(named: .decodeRecoveryAction).count, 4)
        XCTAssertEqual(h.events(named: .videoStalled).count, 1)
        XCTAssertEqual(h.events(named: .decodeFailed).count, 1, "still one episode")
    }

    func testFlatPathRecordsNoRungs() {
        let h = makeHarness()
        admit(h.session)
        h.decoder.shouldThrow = true
        feedAUs(h.session, count: 40)
        XCTAssertEqual(h.events(named: .decodeFailed).count, 1)
        XCTAssertEqual(h.events(named: .decodeRecoveryAction).count, 0)
        XCTAssertEqual(h.events(named: .videoStalled).count, 0)
    }

    // MARK: - Transport summary

    /// One row per window, carrying that window's deltas, not session totals.
    func testTransportSummaryOncePerWindowWithDeltas() {
        let h = makeHarness()
        h.session.tick(nowNs: 0)
        admit(h.session, ssrc: 5)
        h.session.tick(nowNs: 1 * second)  // opens the first window
        var seq = feedAUs(h.session, count: 4)
        h.session.tick(nowNs: 3 * second)
        XCTAssertEqual(h.events(named: .transportSummary).count, 0, "inside the window: nothing")

        h.session.tick(nowNs: 6 * second)  // 5 s after it opened
        var rows = h.events(named: .transportSummary)
        XCTAssertEqual(rows.count, 1)
        let first = rows[0]
        XCTAssertEqual(first.role, .viewer)
        XCTAssertEqual(first.category, .transport)
        XCTAssertEqual(first.fields["ssrc"], .int(5))
        XCTAssertEqual(first.fields["window_ms"], .int(5000))
        XCTAssertEqual(first.fields["frames"], .int(4))
        XCTAssertEqual(first.fields["frames_total"], .int(4))
        XCTAssertEqual(first.fields["aus"], .int(4))
        XCTAssertEqual(first.fields["codec"], .string("h264"))
        XCTAssertEqual(first.fields["keyframe"], .bool(true))
        XCTAssertEqual(first.fields["fec_active"], .bool(false))
        XCTAssertEqual(first.fields["decode_failures"], .int(0))
        XCTAssertEqual(first.fields["plis_sent"], .int(1), "the post-admission keyframe request")
        XCTAssertEqual(first.fields["nacks_sent"], .int(0))
        guard case .int(let packets)? = first.fields["video_packets"], packets > 0 else {
            return XCTFail(
                "the window's video packets should be counted: "
                    + "\(String(describing: first.fields["video_packets"]))")
        }

        seq = feedAUs(h.session, count: 2, startSeq: seq)
        h.session.tick(nowNs: 11 * second)
        rows = h.events(named: .transportSummary)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].fields["frames"], .int(2), "this window's frames, not the total")
        XCTAssertEqual(rows[1].fields["frames_total"], .int(6))
        XCTAssertEqual(rows[1].fields["aus"], .int(2))

        h.session.tick(nowNs: 16 * second)
        rows = h.events(named: .transportSummary)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[2].fields["frames"], .int(0))
        XCTAssertEqual(rows[2].fields["video_packets"], .int(0))
        XCTAssertEqual(rows[2].fields["frames_total"], .int(6))
    }

    /// The first window is measured from admission, not `start()`.
    func testNoSummaryBeforeAdmissionAndWindowStartsAtAdmission() {
        let h = makeHarness()
        h.session.start()
        for tickNs in stride(from: UInt64(0), through: 60 * second, by: Int(second)) {
            h.session.tick(nowNs: tickNs)
        }
        XCTAssertEqual(h.events(named: .transportSummary).count, 0, "not admitted: no rows")

        admit(h.session)
        h.session.tick(nowNs: 61 * second)  // sampler's first call: opens
        h.session.tick(nowNs: 65 * second)
        XCTAssertEqual(h.events(named: .transportSummary).count, 0, "four seconds after admission")
        h.session.tick(nowNs: 66 * second)
        XCTAssertEqual(h.events(named: .transportSummary).count, 1, "five seconds after admission")
    }

    func testSummaryCountsFeedbackTheSessionSent() {
        let h = makeHarness()
        h.session.tick(nowNs: 0)
        admit(h.session)
        h.session.tick(nowNs: 1 * second)
        // Skip a sequence number past the reorder tolerance so the scheduler NACKs.
        var seq = feedAUs(h.session, count: 2)
        seq &+= 3
        seq = feedAUs(h.session, count: 20, startSeq: seq)
        h.session.tick(nowNs: 2 * second)
        h.session.tick(nowNs: 6 * second)

        let rows = h.events(named: .transportSummary)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].fields["nacks_sent"], .int(Int64(h.session.diagnostics.nacksSent)))
        guard case .int(let nacks)? = rows[0].fields["nacks_sent"], nacks > 0 else {
            return XCTFail("the gap should have produced at least one NACK in the window")
        }
        XCTAssertEqual(rows[0].fields["skipped_gaps"], .int(Int64(h.session.diagnostics.skippedGaps)))
        XCTAssertEqual(rows[0].fields["loss_q8"], .int(Int64(h.session.diagnostics.lastReportedLossQ8)))
    }

    func testSummaryFieldsAreDeltasOfCountersAndCurrentGauges() {
        var previous = ViewerSession.Diagnostics()
        previous.videoPacketsReceived = 100
        previous.framesDecoded = 30
        previous.keyframeRequests = 1
        previous.nacksSent = 2
        previous.fecRecovered = 3
        previous.rttMs = 80
        var now = previous
        now.videoPacketsReceived = 160
        now.framesDecoded = 45
        now.keyframeRequests = 1
        now.nacksSent = 5
        now.fecRecovered = 7
        now.rttMs = 35
        now.lastReportedLossQ8 = 8
        now.codec = .hevc
        now.seenKeyframe = true
        now.fecActive = true

        let fields = now.transportSummaryFields(since: previous, windowNs: 5_000_000_000)
        XCTAssertEqual(fields["video_packets"], .int(60))
        XCTAssertEqual(fields["frames"], .int(15))
        XCTAssertEqual(fields["frames_total"], .int(45))
        XCTAssertEqual(fields["plis_sent"], .int(0))
        XCTAssertEqual(fields["nacks_sent"], .int(3))
        XCTAssertEqual(fields["fec_recovered"], .int(4))
        XCTAssertEqual(fields["rtt_ms"], .int(35), "a gauge: the current reading, not a delta")
        XCTAssertEqual(fields["loss_q8"], .int(8))
        XCTAssertEqual(fields["codec"], .string("hevc"))
        XCTAssertEqual(fields["keyframe"], .bool(true))
        XCTAssertEqual(fields["fec_active"], .bool(true))
        XCTAssertEqual(fields["window_ms"], .int(5000))
        for key in fields.keys {
            XCTAssertEqual(key, key.lowercased(), "\(key) is not lowercase")
            XCTAssertFalse(key.contains(" ") || key.contains("-"), "\(key) is not snake_case")
        }
    }

    /// With no recorder installed (stable-release default) the session
    /// behaves identically.
    func testNoRecorderRecordsNothingAndChangesNothing() {
        let h = makeHarness()
        h.session.recorder = nil
        h.session.tick(nowNs: 0)
        admit(h.session)
        h.session.tick(nowNs: 1 * second)
        h.decoder.frameSize = (8, 8)
        feedAUs(h.session, count: 3)
        h.session.tick(nowNs: 7 * second)
        XCTAssertEqual(h.recorder.events().count, 0)
        XCTAssertEqual(h.session.diagnostics.framesDecoded, 3)
    }

    // MARK: - Host-counted failures, and the frame side on another thread

    /// A host that runs the ladder itself (mac) counts per-frame failures
    /// through `noteHostDecodeFailure`: no PLI, no ladder rung, but the
    /// same counter and once-per-run `decode.failed`.
    func testHostDecodeFailuresAreCountedWithoutRunningTheLadder() {
        let h = makeHarness()
        h.session.tick(nowNs: 0)
        admit(h.session)
        feedAUs(h.session, count: 1)
        h.session.tick(nowNs: 1 * second)
        var plis = 0
        h.session.onPLISent = { plis += 1 }
        let plisBefore = plis

        for _ in 0..<7 { h.session.noteHostDecodeFailure() }
        h.session.tick(nowNs: 2 * second)  // drains
        XCTAssertEqual(h.session.diagnostics.decodeFailures, 7)
        XCTAssertEqual(h.events(named: .decodeFailed).count, 1, "seven failures, one run")
        XCTAssertEqual(h.events(named: .decodeRecoveryAction).count, 0, "the host owns the ladder")
        XCTAssertEqual(plis, plisBefore, "and the host owns the PLI")

        feedAUs(h.session, count: 1, startSeq: 1)
        h.session.noteHostDecodeFailure()
        h.session.tick(nowNs: 3 * second)
        XCTAssertEqual(h.events(named: .decodeFailed).count, 2)
        XCTAssertEqual(h.session.diagnostics.decodeFailures, 8)
        XCTAssertEqual(plis, plisBefore, "still no PLI from the session")

        h.session.tick(nowNs: 6 * second)
        let row = h.events(named: .transportSummary).last
        XCTAssertEqual(row?.fields["decode_failures"], .int(8), "host failures reach the row")
        XCTAssertEqual(row?.fields["frames"], .int(2))
    }

    /// Frames and host failures reported from another thread (the mac
    /// adapter's shape) must be counted exactly once, interleaving-independent.
    func testFrameSideOnAnotherThreadIsCountedExactlyOnce() {
        let h = makeHarness()
        h.session.tick(nowNs: 0)
        admit(h.session)
        feedAUs(h.session, count: 1)

        let frames = 2_000
        let failures = 500
        let session = h.session
        // The session is deliberately not Sendable (the host serializes it);
        // the box only tells the compiler what's already safe.
        let producerSide = UncheckedSendableBox((session: session, decoder: h.decoder))
        let producer = Thread {
            let (session, decoder) = producerSide.value
            for i in 0..<(frames + failures) {
                if i % 5 == 4 {
                    session.noteHostDecodeFailure()
                } else {
                    decoder.onDecodedFrame?(
                        DecodedVideoFrame(
                            width: 4, height: 4,
                            yPlane: [UInt8](repeating: 0x10, count: 16),
                            uPlane: [UInt8](repeating: 0x80, count: 4),
                            vPlane: [UInt8](repeating: 0x80, count: 4)))
                }
            }
        }
        producer.start()
        var tick: UInt64 = 1
        while !producer.isFinished {
            session.tick(nowNs: tick * 10_000_000)
            _ = session.diagnostics
            tick += 1
        }
        session.tick(nowNs: 100 * second)

        let snapshot = session.diagnostics
        XCTAssertEqual(snapshot.framesDecoded, frames + 1, "every frame counted once")
        XCTAssertEqual(snapshot.decodeFailures, failures, "every failure counted once")
        XCTAssertEqual(h.events(named: .decodeFirstFrame).count, 1)
        XCTAssertEqual(h.events(named: .renderSizeChanged).count, 0)
        let summaries = h.events(named: .transportSummary)
        let summedFrames = summaries.reduce(Int64(0)) { acc, row in
            if case .int(let n)? = row.fields["frames"] { return acc + n }
            return acc
        }
        XCTAssertEqual(summaries.last?.fields["frames_total"], .int(Int64(frames + 1)))
        XCTAssertEqual(summedFrames, Int64(frames + 1), "the windows partition the frames")
    }
}
