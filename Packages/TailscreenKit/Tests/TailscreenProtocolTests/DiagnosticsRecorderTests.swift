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
