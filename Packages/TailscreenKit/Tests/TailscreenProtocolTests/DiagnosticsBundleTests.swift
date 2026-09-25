import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticsBundle`: the file format, and the cross-side merge that
/// aligns two devices' clocks into one causally-ordered timeline.
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

    /// Re-stamp `monotonicNs` as elapsed since the first event, matching the
    /// invariant `DiagnosticsRecorder` actually maintains.
    private func normalized(_ events: [DiagnosticEvent]) -> [DiagnosticEvent] {
        guard let start = events.first?.wallClock else { return events }
        return events.map { event in
            var copy = event
            let elapsed = event.wallClock.timeIntervalSince(start)
            copy.monotonicNs = elapsed > 0 ? UInt64(elapsed * 1_000_000_000) : 0
            return copy
        }
    }

    private func bundle(
        role: DiagnosticRole,
        device: String,
        events rawEvents: [DiagnosticEvent],
        version: String = "0.10.0-rc.2"
    ) -> DiagnosticsBundle {
        let events = normalized(rawEvents)
        return DiagnosticsBundle.make(
            from: DiagnosticsSnapshot(
                role: role,
                deviceLabel: device,
                wasRecording: true,
                startedAt: events.first?.wallClock,
                droppedCount: 0,
                events: events),
            environment: DiagnosticsEnvironment(
                platform: "test", appVersion: version, commit: "abc1234",
                configuration: "release", architecture: "arm64", deviceLabel: device),
            exportedAt: epoch.addingTimeInterval(100))
    }

    // MARK: - The file format

    /// Header first, one event per line, trailing newline.
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

    /// An SSRC rendered `2.0` would break the merge's exact field match.
    func testIntegersSurviveAsIntegers() throws {
        let events = [event(seq: 1, .helloAckSent, atOffset: 0, fields: ["ssrc": .int(42)])]
        let text = try bundle(role: .sharer, device: "mac", events: events).jsonLines()
        XCTAssertTrue(text.contains("\"ssrc\":42"), "ssrc was not encoded as an integer")

        let parsed = try DiagnosticsBundle.parse(jsonLines: text)
        XCTAssertEqual(parsed.events[0].fields["ssrc"], .int(42))
    }

    /// Booleans must not decay into 0/1.
    func testBooleansSurviveAsBooleans() throws {
        let events = [event(seq: 1, .linkEnabled, atOffset: 0, fields: ["guest": .bool(true)])]
        let parsed = try DiagnosticsBundle.parse(
            jsonLines: try bundle(role: .sharer, device: "mac", events: events).jsonLines())
        XCTAssertEqual(parsed.events[0].fields["guest"], .bool(true))
    }

    /// Two exports of the same events are byte-identical.
    func testEncodingIsDeterministic() throws {
        let events = [
            event(
                seq: 1, .helloAckSent, atOffset: 0,
                fields: ["z": 1, "a": 2, "m": "x", "b": .bool(true)])
        ]
        let one = bundle(role: .sharer, device: "mac", events: events)
        XCTAssertEqual(try one.jsonLines(), try one.jsonLines())
    }

    /// Elapsed time is written in milliseconds, not raw nanoseconds.
    func testElapsedIsWrittenInMilliseconds() throws {
        let events = [
            event(seq: 1, .helloReceived, atOffset: 0),
            event(seq: 2, .helloAckSent, atOffset: 1.8412)
        ]
        let text = try bundle(role: .sharer, device: "mac", events: events).jsonLines()
        XCTAssertTrue(
            text.contains("\"elapsed_ms\":1841.2"),
            "expected a millisecond field, got: \(text)")
    }

    /// Every bundle states what's in it, since the file gets forwarded to
    /// someone who never saw the dialog that produced it.
    func testHeaderCarriesTheContentNotice() throws {
        let parsed = try DiagnosticsBundle.parse(
            jsonLines: try bundle(role: .sharer, device: "mac", events: []).jsonLines())
        XCTAssertFalse(parsed.header.contentNotice.isEmpty)
        XCTAssertTrue(parsed.header.contentNotice.contains("tailnet"))
    }

    // MARK: - Tolerant parsing

    /// A bundle from a newer build must stay readable: unknown names/categories
    /// fall back instead of failing the parse.
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

    /// A valid-JSON but absurd number (`elapsed_ms:1e300`) must not crash the
    /// reader — `UInt64(someDouble)` traps on NaN/infinity/overflow.
    func testAbsurdElapsedDoesNotCrashTheReader() throws {
        let header = try bundle(role: .sharer, device: "mac", events: []).jsonLines()
        for value in ["1e300", "-1e300", "1e999", "1e-300"] {
            let line = """
                {"at":"2027-01-01T00:00:00.000Z","category":"media","elapsed_ms":\(value),                "event":"decode.failed","role":"viewer","seq":9,"severity":"warning"}
                """
            // Assertion is that this returns; surviving vs. being skipped is
            // the parser's business.
            let parsed = try DiagnosticsBundle.parse(jsonLines: header + line + "\n")
            XCTAssertLessThanOrEqual(parsed.events.count, 1, "value \(value)")
        }
    }

    func testNanosecondConversionSaturatesInsteadOfTrapping() {
        XCTAssertEqual(DiagnosticEvent.nanoseconds(fromMilliseconds: 1.5), 1_500_000)
        XCTAssertEqual(DiagnosticEvent.nanoseconds(fromMilliseconds: 0), 0)
        XCTAssertEqual(DiagnosticEvent.nanoseconds(fromMilliseconds: -5), 0)
        XCTAssertEqual(DiagnosticEvent.nanoseconds(fromMilliseconds: .nan), 0)
        // Non-finite maps to 0, not `.max` — `.max` would sort the event to the
        // end of the session, asserting more than the data supports.
        XCTAssertEqual(DiagnosticEvent.nanoseconds(fromMilliseconds: .infinity), 0)
        XCTAssertEqual(DiagnosticEvent.nanoseconds(fromMilliseconds: 1e300), .max)
    }

    func testCorruptLinesAreSkippedNotFatal() throws {
        let good = try bundle(
            role: .sharer, device: "mac",
            events: [event(seq: 1, .helloReceived, atOffset: 0)]
        ).jsonLines()
        let parsed = try DiagnosticsBundle.parse(
            jsonLines: good + "{not json at all\n\n   \n")

        XCTAssertEqual(parsed.events.count, 1)
    }

    /// A missing header must error, not parse as an empty (nothing-happened) session.
    func testMissingHeaderIsAnError() {
        XCTAssertThrowsError(try DiagnosticsBundle.parse(jsonLines: "{\"a\":1}\n")) { error in
            XCTAssertEqual(error as? DiagnosticsBundleError, .missingHeader)
        }
    }

    /// The one thing the tolerant parser refuses: a future schema, since
    /// `currentSchema` bumps only when an older reader would misread it.
    func testAFutureSchemaIsRefusedRatherThanMisread() throws {
        let text = try bundle(
            role: .sharer, device: "mac",
            events: [event(seq: 1, .helloAckSent, role: .sharer, atOffset: 0)]
        ).jsonLines().replacingOccurrences(of: "\"schema\":1", with: "\"schema\":2")

        XCTAssertThrowsError(try DiagnosticsBundle.parse(jsonLines: text)) { error in
            XCTAssertEqual(
                error as? DiagnosticsBundleError, .unsupportedSchema(2), "\(error)")
        }
    }

    func testAnOlderSchemaStillParses() throws {
        let text = try bundle(
            role: .sharer, device: "mac",
            events: [event(seq: 1, .helloAckSent, role: .sharer, atOffset: 0)]
        ).jsonLines().replacingOccurrences(of: "\"schema\":1", with: "\"schema\":0")

        XCTAssertEqual(try DiagnosticsBundle.parse(jsonLines: text).events.count, 1)
    }

    // MARK: - Merging two sides

    /// Builds the two bundles of one handshake, with the viewer's clock
    /// offset `skew` seconds behind the sharer's.
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

    /// The NTP formula recovers skew from the handshake's four timestamps.
    func testClockSkewIsEstimatedFromTheHandshake() throws {
        let pair = handshakePair(skew: 2.5)
        let estimate = try XCTUnwrap(
            DiagnosticsMerge.estimateOffset(of: pair.viewer, against: pair.sharer))

        XCTAssertEqual(estimate.seconds, 2.5, accuracy: 0.002)
        XCTAssertEqual(estimate.roundTripSeconds, 0.04, accuracy: 0.002)
        XCTAssertEqual(estimate.ssrc, 2)
    }

    /// With the correction applied, cause precedes effect.
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

    /// Each send must precede its own receive after correction.
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

    /// The correction is reported, never silently applied.
    func testSkewCorrectionIsDisclosed() throws {
        let pair = handshakePair(skew: 2.5)
        let timeline = DiagnosticsMerge.merge([pair.sharer, pair.viewer])

        XCTAssertEqual(timeline.clockNotes.count, 1)
        let note = try XCTUnwrap(timeline.clockNotes.first)
        XCTAssertTrue(note.contains("viewer-pc"))
        XCTAssertTrue(note.contains("SSRC 2"))
    }

    /// The original stamp is kept beside the corrected one.
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

    /// Two bundles that never talked cannot be aligned; say so rather than
    /// inventing an offset.
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

    /// Ties break deterministically, so a timeline can be cited line by line.
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

    func testSingleBundleMergesToItself() {
        let only = bundle(
            role: .viewer, device: "viewer-pc",
            events: [event(seq: 1, .helloSent, role: .viewer, atOffset: 0)])
        let timeline = DiagnosticsMerge.merge([only])

        XCTAssertEqual(timeline.lines.count, 1)
        XCTAssertEqual(timeline.referenceDevice, "viewer-pc")
        XCTAssertTrue(timeline.clockNotes.isEmpty)
    }

    /// One process can be both ends at once — a Mac sharing while also
    /// viewing. The merge must pair on what the bundles CONTAIN, not on
    /// their header role, or the offset is solved from the wrong handshake.
    func testDualRoleBundlePairsOnEventsNotHeaderRole() {
        // Answered a HELLO (as sharer) but its header says `.app`.
        let dualEvents = [
            event(seq: 1, .helloReceived, role: .sharer, atOffset: 0.02),
            event(
                seq: 2, .helloAckSent, role: .sharer, atOffset: 0.025,
                fields: ["ssrc": .int(5)])
        ]
        let dual = bundle(role: .app, device: "dual-mac", events: dualEvents)

        let viewerEvents = [
            event(seq: 1, .helloSent, role: .viewer, atOffset: 0 - 3.0),
            event(
                seq: 2, .helloAckReceived, role: .viewer, atOffset: 0.045 - 3.0,
                fields: ["ssrc": .int(5)])
        ]
        let viewer = bundle(role: .viewer, device: "viewer-pc", events: viewerEvents)

        let estimate = DiagnosticsMerge.estimateOffset(of: viewer, against: dual)
        XCTAssertEqual(estimate?.seconds ?? 0, 3.0, accuracy: 0.002)

        // The dual-role bundle is the reference: it's the side that sent the ack.
        XCTAssertEqual(DiagnosticsMerge.merge([viewer, dual]).referenceDevice, "dual-mac")
    }

    /// Reversing the arguments must flip the sign, not double the skew.
    func testOffsetEstimateIsSymmetric() {
        let pair = handshakePair(skew: 2.5)
        let forward = DiagnosticsMerge.estimateOffset(of: pair.viewer, against: pair.sharer)
        let backward = DiagnosticsMerge.estimateOffset(of: pair.sharer, against: pair.viewer)

        XCTAssertEqual(forward?.seconds ?? 0, 2.5, accuracy: 0.002)
        XCTAssertEqual(backward?.seconds ?? 0, -2.5, accuracy: 0.002)
    }

    /// With several viewers joining at once, pairing on time alone could pick
    /// another viewer's HELLO — the ack's `addr` must be matched too.
    func testOffsetPairsTheRightViewersHello() throws {
        let sharer = bundle(
            role: .sharer, device: "sharer-mac",
            events: [
                event(
                    seq: 1, .helloReceived, atOffset: 0.00,
                    fields: ["addr": "100.64.0.3"]),
                // A second viewer's HELLO between this one and its ack.
                event(
                    seq: 2, .helloReceived, atOffset: 0.01,
                    fields: ["addr": "100.64.0.9"]),
                event(
                    seq: 3, .helloAckSent, atOffset: 0.02,
                    fields: ["ssrc": .int(2), "addr": "100.64.0.3"])
            ])
        let viewer = bundle(
            role: .viewer, device: "viewer-pc",
            events: [
                event(seq: 1, .helloSent, role: .viewer, atOffset: -0.02),
                event(
                    seq: 2, .helloAckReceived, role: .viewer, atOffset: 0.04,
                    fields: ["ssrc": .int(2)])
            ])

        let estimate = try XCTUnwrap(
            DiagnosticsMerge.estimateOffset(of: viewer, against: sharer))
        // Paired against the 0.00 HELLO, not the 0.01 one.
        XCTAssertEqual(estimate.roundTripSeconds, 0.04, accuracy: 0.002)
    }

    /// A wall clock that steps mid-session must not reorder one device's own
    /// events — this is what `monotonicNs` is for.
    func testClockStepDoesNotReorderOneDevicesOwnEvents() {
        // Monotonic and increasing, but the middle event's wall clock jumps
        // backwards a minute (an NTP correction mid-share).
        let events = [
            DiagnosticEvent(
                seq: 1, monotonicNs: 0, wallClock: epoch, role: .sharer,
                category: .media, name: DiagnosticEventName.captureStarted.rawValue,
                severity: .info, fields: [:]),
            DiagnosticEvent(
                seq: 2, monotonicNs: 1_000_000_000,
                wallClock: epoch.addingTimeInterval(-60), role: .sharer,
                category: .media, name: DiagnosticEventName.encodeCodecSelected.rawValue,
                severity: .info, fields: [:]),
            DiagnosticEvent(
                seq: 3, monotonicNs: 2_000_000_000,
                wallClock: epoch.addingTimeInterval(-59), role: .sharer,
                category: .media, name: DiagnosticEventName.decodeFirstFrame.rawValue,
                severity: .info, fields: [:])
        ]
        let only = DiagnosticsBundle.make(
            from: DiagnosticsSnapshot(
                role: .sharer, deviceLabel: "sharer-mac", wasRecording: true,
                startedAt: epoch, droppedCount: 0, events: events),
            environment: DiagnosticsEnvironment(
                platform: "test", appVersion: "0.10.0-rc.2", commit: "abc1234",
                configuration: "release", architecture: "arm64",
                deviceLabel: "sharer-mac"))

        let timeline = DiagnosticsMerge.merge([only])
        XCTAssertEqual(
            timeline.lines.map(\.event.seq), [1, 2, 3],
            "a backwards clock step reordered one device's own events")
    }

    /// A backward clock step on the sharer, between receiving the HELLO and
    /// answering it, must not lose the pairing. Within one bundle `seq` is
    /// exact and monotonic; comparing wall clocks there let a step make the
    /// HELLO look later than its own ack, defeating the pairing on exactly
    /// the bundles most needing alignment.
    func testBackwardClockStepOnTheSharerStillPairs() {
        let viewer = bundle(
            role: .viewer, device: "viewer-pc",
            events: [
                event(seq: 1, .helloSent, role: .viewer, atOffset: 0),
                event(
                    seq: 2, .helloAckReceived, role: .viewer, atOffset: 0.04,
                    fields: ["ssrc": .int(7)])
            ])
        // Steps back 3 s in the 5 ms between receiving and answering.
        let sharer = bundle(
            role: .sharer, device: "sharer-mac",
            events: [
                event(
                    seq: 1, .helloReceived, role: .sharer, atOffset: 0.02,
                    fields: ["addr": "100.64.0.3"]),
                event(
                    seq: 2, .helloAckSent, role: .sharer, atOffset: -2.975,
                    fields: ["ssrc": .int(7), "addr": "100.64.0.3"])
            ])

        XCTAssertNotNil(
            DiagnosticsMerge.estimateOffset(of: viewer, against: sharer),
            "a clock step inside one bundle defeated the handshake pairing")
    }

    // MARK: - Sessions

    /// The pairing must not reach back into an earlier session: a session
    /// whose own HELLO was evicted under the retention cap still has its ACK,
    /// and `last(where: seq <= ack)` could walk back past the session
    /// boundary and pair it with a HELLO from an hour earlier.
    func testHandshakePairingDoesNotReachIntoAnEarlierSession() {
        func viewerEvent(
            _ seq: UInt64, _ name: DiagnosticEventName, _ session: UInt32,
            _ offset: TimeInterval, _ fields: [String: DiagnosticValue] = [:]
        ) -> DiagnosticEvent {
            DiagnosticEvent(
                seq: seq, monotonicNs: UInt64(max(0, offset) * 1_000_000_000),
                wallClock: epoch.addingTimeInterval(offset), session: session,
                role: .viewer, category: name.category, name: name.rawValue,
                severity: name.defaultSeverity, fields: fields)
        }
        // Session 0's HELLO survived; session 1's didn't, but its ACK did.
        let viewer = bundle(
            role: .viewer, device: "viewer-pc",
            events: [
                viewerEvent(1, .helloSent, 0, 0),
                viewerEvent(9, .helloAckReceived, 1, 3600.04, ["ssrc": .int(7)])
            ])
        let sharer = bundle(
            role: .sharer, device: "sharer-mac",
            events: [
                event(
                    seq: 1, .helloReceived, role: .sharer, atOffset: 3600.02,
                    fields: ["addr": "100.64.0.3"]),
                event(
                    seq: 2, .helloAckSent, role: .sharer, atOffset: 3600.025,
                    fields: ["ssrc": .int(7), "addr": "100.64.0.3"])
            ])

        XCTAssertNil(
            DiagnosticsMerge.estimateOffset(of: viewer, against: sharer),
            "paired an ACK with a HELLO from the previous session")
    }

    /// Applying one offset to a multi-session bundle is disclosed: later
    /// sessions are corrected by an estimate taken during an earlier one.
    func testASingleOffsetOverManySessionsIsDisclosed() {
        let pair = handshakePair(skew: 2.5)
        var viewer = pair.viewer
        viewer.events.append(
            DiagnosticEvent(
                seq: 9, monotonicNs: 3_600_000_000_000,
                wallClock: epoch.addingTimeInterval(3600), session: 1,
                role: .viewer, category: DiagnosticEventName.transportSummary.category,
                name: DiagnosticEventName.transportSummary.rawValue, severity: .info))

        let timeline = DiagnosticsMerge.merge([pair.sharer, viewer])
        XCTAssertTrue(
            timeline.clockNotes.contains { $0.contains("applied to all of them") },
            "\(timeline.clockNotes)")
    }

    // MARK: - Holes in a stream

    /// The rendered timeline must not present a hole as adjacency: once the
    /// ring wraps, the retained prologue and the recent ring sit next to each
    /// other with an unknown interval between them.
    func testDroppedEventsBecomeAGapInTheMergedTimeline() {
        let events = [
            event(seq: 1, .helloSent, role: .viewer, atOffset: 0),
            // seq 2...40 were evicted.
            event(seq: 41, .transportSummary, role: .viewer, atOffset: 30)
        ]
        let timeline = DiagnosticsMerge.merge([bundle(role: .viewer, device: "pc", events: events)])

        XCTAssertEqual(timeline.gaps.count, 1)
        XCTAssertEqual(timeline.gaps.first?.missing, 39)
        XCTAssertEqual(timeline.gaps.first?.device, "pc")
    }

    /// A gap is located by where it is, not just counted: the marker sits at
    /// the first event after the hole.
    func testGapIsPlacedAtTheEventThatFollowsIt() {
        let events = [
            event(seq: 1, .helloSent, role: .viewer, atOffset: 0),
            event(seq: 2, .helloAckReceived, role: .viewer, atOffset: 1),
            event(seq: 9, .transportSummary, role: .viewer, atOffset: 12)
        ]
        let timeline = DiagnosticsMerge.merge([bundle(role: .viewer, device: "pc", events: events)])

        XCTAssertEqual(timeline.gaps.count, 1)
        XCTAssertEqual(
            timeline.gaps.first?.at, timeline.lines[2].event.wallClock,
            "the marker belongs immediately before the first surviving event")
    }

    /// A bundle starting at a sequence above 1 lost a whole session prologue
    /// to the retention cap — a hole with no event in front of it.
    func testAReleasedLeadingPrologueIsAGapToo() {
        let events = [
            event(seq: 12, .helloSent, role: .viewer, atOffset: 0),
            event(seq: 13, .helloAckReceived, role: .viewer, atOffset: 1)
        ]
        let timeline = DiagnosticsMerge.merge([bundle(role: .viewer, device: "pc", events: events)])

        XCTAssertEqual(timeline.gaps.count, 1)
        XCTAssertEqual(timeline.gaps.first?.missing, 11)
    }

    /// A dense stream reports no gap at all.
    func testADenseStreamHasNoGaps() {
        let events = [
            event(seq: 1, .helloSent, role: .viewer, atOffset: 0),
            event(seq: 2, .helloAckReceived, role: .viewer, atOffset: 1),
            event(seq: 3, .transportSummary, role: .viewer, atOffset: 2)
        ]
        let timeline = DiagnosticsMerge.merge([bundle(role: .viewer, device: "pc", events: events)])

        XCTAssertTrue(timeline.gaps.isEmpty)
    }

    // MARK: - Where each side's timeline is anchored

    /// A bundle whose wall clock stepped between start-up and the handshake:
    /// `startedAt` is the pre-step reading, the handshake the post-step one.
    private func steppedClockBundle(step: TimeInterval) -> DiagnosticsBundle {
        let events = [
            DiagnosticEvent(
                seq: 1, monotonicNs: 0, wallClock: epoch, role: .sharer,
                category: DiagnosticEventName.captureStarted.category,
                name: DiagnosticEventName.captureStarted.rawValue, severity: .info),
            DiagnosticEvent(
                seq: 2, monotonicNs: 1_000_000_000,
                wallClock: epoch.addingTimeInterval(1 + step), role: .sharer,
                category: DiagnosticEventName.helloAckSent.category,
                name: DiagnosticEventName.helloAckSent.rawValue, severity: .info)
        ]
        return DiagnosticsBundle.make(
            from: DiagnosticsSnapshot(
                role: .sharer, deviceLabel: "sharer-mac", wasRecording: true,
                startedAt: epoch, droppedCount: 0, events: events),
            environment: DiagnosticsEnvironment(
                platform: "test", appVersion: "0.10.0-rc.2", commit: "abc1234",
                configuration: "release", architecture: "arm64",
                deviceLabel: "sharer-mac"),
            exportedAt: epoch.addingTimeInterval(100))
    }

    /// The anchor comes from the handshake, not the session start: the
    /// cross-device offset is estimated from handshake timestamps, so
    /// anchoring at a pre-step `startedAt` would shift the whole timeline
    /// by the step.
    func testAnchorIsDerivedFromTheHandshakeNotTheSessionStart() throws {
        let anchor = try XCTUnwrap(DiagnosticsMerge.anchor(for: steppedClockBundle(step: 5)))

        XCTAssertEqual(anchor.timeIntervalSince(epoch), 5, accuracy: 0.001)
    }

    func testSteppedClockDoesNotStretchTheGapBeforeTheHandshake() {
        let timeline = DiagnosticsMerge.merge([steppedClockBundle(step: 5)])

        XCTAssertEqual(timeline.lines.count, 2)
        let gap = timeline.lines[1].event.wallClock.timeIntervalSince(
            timeline.lines[0].event.wallClock)
        XCTAssertEqual(gap, 1, accuracy: 0.001, "the step was replayed as elapsed time")
    }

    /// Without a handshake, `startedAt` is the fallback.
    func testAnchorFallsBackToTheSessionStartWithoutAHandshake() throws {
        let events = [
            event(seq: 1, .captureStarted, role: .sharer, atOffset: 0),
            event(seq: 2, .captureFailed, role: .sharer, atOffset: 2)
        ]
        let anchor = try XCTUnwrap(
            DiagnosticsMerge.anchor(for: bundle(role: .sharer, device: "mac", events: events)))

        XCTAssertEqual(anchor.timeIntervalSince(epoch), 0, accuracy: 0.001)
    }

    /// An empty input is not a crash.
    func testEmptyMergeIsEmpty() {
        let timeline = DiagnosticsMerge.merge([])
        XCTAssertTrue(timeline.lines.isEmpty)
        XCTAssertTrue(timeline.clockNotes.isEmpty)
    }
}
