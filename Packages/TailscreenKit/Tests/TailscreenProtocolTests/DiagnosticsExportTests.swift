import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticsExport` — the filenames, the write, and the rendered timeline.
///
/// The renderer is pinned because it is the actual deliverable of this whole
/// feature: the bundle is what gets sent, but the timeline is what gets read.
/// Its failure mode is not a crash, it is a wall of text nobody can scan —
/// which looks like a working feature and helps nobody.
final class DiagnosticsExportTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Filenames

    /// Role and device are in the name because these files arrive in pairs,
    /// in a chat thread, renamed. Two files called `diagnostics.jsonl` do not
    /// survive that.
    func testFilenameNamesTheSideItCameFrom() {
        let name = DiagnosticsExport.filename(
            role: .sharer, device: "Robert's MacBook Pro", at: epoch)

        XCTAssertTrue(name.hasPrefix("tailscreen-sharer-roberts-macbook-pro-"))
        XCTAssertTrue(name.hasSuffix(".jsonl"))
    }

    /// The stamp sorts lexicographically, so one session's bundles land next
    /// to each other in any file listing.
    func testTimestampsSortChronologically() {
        let earlier = DiagnosticsExport.stamp(epoch)
        let later = DiagnosticsExport.stamp(epoch.addingTimeInterval(3600))
        XCTAssertLessThan(earlier, later)
    }

    /// Device names are user-chosen and arrive with anything in them. The
    /// slug has to be safe on Windows too, which rejects `<>:"/\|?*`.
    func testSlugIsSafeOnEveryPlatform() {
        let forbidden = Set("<>:\"/\\|?* '")
        for name in ["Robert's Mac", "desk<top>", "a/b\\c", "  spaced  out  "] {
            let slug = DiagnosticsExport.slug(name)
            XCTAssertTrue(
                slug.unicodeScalars.allSatisfy { !forbidden.contains(Character($0)) },
                "\(name) → \(slug) kept a forbidden character")
            XCTAssertFalse(slug.hasPrefix("-"), "\(name) → \(slug)")
            XCTAssertFalse(slug.hasSuffix("-"), "\(name) → \(slug)")
        }
    }

    /// A name with nothing ASCII in it must not slug away to nothing and
    /// produce a filename with a hole in it.
    func testFullyNonASCIINameStillYieldsAName() {
        XCTAssertEqual(DiagnosticsExport.slug("日本語"), "device")
        XCTAssertEqual(DiagnosticsExport.slug(""), "device")
    }

    // MARK: - Writing

    /// Round-trip through the filesystem, including creating the directory.
    func testWriteCreatesDirectoriesAndRoundTrips() throws {
        let recorder = DiagnosticsRecorder(
            defaultRole: .viewer, deviceLabel: "viewer-pc", enabled: true)
        recorder.record(.helloSent, fields: ["caps": "nack|rr|fec"])

        let bundle = DiagnosticsBundle.make(
            from: recorder.snapshot(),
            environment: DiagnosticsEnvironment(
                platform: "linux", appVersion: "0.10.0-rc.2", commit: "abc1234",
                configuration: "release", architecture: "x86_64",
                deviceLabel: "viewer-pc"))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diagnostics-test-\(UUID().uuidString)/nested")
        let url = directory.appendingPathComponent("bundle.jsonl")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        try DiagnosticsExport.write(bundle, to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = try DiagnosticsBundle.parse(jsonLines: text)
        XCTAssertEqual(parsed.header.device, "viewer-pc")
        XCTAssertEqual(parsed.events.count, 1)
    }

    // MARK: - The rendered timeline

    /// Re-stamp `monotonicNs` as elapsed since the FIRST event, which is the
    /// invariant `DiagnosticsRecorder` actually maintains.
    ///
    /// The fixtures used to derive it from a fixed epoch with negatives clamped
    /// to zero, which no real recorder would ever produce — and the merge now
    /// replays each side from its anchor plus that elapsed, so an inconsistent
    /// fixture produced an inconsistent timeline. Building the fixtures the way
    /// the recorder builds them keeps the suite testing the code rather than
    /// testing a fiction.
    private func normalized(_ events: [DiagnosticEvent]) -> [DiagnosticEvent] {
        guard let start = events.first?.wallClock else { return events }
        return events.map { event in
            var copy = event
            let elapsed = event.wallClock.timeIntervalSince(start)
            copy.monotonicNs = elapsed > 0 ? UInt64(elapsed * 1_000_000_000) : 0
            return copy
        }
    }

    private func twoSidedTimeline() -> DiagnosticsMerge.Timeline {
        func event(
            _ seq: UInt64, _ name: DiagnosticEventName, _ role: DiagnosticRole,
            _ offset: TimeInterval, _ fields: [String: DiagnosticValue] = [:]
        ) -> DiagnosticEvent {
            DiagnosticEvent(
                seq: seq, monotonicNs: UInt64(max(0, offset) * 1_000_000_000),
                wallClock: epoch.addingTimeInterval(offset), role: role,
                category: name.category, name: name.rawValue,
                severity: name.defaultSeverity, fields: fields)
        }
        func bundle(
            _ role: DiagnosticRole, _ device: String, _ rawEvents: [DiagnosticEvent]
        ) -> DiagnosticsBundle {
            let events = normalized(rawEvents)
            return DiagnosticsBundle.make(
                from: DiagnosticsSnapshot(
                    role: role, deviceLabel: device, wasRecording: true,
                    startedAt: events.first?.wallClock, droppedCount: 0, events: events),
                environment: DiagnosticsEnvironment(
                    platform: "test", appVersion: "0.10.0-rc.2", commit: "abc1234",
                    configuration: "release", architecture: "arm64", deviceLabel: device))
        }

        let sharer = bundle(
            .sharer, "sharer-mac",
            [
                event(1, .captureStarted, .sharer, 0),
                event(2, .helloReceived, .sharer, 1.02, ["addr": "100.64.0.3"]),
                event(3, .helloAckSent, .sharer, 1.03, ["ssrc": .int(2), "addr": "100.64.0.3"]),
                event(4, .viewerAdmitted, .sharer, 1.04, ["addr": "100.64.0.3"])
            ])
        let viewer = bundle(
            .viewer, "viewer-pc",
            [
                event(1, .helloSent, .viewer, 1.00, ["caps": "nack|rr|fec"]),
                event(2, .helloAckReceived, .viewer, 1.05, ["ssrc": .int(2)]),
                event(3, .decodeFailed, .viewer, 2.00, ["reason": "no parameter sets"])
            ])
        return DiagnosticsMerge.merge([sharer, viewer])
    }

    /// The output has to be scannable: one line per event, aligned columns, so
    /// a reader's eye can run down the device column and the event column.
    func testTimelineRendersOneAlignedLinePerEvent() {
        let text = DiagnosticsExport.renderTimeline(twoSidedTimeline())
        let body = text.split(separator: "\n").filter { $0.contains("hello.") || $0.contains("capture.") }

        XCTAssertEqual(body.count, 5)
        // Device and category start at the same column on every row.
        let deviceColumns = body.map { line -> Int in
            line.distance(
                from: line.startIndex,
                to: line.firstIndex(where: { $0.isLetter }) ?? line.startIndex)
        }
        XCTAssertEqual(Set(deviceColumns).count, 1, "columns are not aligned:\n\(text)")
    }

    /// Both devices appear, with the events interleaved in causal order —
    /// which is the entire reason for merging rather than concatenating.
    func testTimelineInterleavesBothSidesInCausalOrder() {
        let text = DiagnosticsExport.renderTimeline(twoSidedTimeline())
        let order = text.split(separator: "\n").compactMap { line -> String? in
            for name in ["hello.sent", "hello.received", "hello.ack.sent", "hello.ack.received"]
            where line.contains(name) {
                return name
            }
            return nil
        }
        XCTAssertEqual(
            order, ["hello.sent", "hello.received", "hello.ack.sent", "hello.ack.received"])
        XCTAssertTrue(text.contains("sharer-mac"))
        XCTAssertTrue(text.contains("viewer-pc"))
    }

    /// Times are relative to the first event — "three seconds in, the viewer
    /// was denied" is what a reader wants, not a wall-clock stamp they have to
    /// subtract in their head.
    func testTimesAreRelativeToTheFirstEvent() {
        let text = DiagnosticsExport.renderTimeline(twoSidedTimeline())
        XCTAssertTrue(text.contains("0.000s"), "first event should read zero:\n\(text)")
        XCTAssertTrue(text.contains("2.000s"), "decode failure at +2s:\n\(text)")
    }

    /// Trouble is marked in the left margin, so scanning for it does not mean
    /// reading every line.
    func testSeverityIsMarkedInTheMargin() throws {
        let text = DiagnosticsExport.renderTimeline(twoSidedTimeline())
        let decodeLine = try XCTUnwrap(
            text.split(separator: "\n").first { $0.contains("decode.failed") })
        XCTAssertTrue(decodeLine.hasPrefix("!"), "warning not marked: \(decodeLine)")
    }

    /// Fields render sorted, so comparing two occurrences of one event shows
    /// only the value that actually differs.
    func testFieldsRenderSortedAndUnambiguously() {
        let rendered = DiagnosticsExport.renderFields([
            "zeta": .int(1), "alpha": .string("two words"), "mid": .bool(true)
        ])
        XCTAssertEqual(rendered, "alpha=\"two words\" mid=true zeta=1")
    }

    /// A value containing a newline would SPLIT one event across several lines
    /// in a format that is one-event-per-line — silently turning a readable
    /// trace into one that appears to contain events nothing recorded. Captured
    /// log lines and error descriptions contain newlines routinely.
    func testFieldValuesAreEscapedSoOneEventStaysOneLine() {
        let rendered = DiagnosticsExport.renderFields([
            "text": .string("line one\nline two"),
            "quoted": .string("he said \"no\""),
            "tabbed": .string("a\tb")
        ])
        XCTAssertFalse(rendered.contains("\n"), rendered)
        XCTAssertFalse(rendered.contains("\t"), rendered)
        XCTAssertTrue(rendered.contains("\\n"), rendered)
    }

    /// A value needing escapes is quoted, so the escapes are unambiguous.
    func testEscapedValuesAreQuoted() {
        let rendered = DiagnosticsExport.renderFields(["k": .string("a\nb")])
        XCTAssertEqual(rendered, "k=\"a\\nb\"")
    }

    /// Ordinary values keep their unquoted shape — escaping must not make the
    /// common line noisier.
    func testOrdinaryValuesAreNotQuoted() {
        XCTAssertEqual(
            DiagnosticsExport.renderFields(["addr": .string("100.64.0.3")]), "addr=100.64.0.3")
    }

    /// A name that already exists gains a suffix rather than replacing the
    /// file — for a feature whose job is preserving evidence, a silent
    /// overwrite is the worst possible rounding error.
    func testUniqueFilenameAvoidsAnExistingOne() {
        let taken: Set<String> = [
            DiagnosticsExport.filename(role: .sharer, device: "mac", at: epoch)
        ]
        let next = DiagnosticsExport.uniqueFilename(
            role: .sharer, device: "mac", at: epoch, existsAtPath: { taken.contains($0) })

        XCTAssertFalse(taken.contains(next))
        XCTAssertTrue(next.hasSuffix(".jsonl"))
        XCTAssertTrue(next.contains("-2."), next)
    }

    /// With nothing in the way it is the plain name.
    func testUniqueFilenameIsThePlainNameWhenFree() {
        XCTAssertEqual(
            DiagnosticsExport.uniqueFilename(
                role: .sharer, device: "mac", at: epoch, existsAtPath: { _ in false }),
            DiagnosticsExport.filename(role: .sharer, device: "mac", at: epoch))
    }

    /// An empty collection says so rather than rendering an empty file that
    /// reads as a session where nothing went wrong.
    func testEmptyTimelineSaysSo() {
        let text = DiagnosticsExport.renderTimeline(DiagnosticsMerge.merge([]))
        XCTAssertTrue(text.contains("No diagnostic events"))
    }

    /// The clock note reaches the rendered output. A correction the reader
    /// cannot see is as misleading as the skew it corrected.
    func testClockNotesAppearInTheRenderedOutput() {
        let sharerEvents = [
            DiagnosticEvent(
                seq: 1, monotonicNs: 0, wallClock: epoch, role: .sharer,
                category: .media, name: DiagnosticEventName.captureStarted.rawValue,
                severity: .info, fields: [:])
        ]
        let strangerEvents = [
            DiagnosticEvent(
                seq: 1, monotonicNs: 0, wallClock: epoch, role: .viewer,
                category: .handshake, name: DiagnosticEventName.helloSent.rawValue,
                severity: .info, fields: [:])
        ]
        func bundle(
            _ role: DiagnosticRole, _ device: String, _ events: [DiagnosticEvent]
        ) -> DiagnosticsBundle {
            DiagnosticsBundle.make(
                from: DiagnosticsSnapshot(
                    role: role, deviceLabel: device, wasRecording: true,
                    startedAt: epoch, droppedCount: 0, events: events),
                environment: DiagnosticsEnvironment(
                    platform: "test", appVersion: "0.10.0", commit: "abc1234",
                    configuration: "release", architecture: "arm64", deviceLabel: device))
        }
        let timeline = DiagnosticsMerge.merge([
            bundle(.sharer, "a-mac", sharerEvents),
            bundle(.viewer, "b-pc", strangerEvents)
        ])
        let text = DiagnosticsExport.renderTimeline(timeline)
        XCTAssertTrue(text.contains("Clock alignment:"))
        XCTAssertTrue(text.contains("no handshake"))
    }
}
