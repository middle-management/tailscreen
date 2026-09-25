import Foundation

/// Every event this app can record, and what each one means. A registry like
/// the wire-byte one: readers match on these strings (agents triaging a
/// bundle, saved query filters, ``DiagnosticsBundle``'s pairing by name), so
/// renaming a case breaks all three silently.
///
/// **Add a case in the same commit as the code that records it, never rename
/// or reuse a shipped one.** `DiagnosticEventNameTests` pins the full set.
/// Retiring an event is fine — stop recording it, keep the case.
///
/// Category and severity are derived here, not passed at the call site, so
/// two call sites can't silently disagree about one event's category.
/// ``DiagnosticsRecorder/record(_:severity:fields:nowNs:wallClock:)`` still
/// takes a severity override for events whose weight depends on outcome.
///
/// Naming: `subject.thing.past-tense-verb`, lowercase, dot-separated,
/// `snake_case` inside a segment. Subject leads so a prefix match filters
/// (`viewer.`, `hello.`). Directional events name the direction last
/// (`.sent`/`.received`), the axis a merged bundle reads along.
public enum DiagnosticEventName: String, Sendable, CaseIterable, Codable {

    // MARK: Recording lifecycle

    /// The recorder began keeping events. Always the first line of a bundle.
    case recordingStarted = "recording.started"
    /// The user (or a host teardown) turned recording off.
    case recordingStopped = "recording.stopped"
    /// A bundle was written out. Recorded *before* the write, so a bundle
    /// always contains the record of its own export.
    case recordingExported = "recording.exported"

    // MARK: Node bring-up, sign-in, discovery

    case nodeBringUpStarted = "node.bringup.started"
    case nodeBringUpReady = "node.bringup.ready"
    case nodeBringUpFailed = "node.bringup.failed"
    /// Interactive login URL produced. The URL itself is **not** recorded —
    /// it is a bearer credential for the tailnet. Only that one was issued.
    case nodeSignInURLIssued = "node.signin.url_issued"
    case nodeSignInCompleted = "node.signin.completed"
    case nodeStopped = "node.stopped"
    case peerDiscoveryCompleted = "peer.discovery.completed"
    /// Node bring-up phase transition (`NodeBringUpPhase`), `from` → `to`.
    case nodePhaseChanged = "node.phase.changed"

    // MARK: Share (by-link / share-by-token) tunnel

    case linkEnabled = "link.enabled"
    case linkDisabled = "link.disabled"
    case linkRotated = "link.rotated"
    case linkGuestJoined = "link.guest.joined"
    case linkGuestEvicted = "link.guest.evicted"

    // MARK: Handshake — viewer side

    case helloSent = "hello.sent"
    case helloAckReceived = "hello.ack.received"
    case helloPendingReceived = "hello.pending.received"
    case helloDeniedReceived = "hello.denied.received"
    case serverByeReceived = "hello.server_bye.received"

    // MARK: Handshake — sharer side

    case helloReceived = "hello.received"
    case helloAckSent = "hello.ack.sent"
    case helloPendingSent = "hello.pending.sent"
    case helloDeniedSent = "hello.denied.sent"
    case byeReceived = "hello.bye.received"

    // MARK: Viewer admission (sharer side)

    /// A viewer entered the fan-out set — the single admission choke point.
    case viewerAdmitted = "viewer.admitted"
    case viewerApproved = "viewer.approved"
    case viewerDenied = "viewer.denied"
    case viewerExpelled = "viewer.expelled"
    case viewerPreApproved = "viewer.pre_approved"
    /// A remembered allow/deny policy decided admission without asking.
    case viewerPolicyApplied = "viewer.policy.applied"
    case viewerDisconnected = "viewer.disconnected"

    // MARK: Session phases

    /// `ShareBringUpPhase` transition, `from` → `to`.
    case sharePhaseChanged = "share.phase.changed"
    /// `ViewerSessionLifecycle` transition, `from` → `to`.
    case viewerSessionPhaseChanged = "viewer.session.phase.changed"

    // MARK: Media — capture and encode (sharer)

    case captureStarted = "capture.started"
    case captureStopped = "capture.stopped"
    case captureRestarted = "capture.restarted"
    case captureFailed = "capture.failed"
    case captureSourceChanged = "capture.source.changed"
    case encodeCodecSelected = "encode.codec.selected"
    case encodeBitrateChanged = "encode.bitrate.changed"
    case encodeFrameIntervalChanged = "encode.frame_interval.changed"
    case encodeKeyframeForced = "encode.keyframe.forced"
    /// 10-bit withheld because an admitted viewer cannot decode it.
    case encodeBitDepthDowngraded = "encode.bit_depth.downgraded"

    // MARK: Media — decode and render (viewer)

    case decodeFirstFrame = "decode.first_frame"
    case decodeFailed = "decode.failed"
    /// The decode-failure escalation ladder moved a rung.
    case decodeRecoveryAction = "decode.recovery.action"
    case renderSizeChanged = "render.size.changed"
    case videoStalled = "video.stalled"

    // MARK: Transport — loss recovery and congestion

    /// Per-window rollup, not per-packet. See ``DiagnosticsTransportSampler``.
    case transportSummary = "transport.summary"
    case fecArmed = "fec.armed"
    case fecDisarmed = "fec.disarmed"
    case congestionArmed = "congestion.armed"
    case receiveLoopFailed = "transport.receive_loop.failed"

    /// Per-window rollup of viewer annotations crossing the framed control
    /// channel, sharer side: ops applied, dropped by the admitted-viewer
    /// gate, relayed on. Recorded only for a window where something
    /// happened, unlike ``transportSummary`` — no ops just means nobody drew.
    case annotationSummary = "annotation.summary"

    // MARK: Audio

    /// The set of audio devices the session can choose from changed — or was
    /// enumerated for the first time. Carries both lists and both selections;
    /// see ``AudioDeviceDiagnostics``.
    case audioDevicesChanged = "audio.devices.changed"
    case micAttached = "mic.attached"
    case micDetached = "mic.detached"
    case micFailed = "mic.failed"
    case micMuteChanged = "mic.mute.changed"
    case systemAudioStarted = "system_audio.started"
    case systemAudioStopped = "system_audio.stopped"
    case voiceSSRCAssigned = "voice.ssrc.assigned"

    /// Per-window rollup of the voice receive path's health — concealment,
    /// overruns, underruns, clamping, jitter — plus what was playing. See
    /// ``DiagnosticsTransportSampler`` for cadence, `VoiceStats.audioSummaryFields`
    /// for the row. Recorded every window audio is running, even if no counter moved.
    case audioSummary = "audio.summary"

    // MARK: Remote control

    case controlRequested = "control.requested"
    case controlGranted = "control.granted"
    case controlDenied = "control.denied"
    case controlRevoked = "control.revoked"
    case controlReleased = "control.released"

    // MARK: User actions

    case actionShareStart = "action.share.start"
    case actionShareStop = "action.share.stop"
    case actionConnect = "action.connect"
    case actionDisconnect = "action.disconnect"
    case actionViewerApprove = "action.viewer.approve"
    case actionViewerDeny = "action.viewer.deny"
    case actionViewerBlock = "action.viewer.block"
    case actionViewerKick = "action.viewer.kick"
    case actionMicToggle = "action.mic.toggle"
    /// The user picked a specific input or output device.
    case actionAudioDeviceSelected = "action.audio_device.selected"
    case actionSystemAudioToggle = "action.system_audio.toggle"
    case actionLinkToggle = "action.link.toggle"
    case actionLinkRotate = "action.link.rotate"
    case actionControlRequest = "action.control.request"
    case actionControlGrant = "action.control.grant"
    case actionControlDeny = "action.control.deny"
    case actionControlRevoke = "action.control.revoke"
    case actionAnnotationStroke = "action.annotation.stroke"
    case actionAnnotationCleared = "action.annotation.cleared"
    case actionSettingChanged = "action.setting.changed"
    case actionAccountSwitched = "action.account.switched"
    case actionShareRequestSent = "action.share_request.sent"
    case actionShareRequestAnswered = "action.share_request.answered"

    // MARK: Views

    /// A UI surface became the one the user is looking at.
    case viewShown = "view.shown"
    /// A surface the user was looking at went away.
    case viewHidden = "view.hidden"
    /// A permission prompt was put in front of the user.
    case permissionPrompted = "permission.prompted"
    case permissionResolved = "permission.resolved"

    // MARK: Faults

    /// A failure was surfaced to the user (the `presentError` funnel). Carries
    /// the stable `TS-…` code so a bundle joins onto the error registry.
    case faultSurfaced = "fault.surfaced"
    /// An informational notice was shown — an expected ending, not a failure.
    case noticeShown = "notice.shown"
    /// A line from the existing `LogSink` plumbing, captured verbatim.
    /// See ``DiagnosticsLogSink``.
    case logLine = "log.line"

    // MARK: - Derived metadata

    /// The subsystem this event belongs to. Derived, never passed — see the
    /// type's doc comment.
    public var category: DiagnosticCategory {
        switch self {
        case .recordingStarted, .recordingStopped, .recordingExported,
            .nodeBringUpStarted, .nodeBringUpReady, .nodeBringUpFailed,
            .nodeSignInURLIssued, .nodeSignInCompleted, .nodeStopped,
            .peerDiscoveryCompleted, .nodePhaseChanged,
            .linkEnabled, .linkDisabled, .linkRotated,
            .linkGuestJoined, .linkGuestEvicted:
            return .network

        case .helloSent, .helloAckReceived, .helloPendingReceived,
            .helloDeniedReceived, .serverByeReceived,
            .helloReceived, .helloAckSent, .helloPendingSent,
            .helloDeniedSent, .byeReceived,
            .viewerAdmitted, .viewerApproved, .viewerDenied, .viewerExpelled,
            .viewerPreApproved, .viewerPolicyApplied, .viewerDisconnected,
            .sharePhaseChanged, .viewerSessionPhaseChanged,
            .controlRequested, .controlGranted, .controlDenied,
            .controlRevoked, .controlReleased:
            return .handshake

        case .captureStarted, .captureStopped, .captureRestarted,
            .captureFailed, .captureSourceChanged,
            .encodeCodecSelected, .encodeBitrateChanged,
            .encodeFrameIntervalChanged, .encodeKeyframeForced,
            .encodeBitDepthDowngraded,
            .decodeFirstFrame, .decodeFailed, .decodeRecoveryAction,
            .renderSizeChanged, .videoStalled:
            return .media

        case .transportSummary, .fecArmed, .fecDisarmed,
            .congestionArmed, .receiveLoopFailed, .annotationSummary:
            return .transport

        case .audioDevicesChanged, .micAttached, .micDetached, .micFailed,
            .micMuteChanged, .systemAudioStarted, .systemAudioStopped,
            .voiceSSRCAssigned, .audioSummary:
            return .audio

        case .actionShareStart, .actionShareStop, .actionConnect,
            .actionDisconnect, .actionViewerApprove, .actionViewerDeny,
            .actionViewerBlock, .actionViewerKick, .actionMicToggle,
            .actionSystemAudioToggle, .actionLinkToggle, .actionLinkRotate,
            .actionControlRequest, .actionControlGrant, .actionControlDeny,
            .actionControlRevoke, .actionAnnotationStroke, .actionAudioDeviceSelected,
            .actionAnnotationCleared, .actionSettingChanged,
            .actionAccountSwitched, .actionShareRequestSent,
            .actionShareRequestAnswered:
            return .action

        case .viewShown, .viewHidden, .permissionPrompted, .permissionResolved:
            return .view

        case .faultSurfaced, .noticeShown, .logLine:
            return .fault
        }
    }

    /// How much this event should pull a reader's eye when nothing at the
    /// call site says otherwise. Only events that are *always* trouble are
    /// `error` — outcome-dependent ones stay `info` and are overridden at the call site.
    public var defaultSeverity: DiagnosticSeverity {
        switch self {
        case .nodeBringUpFailed, .captureFailed, .micFailed,
            .receiveLoopFailed, .faultSurfaced, .videoStalled:
            return .error

        case .decodeFailed, .captureRestarted, .decodeRecoveryAction,
            .encodeBitDepthDowngraded, .helloDeniedReceived,
            .helloDeniedSent, .viewerExpelled, .fecArmed:
            return .warning

        default:
            return .info
        }
    }
}
