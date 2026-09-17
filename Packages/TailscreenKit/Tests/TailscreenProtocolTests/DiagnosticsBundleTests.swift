import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticsBundle` — the file format, and the cross-side merge that is the
/// whole reason for recording.
///
/// The format is pinned because it is an interface to a reader that is not
/// this codebase: an agent triaging a report, a `jq` filter, the next version
/// of this app parsing a bundle written by this one. The merge is pinned
/// because its failure mode is the worst one a timeline has — plausible order
/// that is actually wrong, which a reader will confidently interpret as
/// causality.
final class DiagnosticsBundleTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        seq: UInt64,
        _ name: DiagnosticEventName,
        role: DiagnosticRole = .sharer,
        atOffset offset: TimeInterval,
        fields: [String: DiagnosticValue] = [:]
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            seq: seq,
            monotonicNs: UInt64(max(0, offset) * 1_000_000_000),
            wallClock: epoch.addingTimeInterval(offset),
            role: role,
            category: name.category,
            name: name.rawValue,
            severity: name.defaultSeverity,
            fields: fields)
    }

    private func bundle(
        role: DiagnosticRole,
        device: String,
        events: [DiagnosticEvent],
        version: String = "0.10.0-rc.2"
    ) -> DiagnosticsBundle {
        DiagnosticsBundle.make(
            from: DiagnosticsSnapshot(
                role: role,
                deviceLabel: device,
                wasRecording: true,
                startedAt: events.first?.wallClock,
                droppedCount: 0,
                events: events),
            platform: "test",
            appVersion: version,
            commit: "abc1234",
            configuration: "release",
            architecture: "arm64",
            exportedAt: epoch.addingTimeInterval(100))
    }

    // MARK: - The file format

    /// Header first, one event per line, trailing newline. `head -1` must be a
    /// complete answer to "what am I looking at".
    func testFormatIsHeaderThenOneEventPerLine() throws {
        let events = [
            event(seq: 1, .helloReceived, atOffset: 0),
            event(seq: 2, .helloAckSent, atOffset: 0.01)
        ]
        let text = try bundle(role: .sharer, device: "mac", events: events).jsonLines()

        XCTAssertTrue(text.hasSuffix("\n"))
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("tailscreen.diagnostics.header"))
        XCTAssertTrue(lines[1].contains("hello.received"))
        XCTAssertTrue(lines[2].contains("hello.ack.sent"))
    }

    /// A round trip must not lose anything a reader depends on.
    func testRoundTripPreservesEvents() throws {
        let events = [
            event(seq: 1, .helloReceived, atOffset: 0, fields: ["addr": "100.64.0.3"]),
            event(
                seq: 2, .helloAckSent, atOffset: 1.8412,
                fields: ["ssrc": .int(2), "caps": "nack|rr|fec", "guest": .bool(false)])
        ]
        let original = bundle(role: .sharer, device: "mac", events: events)
        let parsed = try DiagnosticsBundle.parse(jsonLines: try original.jsonLines())

        XCTAssertEqual(parsed.header.role, .sharer)
        XCTAssertEqual(parsed.header.device, "mac")
        XCTAssertEqual(parsed.header.channel, .releaseCandidate)
        XCTAssertEqual(parsed.events.count, 2)
        XCTAssertEqual(parsed.events[1].fields["ssrc"], .int(2))
        XCTAssertEqual(parsed.events[1].fields["caps"], .string("nack|rr|fec"))
        XCTAssertEqual(parsed.events[1].fields["guest"], .bool(false))
        XCTAssertEqual(parsed.events[1].name, DiagnosticEventName.helloAckSent.rawValue)
    }

    /// Whole numbers must come back whole. An SSRC rendered `2.0` breaks the
    /// merge's field match, which compares values exactly.
    func testIntegersSurviveAsIntegers() throws {
        let events = [event(seq: 1, .helloAckSent, atOffset: 0, fields: ["ssrc": .int(42)])]
        let text = try bundle(role: .sharer, device: "mac", events: events).jsonLines()
        XCTAssertTrue(text.contains("\"ssrc\":42"), "ssrc was not encoded as an integer")

        let parsed = try DiagnosticsBundle.parse(jsonLines: text)
        XCTAssertEqual(parsed.events[0].fields["ssrc"], .int(42))
    }

    /// Booleans must not decay into 0/1 — the decode order is what guarantees
    /// this and it is easy to get wrong.
    func testBooleansSurviveAsBooleans() throws {
        let events = [event(seq: 1, .linkEnabled, atOffset: 0, fields: ["guest": .bool(true)])]
        let parsed = try DiagnosticsBundle.parse(
            jsonLines: try bundle(role: .sharer, device: "mac", events: events).jsonLines())
        XCTAssertEqual(parsed.events[0].fields["guest"], .bool(true))
    }

    /// Two exports of the same events are byte-identical, so a bundle diffs
    /// against itself usefully and a re-export is not noise in a bug report.
    func testEncodingIsDeterministic() throws {
        let events = [
            event(
                seq: 1, .helloAckSent, atOffset: 0,
                fields: ["z": 1, "a": 2, "m": "x", "b": .bool(true)])
        ]
        let one = bundle(role: .sharer, device: "mac", events: events)
        XCTAssertEqual(try one.jsonLines(), try one.jsonLines())
    }

    /// Elapsed time is written in milliseconds, which is the column a reader's
    /// eye runs down. Raw nanoseconds would be correct and useless.
    func testElapsedIsWrittenInMilliseconds() throws {
        let events = [event(seq: 1, .helloAckSent, atOffset: 1.8412)]
        let text = try bundle(role: .sharer, device: "mac", events: events).jsonLines()
        XCTAssertTrue(
            text.contains("\"elapsed_ms\":1841.2"),
            "expected a millisecond field, got: \(text)")
    }

    /// Every bundle states what is in it. The file is what gets forwarded, and
    /// the second recipient never saw the dialog that produced it.
    func testHeaderCarriesTheContentNotice() throws {
        let parsed = try DiagnosticsBundle.parse(
            jsonLines: try bundle(role: .sharer, device: "mac", events: []).jsonLines())
        XCTAssertFalse(parsed.header.contentNotice.isEmpty)
        XCTAssertTrue(parsed.header.contentNotice.contains("tailnet"))
    }

    // MARK: - Tolerant parsing

    /// A bundle from a newer build must stay readable. The person with the
    /// problem is by definition the one running the newer build, so a reader
    /// that refuses it fails exactly when it is needed.
    func testUnknownEventNamesAndCategoriesSurviveParsing() throws {
        let header = try bundle(role: .sharer, device: "mac", events: []).jsonLines()
        let futureLine = """
            {"at":"2027-01-01T00:00:00.000Z","category":"quantum","elapsed_ms":5.0,\
            "event":"future.thing.happened","role":"sharer","seq":9,"severity":"spicy"}
            """
        let parsed = try DiagnosticsBundle.parse(jsonLines: header + futureLine + "\n")

        XCTAssertEqual(parsed.events.count, 1)
        XCTAssertEqual(parsed.events[0].name, "future.thing.happened")
        XCTAssertEqual(parsed.events[0].category, .fault, "unknown category should fall back")
        XCTAssertEqual(parsed.events[0].severity, .info, "unknown severity should fall back")
    }

    /// One corrupt line must not cost the other four thousand.
    func testCorruptLinesAreSkippedNotFatal() throws {
        let good = try bundle(
            role: .sharer, device: "mac",
            events: [event(seq: 1, .helloReceived, atOffset: 0)]
        ).jsonLines()
        let parsed = try DiagnosticsBundle.parse(
            jsonLines: good + "{not json at all\n\n   \n")

        XCTAssertEqual(parsed.events.count, 1)
    }

    /// A file with no header is not a bundle, and saying so beats returning an
    /// empty one that looks like a session where nothing happened.
    func testMissingHeaderIsAnError() {
        XCTAssertThrowsError(try DiagnosticsBundle.parse(jsonLines: "{\"a\":1}\n")) { error in
            XCTAssertEqual(error as? DiagnosticsBundleError, .missingHeader)
        }
    }

    // MARK: - Merging two sides

    /// Build the two bundles of one handshake, with the viewer's clock
    /// deliberately offset. `skew` is how far the viewer's clock is BEHIND the
    /// sharer's.
    private func handshakePair(
        skew: TimeInterval,
        oneWayDelay: TimeInterval = 0.02
    ) -> (sharer: DiagnosticsBundle, viewer: DiagnosticsBundle) {
        // True times on the sharer's timeline.
        let t1True = 0.0  // viewer sends HELLO
        let t2True = t1True + oneWayDelay  // sharer receives it
        let t3True = t2True + 0.005  // sharer answers
        let t4True = t3True + oneWayDelay  // viewer receives the answer

        let sharerEvents = [
            event(seq: 1, .captureStarted, role: .sharer, atOffset: -1),
            event(
                seq: 2, .helloReceived, role: .sharer, atOffset: t2True,
                fields: ["addr": "100.64.0.3"]),
            event(
                seq: 3, .helloAckSent, role: .sharer, atOffset: t3True,
                fields: ["ssrc": .int(2), "addr": "100.64.0.3"])
        ]
        // The viewer's own clock reads `skew` seconds low.
        let viewerEvents = [
            event(seq: 1, .helloSent, role: .viewer, atOffset: t1True - skew),
            event(
                seq: 2, .helloAckReceived, role: .viewer, atOffset: t4True - skew,
                fields: ["ssrc": .int(2)])
        ]
        return (
            bundle(role: .sharer, device: "sharer-mac", events: sharerEvents),
            bundle(role: .viewer, device: "viewer-pc", events: viewerEvents)
        )
    }

    /// The offset estimate recovers the skew from the handshake's four
    /// timestamps — the NTP formula, with the four values the protocol
    /// already records.
    func testClockSkewIsEstimatedFromTheHandshake() throws {
        let pair = handshakePair(skew: 2.5)
        let estimate = try XCTUnwrap(
            DiagnosticsMerge.estimateOffset(of: pair.viewer, against: pair.sharer))

        XCTAssertEqual(estimate.seconds, 2.5, accuracy: 0.002)
        XCTAssertEqual(estimate.roundTripSeconds, 0.04, accuracy: 0.002)
        XCTAssertEqual(estimate.ssrc, 2)
    }

    /// The payoff: with the correction applied, cause precedes effect. Without
    /// it the viewer's HELLO would sort 2.5 s before the share even started.
    func testMergedTimelineRestoresCausalOrder() {
        let pair = handshakePair(skew: 2.5)
        let timeline = DiagnosticsMerge.merge([pair.sharer, pair.viewer])

        let names = timeline.lines.map(\.event.name)
        XCTAssertEqual(
            names,
            [
                DiagnosticEventName.captureStarted.rawValue,
                DiagnosticEventName.helloSent.rawValue,
                DiagnosticEventName.helloReceived.rawValue,
                DiagnosticEventName.helloAckSent.rawValue,
                DiagnosticEventName.helloAckReceived.rawValue
            ])
        XCTAssertEqual(timeline.referenceDevice, "sharer-mac")
    }

    /// Each send must precede its own receive after correction. Stated
    /// separately from the order above because this is the invariant that
    /// makes the timeline trustworthy at all.
    func testEverySendPrecedesItsReceiveAfterCorrection() throws {
        for skew in [-5.0, -0.3, 0.0, 0.3, 5.0] {
            let pair = handshakePair(skew: skew)
            let timeline = DiagnosticsMerge.merge([pair.sharer, pair.viewer])
            func at(_ name: DiagnosticEventName) throws -> Date {
                try XCTUnwrap(
                    timeline.lines.first { $0.event.name == name.rawValue }
                ).event.wallClock
            }
            XCTAssertLessThanOrEqual(
                try at(.helloSent), try at(.helloReceived),
                "skew \(skew): HELLO arrived before it left")
            XCTAssertLessThanOrEqual(
                try at(.helloAckSent), try at(.helloAckReceived),
                "skew \(skew): HELLO_ACK arrived before it was sent")
        }
    }

    /// The correction is reported, never silently applied. An offset a reader
    /// cannot see is exactly as misleading as a skew they cannot see.
    func testSkewCorrectionIsDisclosed() throws {
        let pair = handshakePair(skew: 2.5)
        let timeline = DiagnosticsMerge.merge([pair.sharer, pair.viewer])

        XCTAssertEqual(timeline.clockNotes.count, 1)
        let note = try XCTUnwrap(timeline.clockNotes.first)
        XCTAssertTrue(note.contains("viewer-pc"))
        XCTAssertTrue(note.contains("SSRC 2"))
    }

    /// The original stamp is kept beside the corrected one, so a reader can
    /// always get back to what the device itself said.
    func testOriginalTimestampIsPreserved() throws {
        let pair = handshakePair(skew: 2.5)
        let timeline = DiagnosticsMerge.merge([pair.sharer, pair.viewer])
        let helloSent = try XCTUnwrap(
            timeline.lines.first { $0.event.name == DiagnosticEventName.helloSent.rawValue })

        XCTAssertEqual(helloSent.appliedOffsetSeconds, 2.5, accuracy: 0.002)
        XCTAssertEqual(
            helloSent.event.wallClock.timeIntervalSince(helloSent.originalWallClock),
            2.5,
            accuracy: 0.002)
    }

    /// Two bundles that never talked to each other cannot be aligned, and
    /// saying so beats inventing an offset. A confidently wrong timeline is
    /// worse than one labelled uncertain.
    func testUnpairedBundlesAreShownAsRecordedAndFlagged() {
        let sharer = bundle(
            role: .sharer, device: "sharer-mac",
            events: [event(seq: 1, .captureStarted, atOffset: 0)])
        let stranger = bundle(
            role: .viewer, device: "other-pc",
            events: [event(seq: 1, .helloSent, role: .viewer, atOffset: 0)])

        let timeline = DiagnosticsMerge.merge([sharer, stranger])
        XCTAssertTrue(timeline.lines.allSatisfy { $0.appliedOffsetSeconds == 0 })
        XCTAssertEqual(timeline.clockNotes.count, 1)
        XCTAssertTrue(timeline.clockNotes[0].contains("no handshake"))
    }

    /// Ties break deterministically, so a timeline does not reorder itself
    /// between runs and can be cited line by line.
    func testMergeIsDeterministicUnderTies() {
        let a = bundle(
            role: .sharer, device: "aaa",
            events: [event(seq: 1, .captureStarted, atOffset: 0)])
        let b = bundle(
            role: .viewer, device: "zzz",
            events: [event(seq: 1, .helloSent, role: .viewer, atOffset: 0)])

        let first = DiagnosticsMerge.merge([a, b]).lines.map(\.device)
        let second = DiagnosticsMerge.merge([b, a]).lines.map(\.device)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, ["aaa", "zzz"])
    }

    /// A merge of one side is just that side — the common case when only one
    /// person could get a bundle out.
    func testSingleBundleMergesToItself() {
        let only = bundle(
            role: .viewer, device: "viewer-pc",
            events: [event(seq: 1, .helloSent, role: .viewer, atOffset: 0)])
        let timeline = DiagnosticsMerge.merge([only])

        XCTAssertEqual(timeline.lines.count, 1)
        XCTAssertEqual(timeline.referenceDevice, "viewer-pc")
        XCTAssertTrue(timeline.clockNotes.isEmpty)
    }

    /// One process can be both ends at once — a Mac sharing its screen to one
    /// person while watching another's. The merge must pair on what the
    /// bundles CONTAIN, not on their header role, or the dual-role side pairs
    /// as whichever one it happened to default to and the offset is solved
    /// from the wrong handshake.
    func testDualRoleBundlePairsOnEventsNotHeaderRole() {
        // This side both answered a HELLO (as sharer) and, separately, is the
        // one whose clock we want aligned. Its header says `.app`.
        let dualEvents = [
            event(seq: 1, .helloReceived, role: .sharer, atOffset: 0.02),
            event(
                seq: 2, .helloAckSent, role: .sharer, atOffset: 0.025,
                fields: ["ssrc": .int(5)])
        ]
        let dual = bundle(role: .app, device: "dual-mac", events: dualEvents)

        // The plain viewer, whose clock reads 3 s low.
        let viewerEvents = [
            event(seq: 1, .helloSent, role: .viewer, atOffset: 0 - 3.0),
            event(
                seq: 2, .helloAckReceived, role: .viewer, atOffset: 0.045 - 3.0,
                fields: ["ssrc": .int(5)])
        ]
        let viewer = bundle(role: .viewer, device: "viewer-pc", events: viewerEvents)

        let estimate = DiagnosticsMerge.estimateOffset(of: viewer, against: dual)
        XCTAssertEqual(estimate?.seconds ?? 0, 3.0, accuracy: 0.002)

        // And the dual-role bundle is chosen as the reference, because it is
        // the side that sent the ack.
        XCTAssertEqual(DiagnosticsMerge.merge([viewer, dual]).referenceDevice, "dual-mac")
    }

    /// The estimate works with the arguments the other way round too — the
    /// sign has to flip, and getting that wrong would double the skew instead
    /// of removing it.
    func testOffsetEstimateIsSymmetric() {
        let pair = handshakePair(skew: 2.5)
        let forward = DiagnosticsMerge.estimateOffset(of: pair.viewer, against: pair.sharer)
        let backward = DiagnosticsMerge.estimateOffset(of: pair.sharer, against: pair.viewer)

        XCTAssertEqual(forward?.seconds ?? 0, 2.5, accuracy: 0.002)
        XCTAssertEqual(backward?.seconds ?? 0, -2.5, accuracy: 0.002)
    }

    /// An empty input is not a crash.
    func testEmptyMergeIsEmpty() {
        let timeline = DiagnosticsMerge.merge([])
        XCTAssertTrue(timeline.lines.isEmpty)
        XCTAssertTrue(timeline.clockNotes.isEmpty)
    }
}
