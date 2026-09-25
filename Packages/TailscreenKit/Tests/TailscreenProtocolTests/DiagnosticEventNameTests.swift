import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticEventName` — the registry, pinned the way the wire bytes are
/// pinned by `WireByteRegistryTests`.
///
/// A recorded event name is an interface to a reader outside this codebase: an
/// agent matching `hello.ack.sent`, a saved filter on `action.`, the merge in
/// `DiagnosticsMerge` pairing sends with receives. Renaming a case breaks all
/// three, and **nothing at the call site would show it** — the code still
/// compiles, still records, still reads correctly in English. So the names are
/// asserted literally here: changing one means changing this file, which is
/// the moment to ask whether old bundles just became unreadable.
final class DiagnosticEventNameTests: XCTestCase {

    /// The names the merge itself depends on. If one of these moves, cross-
    /// side correlation silently stops working — bundles still parse, the
    /// timeline still renders, and the clock correction quietly never applies.
    func testMergeCriticalNamesAreExact() {
        XCTAssertEqual(DiagnosticEventName.helloSent.rawValue, "hello.sent")
        XCTAssertEqual(DiagnosticEventName.helloReceived.rawValue, "hello.received")
        XCTAssertEqual(DiagnosticEventName.helloAckSent.rawValue, "hello.ack.sent")
        XCTAssertEqual(DiagnosticEventName.helloAckReceived.rawValue, "hello.ack.received")
    }

    /// **The registry itself**, as a literal list, exactly as
    /// `WireByteRegistryTests` pins the wire bytes.
    ///
    /// Uniqueness alone does not pin anything — a duplicate raw value is
    /// already a compile error, so a suite that only checks for duplicates
    /// passes happily while a name is renamed or deleted underneath it. That
    /// is the failure mode this contract exists to prevent: a rename still
    /// compiles, still records, still reads correctly in English, and breaks
    /// every saved query and every old bundle.
    ///
    /// So changing this list is the deliberate act. Adding a case means adding
    /// a line here; a rename or a removal means editing one, which is the
    /// moment to ask whether bundles already in the wild just became
    /// unreadable. Retiring an event is fine — stop recording it, keep the
    /// line.
    func testRegistryContentsArePinned() {
        let expected: Set<String> = [
            "recording.started", "recording.stopped", "recording.exported",
            "node.bringup.started", "node.bringup.ready", "node.bringup.failed",
            "node.signin.url_issued", "node.signin.completed", "node.stopped",
            "peer.discovery.completed", "node.phase.changed",
            "link.enabled", "link.disabled", "link.rotated",
            "link.guest.joined", "link.guest.evicted",
            "hello.sent", "hello.ack.received", "hello.pending.received",
            "hello.denied.received", "hello.server_bye.received",
            "hello.received", "hello.ack.sent", "hello.pending.sent",
            "hello.denied.sent", "hello.bye.received",
            "viewer.admitted", "viewer.approved", "viewer.denied",
            "viewer.expelled", "viewer.pre_approved", "viewer.policy.applied",
            "viewer.disconnected",
            "share.phase.changed", "viewer.session.phase.changed",
            "capture.started", "capture.stopped", "capture.restarted",
            "capture.failed", "capture.source.changed",
            "encode.codec.selected", "encode.bitrate.changed",
            "encode.frame_interval.changed", "encode.keyframe.forced",
            "encode.bit_depth.downgraded",
            "decode.first_frame", "decode.failed", "decode.recovery.action",
            "render.size.changed", "video.stalled",
            "transport.summary", "fec.armed", "fec.disarmed",
            "congestion.armed", "transport.receive_loop.failed",
            "annotation.summary",
            "audio.devices.changed", "audio.summary",
            "mic.attached", "mic.detached", "mic.failed", "mic.mute.changed",
            "system_audio.started", "system_audio.stopped", "voice.ssrc.assigned",
            "control.requested", "control.granted", "control.denied",
            "control.revoked", "control.released",
            "action.share.start", "action.share.stop", "action.connect",
            "action.disconnect", "action.viewer.approve", "action.viewer.deny",
            "action.viewer.block", "action.viewer.kick", "action.mic.toggle",
            "action.audio_device.selected", "action.system_audio.toggle",
            "action.link.toggle", "action.link.rotate",
            "action.control.request", "action.control.grant",
            "action.control.deny", "action.control.revoke",
            "action.annotation.stroke", "action.annotation.cleared",
            "action.setting.changed", "action.account.switched",
            "action.share_request.sent", "action.share_request.answered",
            "view.shown", "view.hidden",
            "permission.prompted", "permission.resolved",
            "fault.surfaced", "notice.shown", "log.line"
        ]
        let actual = Set(DiagnosticEventName.allCases.map(\.rawValue))

        XCTAssertEqual(
            actual.subtracting(expected), [],
            "new event name(s) — add them to this list in the same commit")
        XCTAssertEqual(
            expected.subtracting(actual), [],
            "event name(s) renamed or removed — old bundles reference these")
        XCTAssertEqual(DiagnosticEventName.allCases.count, expected.count)
    }

    /// The shape a reader relies on when filtering by prefix: lowercase,
    /// dot-separated, at least two segments, no whitespace.
    func testNamesFollowTheNamingRule() {
        for name in DiagnosticEventName.allCases {
            let raw = name.rawValue
            XCTAssertEqual(raw, raw.lowercased(), "\(raw) is not lowercase")
            XCTAssertFalse(raw.contains(" "), "\(raw) contains whitespace")
            XCTAssertGreaterThanOrEqual(
                raw.split(separator: ".").count, 2, "\(raw) needs a subject and a verb")
            XCTAssertFalse(raw.hasPrefix("."), "\(raw) starts with a separator")
            XCTAssertFalse(raw.hasSuffix("."), "\(raw) ends with a separator")
        }
    }

    /// Every user action is reachable by the `action.` prefix filter, which is
    /// the first thing anyone reading a bundle does — "what did the person
    /// actually do?" An action event that does not carry the prefix is
    /// invisible to that filter while looking perfectly fine in the file.
    func testActionCategoryAndPrefixAgree() {
        for name in DiagnosticEventName.allCases {
            if name.category == .action {
                XCTAssertTrue(
                    name.rawValue.hasPrefix("action."),
                    "\(name.rawValue) is an action but does not carry the prefix")
            }
            if name.rawValue.hasPrefix("action.") {
                XCTAssertEqual(
                    name.category, .action,
                    "\(name.rawValue) carries the action prefix but is filed elsewhere")
            }
        }
    }

    /// Every case resolves to a category and a severity. The `switch` in
    /// `category` is exhaustive so this cannot regress silently, but a new
    /// case added to a `default` arm by accident would land everything in one
    /// bucket — this asserts the spread is real.
    func testEveryCategoryIsUsed() {
        let used = Set(DiagnosticEventName.allCases.map(\.category))
        for category in DiagnosticCategory.allCases {
            XCTAssertTrue(used.contains(category), "no event is filed under \(category)")
        }
    }

    /// Failures default to `error` and are not left at `info`, where a reader
    /// scanning for trouble would skip them.
    func testFailureEventsDefaultToError() {
        for name in [
            DiagnosticEventName.nodeBringUpFailed, .captureFailed, .micFailed,
            .receiveLoopFailed, .faultSurfaced
        ] {
            XCTAssertEqual(name.defaultSeverity, .error, "\(name.rawValue)")
        }
    }

    /// Severity ordering, which the export filter and any "errors only" view
    /// depend on.
    func testSeverityOrders() {
        XCTAssertLessThan(DiagnosticSeverity.info, .warning)
        XCTAssertLessThan(DiagnosticSeverity.warning, .error)
        XCTAssertEqual(DiagnosticSeverity.allCases.max(), .error)
    }
}
