import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticsRecorder` — the buffer, the switch, and the redaction that runs
/// on the way in.
///
/// The buffer's behaviour under pressure is the part worth pinning, because
/// every wrong answer is silent: a recorder that drops the wrong events still
/// produces a plausible file, and the loss is only discovered by the person
/// who needed the missing part. The prologue/ring split exists precisely to
/// keep the handshake, and nothing about a file full of events would reveal
/// that it had been thrown away.
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

    /// A disabled recorder keeps nothing. The whole opt-out promise.
    func testDisabledRecorderKeepsNothing() {
        let recorder = makeRecorder(enabled: false)
        recorder.record(.helloSent)
        XCTAssertTrue(recorder.events().isEmpty)
        XCTAssertFalse(recorder.isRecording)
    }

    /// A disabled recorder must not even *build* the fields. This is the whole
    /// reason `fields` is an `@autoclosure` — these call sites sit on
    /// per-frame paths, and a stable release has recording off by default, so
    /// the disabled path is the one almost every user runs.
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

    /// Turning recording off keeps what was already recorded. Someone flips
    /// the switch *after* the thing went wrong, and a switch that also erased
    /// the evidence would be a trap.
    func testStoppingKeepsWhatWasAlreadyRecorded() {
        let recorder = makeRecorder()
        recorder.record(.helloSent)
        recorder.setRecording(false)
        recorder.record(.helloAckReceived)

        let events = recorder.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.name, DiagnosticEventName.helloSent.rawValue)
    }

    /// `clear` is the explicit discard, and it resets the numbering with it —
    /// two bundles sharing a device and a numbering but not a session would
    /// merge into nonsense.
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

    /// The elapsed clock restarts with `clear` too. Otherwise the first event
    /// of the new session would carry the old session's elapsed time and read
    /// as though the app had been running for hours before it started.
    func testClearResetsTheElapsedClock() {
        let recorder = makeRecorder()
        recorder.record(.helloSent, nowNs: 1_000_000_000)
        recorder.clear()
        recorder.record(.helloSent, nowNs: 9_000_000_000)

        XCTAssertEqual(recorder.events()[0].monotonicNs, 0)
    }

    // MARK: - The prologue / ring split

    /// The point of the whole design: the handshake survives an hour of
    /// traffic. A plain ring would have evicted the first events, which are
    /// the ones that answer "what did the two sides agree on".
    func testPrologueSurvivesRingOverflow() {
        let recorder = makeRecorder(prologue: 3, ring: 3)
        // Three prologue events, then far more than the ring can hold.
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

    /// The ring keeps the NEWEST events, not the oldest — the symptom is at
    /// the end of the session.
    func testRingKeepsTheNewestEvents() {
        let recorder = makeRecorder(prologue: 0, ring: 3)
        for _ in 0..<10 { recorder.record(.transportSummary) }

        let seqs = recorder.events().map(\.seq)
        XCTAssertEqual(seqs, [8, 9, 10])
    }

    /// Ring order stays chronological after it has wrapped. Getting this wrong
    /// is the classic circular-buffer bug and it produces a file that looks
    /// completely fine while reading out of order.
    func testRingReadsInOrderAcrossTheWrap() {
        let recorder = makeRecorder(prologue: 1, ring: 4)
        for _ in 0..<12 { recorder.record(.transportSummary) }

        let seqs = recorder.events().map(\.seq)
        XCTAssertEqual(seqs, [1, 9, 10, 11, 12])
        XCTAssertEqual(seqs, seqs.sorted(), "wrapped ring read out of order")
    }

    /// Drops are counted and reported. A reader that cannot see the gap will
    /// read the prologue and the ring as adjacent and infer a causal link
    /// across however long is missing.
    func testDropsAreCountedNotSwallowed() {
        let recorder = makeRecorder(prologue: 2, ring: 2)
        for _ in 0..<10 { recorder.record(.transportSummary) }

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.events.count, 4)
        XCTAssertEqual(snapshot.droppedCount, 6)
    }

    /// Nothing is dropped while the buffers are merely full-to-capacity —
    /// an off-by-one here would report loss that never happened, which costs
    /// a reader's trust in every other number in the header.
    func testNoDropsReportedUntilTheRingActuallyWraps() {
        let recorder = makeRecorder(prologue: 2, ring: 2)
        for _ in 0..<4 { recorder.record(.transportSummary) }
        XCTAssertEqual(recorder.snapshot().droppedCount, 0)

        recorder.record(.transportSummary)
        XCTAssertEqual(recorder.snapshot().droppedCount, 1)
    }

    /// **A no-op transition writes nothing.** The marker describes a
    /// transition, and under `TAILSCREEN_DIAGNOSTICS=0` there is never one:
    /// every toggle resolves back to `false` and arrives here while already
    /// disabled, so each flip used to append another `recording.stopped` —
    /// and `export` then saw a non-empty recorder for a run that was forced to
    /// record nothing at all.
    func testSameStateSetRecordingWritesNoMarker() {
        let recorder = makeRecorder(enabled: false)
        for _ in 0..<5 {
            recorder.setRecording(false, markerName: .recordingStopped)
        }
        XCTAssertTrue(recorder.events().isEmpty, "a forced-off run accumulated markers")
    }

    /// The same both ways: an already-recording recorder told to record does
    /// not re-open the session it is already in.
    func testSameStateSetRecordingOnWritesNoMarker() {
        let recorder = makeRecorder(enabled: true)
        recorder.setRecording(true, markerName: .recordingStarted)
        XCTAssertTrue(recorder.events().isEmpty)
    }

    /// A REAL transition still writes its marker — the guard must not swallow
    /// the one event it exists to place correctly.
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

    /// **An off→on cycle during a record must not swallow the event into the
    /// NEW session.** Fields are scrubbed outside the lock on purpose, so a
    /// writer can read the switch, be stopped and restarted while it scrubs,
    /// then take the lock and see `enabled == true` again. Re-checking only the
    /// flag appended an event from the previous session after the
    /// `recording.started` that opened the next one, carrying a timestamp from
    /// before it — the recorder lying about its own lifetime.
    func testEventStraddlingAnOffOnCycleIsDropped() {
        let recorder = makeRecorder(prologue: 16, ring: 16)
        // The cycle happens while `fields` is being evaluated, which is exactly
        // where the real scrubbing happens.
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

    /// The ordinary case still records. A generation check that rejected
    /// everything would be invisible in the suite above and catastrophic in
    /// use, so it is worth stating separately.
    func testAnUninterruptedRecordStillAppends() {
        let recorder = makeRecorder()
        recorder.record(.transportSummary, fields: ["k": 1])
        XCTAssertEqual(recorder.events().count, 1)
    }

    // MARK: - One prologue per session

    /// The reason this stopped being "the first N events of the process": a
    /// SECOND share's handshake has to be protected exactly as the first
    /// one's was. With a single process-wide prologue, filling it once meant
    /// every later session's HELLO landed in the evictable ring — so using
    /// the app twice was enough to export a bundle missing the events
    /// ``DiagnosticsMerge`` pairs the two sides on.
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

    /// Order across the two containers is by sequence, not by container. Once
    /// a second prologue exists the prologues and the ring INTERLEAVE in time
    /// — session one's tail is in the ring, session two's opening events are
    /// in a prologue recorded after it — so concatenating them would print the
    /// second handshake before the first session's last events. That is the
    /// plausible-looking reordering this whole feature exists to avoid.
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

    /// Two `beginSession` calls with nothing in between are one session. Hosts
    /// call it from paths that can run back to back — a share that fails to
    /// start, then the retry — and stacking empty segments would evict a real
    /// prologue to make room for nothing.
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

    /// Retention is bounded, and releasing the oldest session's prologue is an
    /// eviction like any other: it is counted, so a reader still sees that the
    /// stream has a hole rather than reading two distant sessions as adjacent.
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

    /// `clear` collapses back to a single session, so a recorder reused after
    /// an explicit discard starts out like a fresh one instead of carrying
    /// empty segments that count against retention.
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

    // MARK: - Staging the export marker

    /// The marker is staged into the SNAPSHOT and never committed. A write
    /// that fails — a full disk, an undeletable directory — must not leave
    /// `recording.exported` behind for the next bundle that DOES succeed to
    /// claim as its own.
    func testStagedMarkerIsNotCommittedToTheRecorder() {
        let recorder = makeRecorder()
        recorder.record(.helloSent)

        let staged = recorder.snapshotStaging(.recordingExported)
        XCTAssertEqual(
            staged.events.last?.name, DiagnosticEventName.recordingExported.rawValue)
        XCTAssertEqual(recorder.events().count, 1, "the marker must not reach the buffer")
    }

    /// The marker carries the elapsed time of the EXPORT, not of the last
    /// event before it. The merge renders every event at `anchor + elapsed`,
    /// so a marker borrowing its predecessor's elapsed puts an export done
    /// minutes later back at that event's moment.
    func testStagedMarkerCarriesTheCurrentElapsedNotThePreviousEvents() {
        let recorder = makeRecorder()
        recorder.record(.helloSent, nowNs: 1_000_000_000)
        recorder.record(.transportSummary, nowNs: 2_000_000_000)

        let staged = recorder.snapshotStaging(.recordingExported, nowNs: 60_000_000_000)
        XCTAssertEqual(staged.events.last?.monotonicNs, 59_000_000_000)
    }

    /// Its sequence number continues the stream. The merge breaks ties on
    /// `seq`, so a marker repeating the previous number would sort arbitrarily
    /// against the event it must follow.
    func testStagedMarkerContinuesTheSequence() {
        let recorder = makeRecorder()
        recorder.record(.helloSent)
        recorder.record(.transportSummary)
        XCTAssertEqual(recorder.snapshotStaging(.recordingExported).events.last?.seq, 3)
    }

    // MARK: - Stamping

    /// The first event reads zero elapsed and the rest are relative to it.
    /// A reader's eye runs down that column; starting it at a raw uptime
    /// (some arbitrary number of hours since boot) makes it useless.
    func testElapsedIsRelativeToTheFirstEvent() {
        let recorder = makeRecorder()
        recorder.record(.helloSent, nowNs: 5_000_000_000)
        recorder.record(.helloAckReceived, nowNs: 5_250_000_000)

        let events = recorder.events()
        XCTAssertEqual(events[0].monotonicNs, 0)
        XCTAssertEqual(events[1].monotonicNs, 250_000_000)
    }

    /// A clock that appears to step backwards must not wrap into an enormous
    /// elapsed. `&-` on unsigned nanoseconds would turn a 1 ms backward step
    /// into roughly 585 years.
    func testBackwardClockDoesNotWrapElapsed() {
        let recorder = makeRecorder()
        recorder.record(.helloSent, nowNs: 5_000_000_000)
        recorder.record(.helloAckReceived, nowNs: 4_999_000_000)

        XCTAssertEqual(recorder.events()[1].monotonicNs, 0)
    }

    /// Category and severity come from the registry, so two call sites cannot
    /// disagree about what an event is.
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

    /// The override exists for events whose weight depends on the outcome —
    /// a share phase moving to `failed` against the same event moving to
    /// `sharing`.
    func testSeverityOverrideWins() {
        let recorder = makeRecorder()
        recorder.record(.sharePhaseChanged, severity: .error)
        XCTAssertEqual(recorder.events()[0].severity, .error)
    }

    // MARK: - Redaction on the way in

    /// Secrets are removed at record time, not at export time: an unredacted
    /// recorder is one forgotten export path away from a leak.
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

    /// The recorder is called from the capture thread, the receive loops, the
    /// UI thread and the sweep timers at once. Under TSan this is the test
    /// that would catch an unguarded buffer; without it, it still catches a
    /// lost or duplicated sequence number.
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
