import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticsRecorder`: the buffer, the switch, and the redaction that runs
/// on the way in. The buffer's behavior under pressure matters because a
/// recorder that drops the wrong events produces a plausible file with a
/// silent loss — the prologue/ring split exists to keep the handshake.
final class DiagnosticsRecorderTests: XCTestCase {

    private func makeRecorder(
        enabled: Bool = true,
        prologue: Int = 4,
        ring: Int = 4
    ) -> DiagnosticsRecorder {
        DiagnosticsRecorder(
            defaultRole: .sharer,
            deviceLabel: "test-device",
            enabled: enabled,
            prologueCapacity: prologue,
            ringCapacity: ring)
    }

    // MARK: - The switch

    func testDisabledRecorderKeepsNothing() {
        let recorder = makeRecorder(enabled: false)
        recorder.record(.helloSent)
        XCTAssertTrue(recorder.events().isEmpty)
        XCTAssertFalse(recorder.isRecording)
    }

    /// A disabled recorder must not even build the fields — why `fields` is
    /// an `@autoclosure`, since these sit on per-frame paths most users run
    /// disabled.
    func testDisabledRecorderDoesNotEvaluateFields() {
        let recorder = makeRecorder(enabled: false)
        nonisolated(unsafe) var built = false
        recorder.record(
            .helloSent,
            fields: {
                built = true
                return ["k": 1]
            }())
        XCTAssertFalse(built, "fields were evaluated for a disabled recorder")
    }

    /// Turning recording off keeps what was already recorded — the switch is
    /// flipped after the thing went wrong.
    func testStoppingKeepsWhatWasAlreadyRecorded() {
        let recorder = makeRecorder()
        recorder.record(.helloSent)
        recorder.setRecording(false)
        recorder.record(.helloAckReceived)

        let events = recorder.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.name, DiagnosticEventName.helloSent.rawValue)
    }

    /// `clear` resets the numbering too — two bundles sharing a device and
    /// numbering but not a session would merge into nonsense.
    func testClearResetsSequenceNumbering() {
        let recorder = makeRecorder()
        recorder.record(.helloSent)
        recorder.record(.helloAckReceived)
        recorder.clear()

        XCTAssertTrue(recorder.events().isEmpty)
        XCTAssertNil(recorder.snapshot().startedAt, "a cleared recorder has no session start")
        XCTAssertEqual(recorder.snapshot().droppedCount, 0)

        recorder.record(.helloSent)
        let events = recorder.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.seq, 1, "numbering must restart with the session")
    }

    /// The elapsed clock restarts with `clear` too.
    func testClearResetsTheElapsedClock() {
        let recorder = makeRecorder()
        recorder.record(.helloSent, nowNs: 1_000_000_000)
        recorder.clear()
        recorder.record(.helloSent, nowNs: 9_000_000_000)

        XCTAssertEqual(recorder.events()[0].monotonicNs, 0)
    }

    // MARK: - The prologue / ring split

    /// The handshake survives an hour of traffic — a plain ring would have
    /// evicted the first events.
    func testPrologueSurvivesRingOverflow() {
        let recorder = makeRecorder(prologue: 3, ring: 3)
        recorder.record(.helloSent)
        recorder.record(.helloReceived)
        recorder.record(.helloAckSent)
        for _ in 0..<50 { recorder.record(.transportSummary) }

        let events = recorder.events()
        XCTAssertEqual(events.count, 6, "prologue (3) + ring (3)")
        XCTAssertEqual(
            events.prefix(3).map(\.name),
            [
                DiagnosticEventName.helloSent.rawValue,
                DiagnosticEventName.helloReceived.rawValue,
                DiagnosticEventName.helloAckSent.rawValue
            ],
            "the handshake must not be evicted by later traffic")
    }

    /// The ring keeps the newest events, not the oldest.
    func testRingKeepsTheNewestEvents() {
        let recorder = makeRecorder(prologue: 0, ring: 3)
        for _ in 0..<10 { recorder.record(.transportSummary) }

        let seqs = recorder.events().map(\.seq)
        XCTAssertEqual(seqs, [8, 9, 10])
    }

    /// Ring order stays chronological after wrapping — the classic
    /// circular-buffer bug produces a file that looks fine but reads out
    /// of order.
    func testRingReadsInOrderAcrossTheWrap() {
        let recorder = makeRecorder(prologue: 1, ring: 4)
        for _ in 0..<12 { recorder.record(.transportSummary) }

        let seqs = recorder.events().map(\.seq)
        XCTAssertEqual(seqs, [1, 9, 10, 11, 12])
        XCTAssertEqual(seqs, seqs.sorted(), "wrapped ring read out of order")
    }

    /// Drops are counted and reported, or a reader would read the prologue
    /// and ring as adjacent and infer a false causal link.
    func testDropsAreCountedNotSwallowed() {
        let recorder = makeRecorder(prologue: 2, ring: 2)
        for _ in 0..<10 { recorder.record(.transportSummary) }

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.events.count, 4)
        XCTAssertEqual(snapshot.droppedCount, 6)
    }

    /// Nothing is dropped while buffers are merely full-to-capacity — an
    /// off-by-one here would report loss that never happened.
    func testNoDropsReportedUntilTheRingActuallyWraps() {
        let recorder = makeRecorder(prologue: 2, ring: 2)
        for _ in 0..<4 { recorder.record(.transportSummary) }
        XCTAssertEqual(recorder.snapshot().droppedCount, 0)

        recorder.record(.transportSummary)
        XCTAssertEqual(recorder.snapshot().droppedCount, 1)
    }

    /// A no-op transition writes nothing: under `TAILSCREEN_DIAGNOSTICS=0`
    /// every toggle resolves back to `false` while already disabled, and
    /// without this guard each flip appends another `recording.stopped`.
    func testSameStateSetRecordingWritesNoMarker() {
        let recorder = makeRecorder(enabled: false)
        for _ in 0..<5 {
            recorder.setRecording(false, markerName: .recordingStopped)
        }
        XCTAssertTrue(recorder.events().isEmpty, "a forced-off run accumulated markers")
    }

    /// Same both ways: an already-recording recorder told to record does not
    /// re-open the session it's already in.
    func testSameStateSetRecordingOnWritesNoMarker() {
        let recorder = makeRecorder(enabled: true)
        recorder.setRecording(true, markerName: .recordingStarted)
        XCTAssertTrue(recorder.events().isEmpty)
    }

    /// A real transition still writes its marker.
    func testRealTransitionStillWritesItsMarker() {
        let recorder = makeRecorder(enabled: true)
        recorder.record(.helloSent)
        recorder.setRecording(false, markerName: .recordingStopped)

        XCTAssertEqual(
            recorder.events().map(\.name),
            [
                DiagnosticEventName.helloSent.rawValue,
                DiagnosticEventName.recordingStopped.rawValue
            ])
    }

    /// An off→on cycle during a record must not swallow the event into the
    /// NEW session. Fields are scrubbed outside the lock, so a writer can
    /// read the switch, be stopped/restarted mid-scrub, then take the lock
    /// and see `enabled == true` again for the wrong session.
    func testEventStraddlingAnOffOnCycleIsDropped() {
        let recorder = makeRecorder(prologue: 16, ring: 16)
        recorder.record(
            .transportSummary,
            fields: {
                recorder.setRecording(false, markerName: .recordingStopped)
                recorder.setRecording(true, markerName: .recordingStarted)
                return ["k": 1]
            }())

        XCTAssertEqual(
            recorder.events().map(\.name),
            [
                DiagnosticEventName.recordingStopped.rawValue,
                DiagnosticEventName.recordingStarted.rawValue
            ],
            "an event from the closed session landed in the new one")
    }

    func testAnUninterruptedRecordStillAppends() {
        let recorder = makeRecorder()
        recorder.record(.transportSummary, fields: ["k": 1])
        XCTAssertEqual(recorder.events().count, 1)
    }

    // MARK: - One prologue per session

    /// A second share's handshake must be protected as the first one's was —
    /// a single process-wide prologue would put every later session's HELLO
    /// in the evictable ring.
    func testSecondSessionsHandshakeSurvivesRingPressure() {
        let recorder = makeRecorder(prologue: 2, ring: 3)
        recorder.record(.helloReceived)
        recorder.record(.helloAckSent)
        for _ in 0..<20 { recorder.record(.transportSummary) }

        recorder.beginSession()
        recorder.record(.helloReceived)
        recorder.record(.helloAckSent)
        for _ in 0..<20 { recorder.record(.transportSummary) }

        let acks = recorder.events().filter {
            $0.name == DiagnosticEventName.helloAckSent.rawValue
        }
        XCTAssertEqual(acks.count, 2, "the second session's HELLO_ACK was evicted")
    }

    /// Order across containers is by sequence, not by container: session
    /// one's tail is in the ring, session two's opening events are in a
    /// later prologue, so naive concatenation would misorder them.
    func testEventsStayOrderedAcrossInterleavedProloguesAndRing() {
        let recorder = makeRecorder(prologue: 2, ring: 4)
        recorder.record(.helloSent)
        recorder.record(.helloAckReceived)
        for _ in 0..<3 { recorder.record(.transportSummary) }
        recorder.beginSession()
        recorder.record(.helloSent)
        recorder.record(.helloAckReceived)
        recorder.record(.transportSummary)

        XCTAssertEqual(recorder.events().map(\.seq), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(recorder.snapshot().droppedCount, 0)
    }

    /// Two `beginSession` calls with nothing between them are one session —
    /// a failed-then-retried share shouldn't stack an empty prologue.
    func testRepeatedBeginSessionDoesNotStackEmptyPrologues() {
        let recorder = makeRecorder(prologue: 2, ring: 4)
        recorder.record(.helloSent)
        recorder.beginSession()
        recorder.beginSession()
        recorder.beginSession()
        recorder.record(.helloAckReceived)

        XCTAssertEqual(recorder.events().map(\.seq), [1, 2])
        XCTAssertEqual(recorder.snapshot().droppedCount, 0)
    }

    /// Releasing the oldest session's prologue is an eviction like any
    /// other: it's counted, so a reader sees the hole.
    func testOldestSessionPrologueIsReleasedAndCounted() {
        let recorder = DiagnosticsRecorder(
            defaultRole: .sharer,
            deviceLabel: "test-device",
            enabled: true,
            prologueCapacity: 2,
            ringCapacity: 16,
            retainedSessionPrologues: 2)
        recorder.record(.helloSent)
        recorder.beginSession()
        recorder.record(.helloSent)
        recorder.beginSession()
        recorder.record(.helloSent)

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.events.map(\.seq), [2, 3], "session one's prologue should be gone")
        XCTAssertEqual(snapshot.droppedCount, 1)
    }

    /// `clear` collapses back to a single session — a reused recorder starts
    /// fresh instead of carrying empty segments against retention.
    func testClearCollapsesToOneSession() {
        let recorder = makeRecorder(prologue: 1, ring: 4)
        recorder.record(.helloSent)
        recorder.beginSession()
        recorder.record(.helloSent)
        recorder.clear()

        recorder.record(.helloSent)
        recorder.record(.transportSummary)
        XCTAssertEqual(recorder.events().map(\.seq), [1, 2])
        XCTAssertEqual(recorder.snapshot().droppedCount, 0)
    }

    /// Events carry the session they belong to; `beginSession` advances it,
    /// giving the merge something to scope a handshake pairing to.
    func testEventsCarryTheirSession() {
        let recorder = makeRecorder(prologue: 8, ring: 8)
        recorder.record(.helloSent)
        recorder.beginSession()
        recorder.record(.helloSent)
        recorder.beginSession()
        recorder.record(.helloSent)

        XCTAssertEqual(recorder.events().map(\.session), [0, 1, 2])
    }

    /// The ordinal survives the retention cap rather than renumbering down —
    /// a bundle starting at session 2 says two sessions were released.
    func testSessionOrdinalsSurviveTheRetentionCap() {
        let recorder = DiagnosticsRecorder(
            defaultRole: .sharer,
            deviceLabel: "test-device",
            enabled: true,
            prologueCapacity: 2,
            ringCapacity: 16,
            retainedSessionPrologues: 2)
        for _ in 0..<3 {
            recorder.record(.helloSent)
            recorder.beginSession()
        }
        recorder.record(.helloSent)

        // Sessions 0 and 1 were released; the rest keep numbers 2 and 3.
        XCTAssertEqual(recorder.events().map(\.session), [2, 3])
        XCTAssertEqual(recorder.snapshot().droppedCount, 2)
    }

    func testRepeatedBeginSessionDoesNotAdvanceTheOrdinal() {
        let recorder = makeRecorder()
        recorder.record(.helloSent)
        recorder.beginSession()
        recorder.beginSession()
        recorder.record(.helloSent)

        XCTAssertEqual(recorder.events().map(\.session), [0, 1])
    }

    // MARK: - Staging the export marker

    /// The marker is staged into the snapshot and never committed — a
    /// failed write must not leave `recording.exported` for the next
    /// successful export to claim.
    func testStagedMarkerIsNotCommittedToTheRecorder() {
        let recorder = makeRecorder()
        recorder.record(.helloSent)

        let staged = recorder.snapshotStaging(.recordingExported)
        XCTAssertEqual(
            staged.events.last?.name, DiagnosticEventName.recordingExported.rawValue)
        XCTAssertEqual(recorder.events().count, 1, "the marker must not reach the buffer")
    }

    /// The marker carries the elapsed time of the export, not of the
    /// preceding event — the merge renders every event at `anchor + elapsed`.
    func testStagedMarkerCarriesTheCurrentElapsedNotThePreviousEvents() {
        let recorder = makeRecorder()
        recorder.record(.helloSent, nowNs: 1_000_000_000)
        recorder.record(.transportSummary, nowNs: 2_000_000_000)

        let staged = recorder.snapshotStaging(.recordingExported, nowNs: 60_000_000_000)
        XCTAssertEqual(staged.events.last?.monotonicNs, 59_000_000_000)
    }

    /// Its sequence number continues the stream — the merge breaks ties on
    /// `seq`.
    func testStagedMarkerContinuesTheSequence() {
        let recorder = makeRecorder()
        recorder.record(.helloSent)
        recorder.record(.transportSummary)
        XCTAssertEqual(recorder.snapshotStaging(.recordingExported).events.last?.seq, 3)
    }

    // MARK: - Stamping

    /// The first event reads zero elapsed; the rest are relative to it,
    /// not to raw uptime.
    func testElapsedIsRelativeToTheFirstEvent() {
        let recorder = makeRecorder()
        recorder.record(.helloSent, nowNs: 5_000_000_000)
        recorder.record(.helloAckReceived, nowNs: 5_250_000_000)

        let events = recorder.events()
        XCTAssertEqual(events[0].monotonicNs, 0)
        XCTAssertEqual(events[1].monotonicNs, 250_000_000)
    }

    /// A backward clock step must not wrap into an enormous elapsed — `&-`
    /// on unsigned nanoseconds would turn 1ms backward into ~585 years.
    func testBackwardClockDoesNotWrapElapsed() {
        let recorder = makeRecorder()
        recorder.record(.helloSent, nowNs: 5_000_000_000)
        recorder.record(.helloAckReceived, nowNs: 4_999_000_000)

        XCTAssertEqual(recorder.events()[1].monotonicNs, 0)
    }

    func testCategoryAndSeverityComeFromTheRegistry() {
        let recorder = makeRecorder()
        recorder.record(.helloAckSent)
        recorder.record(.captureFailed)

        let events = recorder.events()
        XCTAssertEqual(events[0].category, .handshake)
        XCTAssertEqual(events[0].severity, .info)
        XCTAssertEqual(events[1].category, .media)
        XCTAssertEqual(events[1].severity, .error)
    }

    /// The override exists for events whose weight depends on outcome — a
    /// share phase moving to `failed` vs. `sharing`.
    func testSeverityOverrideWins() {
        let recorder = makeRecorder()
        recorder.record(.sharePhaseChanged, severity: .error)
        XCTAssertEqual(recorder.events()[0].severity, .error)
    }

    // MARK: - Redaction on the way in

    /// Secrets are removed at record time, not export time, or an
    /// unredacted recorder is one forgotten export path away from a leak.
    func testSecretsAreRedactedBeforeTheyReachTheBuffer() {
        let recorder = makeRecorder()
        recorder.record(
            .linkEnabled,
            fields: ["detail": .string("joined with tcAAAABBBBCCCCDDDD")])

        guard case .string(let stored)? = recorder.events()[0].fields["detail"] else {
            return XCTFail("field missing")
        }
        XCTAssertFalse(stored.contains("tcAAAABBBBCCCCDDDD"))
        XCTAssertTrue(stored.contains("tc:"), "expected a fingerprint, got \(stored)")
    }

    // MARK: - Concurrency

    /// Called from the capture thread, receive loops, UI thread, and sweep
    /// timers at once — catches an unguarded buffer under TSan, or a lost/
    /// duplicated sequence number otherwise.
    func testConcurrentRecordingKeepsSequenceNumbersUniqueAndDense() {
        let recorder = DiagnosticsRecorder(
            defaultRole: .sharer,
            deviceLabel: "test-device",
            enabled: true,
            prologueCapacity: 10_000,
            ringCapacity: 10_000)

        let threads = 8
        let perThread = 250
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<perThread { recorder.record(.transportSummary) }
        }

        let seqs = recorder.events().map(\.seq).sorted()
        XCTAssertEqual(seqs.count, threads * perThread)
        XCTAssertEqual(seqs, Array(1...UInt64(threads * perThread)))
    }
}
