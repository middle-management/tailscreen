import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticsExport` — the filenames, the write, and the rendered timeline.
/// The renderer is pinned because the bundle is what gets sent but the
/// timeline is what gets read; its failure mode is an unscannable wall of text.
final class DiagnosticsExportTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Filenames

    /// Role and device are in the name because these files arrive in pairs,
    /// renamed, in a chat thread — two `diagnostics.jsonl` don't survive that.
    func testFilenameNamesTheSideItCameFrom() {
        let name = DiagnosticsExport.filename(
            role: .sharer, device: "Robert's MacBook Pro", at: epoch)

        XCTAssertTrue(name.hasPrefix("tailscreen-sharer-roberts-macbook-pro-"))
        XCTAssertTrue(name.hasSuffix(".jsonl"))
    }

    func testTimestampsSortChronologically() {
        let earlier = DiagnosticsExport.stamp(epoch)
        let later = DiagnosticsExport.stamp(epoch.addingTimeInterval(3600))
        XCTAssertLessThan(earlier, later)
    }

    /// The slug has to be safe on Windows too, which rejects `<>:"/\|?*`.
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

    func testFullyNonASCIINameStillYieldsAName() {
        XCTAssertEqual(DiagnosticsExport.slug("日本語"), "device")
        XCTAssertEqual(DiagnosticsExport.slug(""), "device")
    }

    /// The 40-character cap runs BEFORE the final trim — capping after it
    /// could hand back a trailing dash the trim exists to prevent.
    func testSlugCapDoesNotLeaveATrailingDash() {
        let slug = DiagnosticsExport.slug(String(repeating: "a", count: 39) + " workstation")

        XCTAssertFalse(slug.hasSuffix("-"), slug)
        XCTAssertLessThanOrEqual(slug.count, 40)
        XCTAssertEqual(slug, String(repeating: "a", count: 39))
    }

    func testSlugKeepsANameThatExactlyFitsTheCap() {
        let exact = String(repeating: "b", count: 40)
        XCTAssertEqual(DiagnosticsExport.slug(exact), exact)
    }

    private func line(
        device: String, _ name: DiagnosticEventName, at offset: TimeInterval
    ) -> DiagnosticsMerge.Line {
        let moment = epoch.addingTimeInterval(offset)
        return DiagnosticsMerge.Line(
            device: device,
            role: .viewer,
            event: DiagnosticEvent(
                seq: 1, monotonicNs: UInt64(max(0, offset) * 1_000_000_000),
                wallClock: moment, role: .viewer, category: name.category,
                name: name.rawValue, severity: name.defaultSeverity),
            originalWallClock: moment,
            appliedOffsetSeconds: 0)
    }

    /// The gap reaches the rendered output, inline AND in the header — a
    /// total alone wouldn't tell a reader whether the hole is near the two
    /// events they're comparing.
    func testDroppedEventsAreMarkedWhereTheyHappened() throws {
        let timeline = DiagnosticsMerge.Timeline(
            lines: [
                line(device: "pc", .helloSent, at: 0),
                line(device: "pc", .transportSummary, at: 30)
            ],
            referenceDevice: "pc",
            clockNotes: [],
            gaps: [
                DiagnosticsMerge.Gap(
                    device: "pc", missing: 39, at: epoch.addingTimeInterval(30))
            ])
        let rendered = DiagnosticsExport.renderTimeline(timeline)
        let rows = rendered.split(separator: "\n").map(String.init)

        XCTAssertTrue(rendered.contains("Dropped: 39 event(s) in 1 gap(s)"), rendered)
        let gapRow = try XCTUnwrap(rows.firstIndex { $0.contains("dropped here") }, rendered)
        let followingRow = try XCTUnwrap(
            rows.firstIndex { $0.contains("transport.summary") }, rendered)
        XCTAssertEqual(
            gapRow + 1, followingRow,
            "the marker belongs immediately before the first surviving event")
        XCTAssertTrue(rows[gapRow].contains("pc"), rows[gapRow])
    }

    /// A session boundary is marked where one share gives way to the next,
    /// or the stream reads as one long run.
    func testSessionBoundaryIsMarked() throws {
        var second = line(device: "pc", .helloSent, at: 30)
        second.event.session = 1
        let rendered = DiagnosticsExport.renderTimeline(
            DiagnosticsMerge.Timeline(
                lines: [line(device: "pc", .helloSent, at: 0), second],
                referenceDevice: "pc",
                clockNotes: []))
        let rows = rendered.split(separator: "\n").map(String.init)

        let marker = try XCTUnwrap(
            rows.firstIndex { $0.contains("session 1 begins") }, rendered)
        let following = try XCTUnwrap(
            rows.lastIndex { $0.contains("hello.sent") }, rendered)
        XCTAssertEqual(marker + 1, following)
    }

    func testASingleSessionRendersNoBoundary() {
        let rendered = DiagnosticsExport.renderTimeline(
            DiagnosticsMerge.Timeline(
                lines: [
                    line(device: "pc", .helloSent, at: 0),
                    line(device: "pc", .helloAckReceived, at: 1)
                ],
                referenceDevice: "pc",
                clockNotes: []))

        XCTAssertFalse(rendered.contains("session"), rendered)
    }

    func testACompleteTimelineRendersNoGapNotice() {
        let rendered = DiagnosticsExport.renderTimeline(
            DiagnosticsMerge.Timeline(
                lines: [line(device: "pc", .helloSent, at: 0)],
                referenceDevice: "pc",
                clockNotes: []))

        XCTAssertFalse(rendered.contains("Dropped:"), rendered)
        XCTAssertFalse(rendered.contains("dropped here"), rendered)
    }

    // MARK: - Writing

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

    func testTimelineRendersOneAlignedLinePerEvent() {
        let text = DiagnosticsExport.renderTimeline(twoSidedTimeline())
        let body = text.split(separator: "\n").filter { $0.contains("hello.") || $0.contains("capture.") }

        XCTAssertEqual(body.count, 5)
        let deviceColumns = body.map { line -> Int in
            line.distance(
                from: line.startIndex,
                to: line.firstIndex(where: { $0.isLetter }) ?? line.startIndex)
        }
        XCTAssertEqual(Set(deviceColumns).count, 1, "columns are not aligned:\n\(text)")
    }

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

    func testTimesAreRelativeToTheFirstEvent() {
        let text = DiagnosticsExport.renderTimeline(twoSidedTimeline())
        XCTAssertTrue(text.contains("0.000s"), "first event should read zero:\n\(text)")
        XCTAssertTrue(text.contains("2.000s"), "decode failure at +2s:\n\(text)")
    }

    func testSeverityIsMarkedInTheMargin() throws {
        let text = DiagnosticsExport.renderTimeline(twoSidedTimeline())
        let decodeLine = try XCTUnwrap(
            text.split(separator: "\n").first { $0.contains("decode.failed") })
        XCTAssertTrue(decodeLine.hasPrefix("!"), "warning not marked: \(decodeLine)")
    }

    func testFieldsRenderSortedAndUnambiguously() {
        let rendered = DiagnosticsExport.renderFields([
            "zeta": .int(1), "alpha": .string("two words"), "mid": .bool(true)
        ])
        XCTAssertEqual(rendered, "alpha=\"two words\" mid=true zeta=1")
    }

    /// A raw newline would split one event across lines in a one-event-per-line
    /// format, appearing to contain events nothing recorded.
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

    func testEscapedValuesAreQuoted() {
        let rendered = DiagnosticsExport.renderFields(["k": .string("a\nb")])
        XCTAssertEqual(rendered, "k=\"a\\nb\"")
    }

    func testOrdinaryValuesAreNotQuoted() {
        XCTAssertEqual(
            DiagnosticsExport.renderFields(["addr": .string("100.64.0.3")]), "addr=100.64.0.3")
    }

    /// A name that already exists gains a suffix rather than replacing the
    /// file — a silent overwrite is unacceptable for evidence.
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

    func testUniqueFilenameIsThePlainNameWhenFree() {
        XCTAssertEqual(
            DiagnosticsExport.uniqueFilename(
                role: .sharer, device: "mac", at: epoch, existsAtPath: { _ in false }),
            DiagnosticsExport.filename(role: .sharer, device: "mac", at: epoch))
    }

    func testEmptyTimelineSaysSo() {
        let text = DiagnosticsExport.renderTimeline(DiagnosticsMerge.merge([]))
        XCTAssertTrue(text.contains("No diagnostic events"))
    }

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
