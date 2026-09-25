import Foundation
import XCTest

@testable import TailscreenProtocol

/// `DiagnosticEventName` — the registry, pinned the way wire bytes are pinned
/// by `WireByteRegistryTests`. A rename compiles and records fine but silently
/// breaks readers matching on the old string (saved filters, `DiagnosticsMerge`)
/// and makes old bundles unreadable — hence literal assertion here.
final class DiagnosticEventNameTests: XCTestCase {

    /// Names the cross-side merge depends on; if one moves, correlation silently stops working.
    func testMergeCriticalNamesAreExact() {
        XCTAssertEqual(DiagnosticEventName.helloSent.rawValue, "hello.sent")
        XCTAssertEqual(DiagnosticEventName.helloReceived.rawValue, "hello.received")
        XCTAssertEqual(DiagnosticEventName.helloAckSent.rawValue, "hello.ack.sent")
        XCTAssertEqual(DiagnosticEventName.helloAckReceived.rawValue, "hello.ack.received")
    }

    /// The registry itself, as a literal list. Uniqueness alone doesn't pin
    /// anything (a duplicate raw value is already a compile error) — this
    /// catches a rename/removal, which still compiles and records fine but
    /// breaks old bundles. Retiring an event: stop recording it, keep the line.
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

    /// `.action` category and the `action.` prefix must agree, or a bundle
    /// reader filtering by prefix misses events that look fine in the file.
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

    /// Guards against a new case landing in a `default` arm and collapsing everything into one bucket.
    func testEveryCategoryIsUsed() {
        let used = Set(DiagnosticEventName.allCases.map(\.category))
        for category in DiagnosticCategory.allCases {
            XCTAssertTrue(used.contains(category), "no event is filed under \(category)")
        }
    }

    func testFailureEventsDefaultToError() {
        for name in [
            DiagnosticEventName.nodeBringUpFailed, .captureFailed, .micFailed,
            .receiveLoopFailed, .faultSurfaced
        ] {
            XCTAssertEqual(name.defaultSeverity, .error, "\(name.rawValue)")
        }
    }

    func testSeverityOrders() {
        XCTAssertLessThan(DiagnosticSeverity.info, .warning)
        XCTAssertLessThan(DiagnosticSeverity.warning, .error)
        XCTAssertEqual(DiagnosticSeverity.allCases.max(), .error)
    }
}
