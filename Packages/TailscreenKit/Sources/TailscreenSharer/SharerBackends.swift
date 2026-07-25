import Foundation
import TailscreenProtocol

// The two host-supplied backends the sharer data plane runs on: something
// that captures and encodes the screen, and (optionally) something that can
// inject a remote viewer's input.
//
// `TailscaleScreenShareServer` owns everything *between* them — admission,
// fan-out, NACK/FEC/retransmit, congestion and fairness control, the idle
// sweep, the grant gate — and none of that is platform-specific. These
// protocols are the whole platform surface, and they're deliberately shaped
// like ``CaptureHelperWire``'s `OutType`/`InType`, which is what the macOS
// capture helper already speaks over its pipe. The seam isn't new; it was
// designed years ago as an IPC wire and simply never named as a portability
// boundary.

// MARK: - Capture + encode

/// A source of encoded video (and optionally system audio) for one share
/// session: the sharer's equivalent of the viewer's ``VideoDecoding``.
///
/// The contract is deliberately the capture-helper command set — the
/// porting plan's rule that "the congestion controller's contract is
/// portable (set-bitrate, force-keyframe, set-frame-interval)". A backend
/// that can honour those three levers and emit AVCC access units with
/// in-band parameter sets is a complete implementation; how it captures
/// (ScreenCaptureKit in a helper subprocess, PipeWire via the ScreenCast
/// portal, X11/XCB, Windows.Graphics.Capture) and how it encodes
/// (VideoToolbox, VA-API, x264) is entirely the backend's business.
///
/// **Threading.** Callbacks fire on whatever thread the backend produces on —
/// the macOS helper wrapper uses a dedicated reader thread — so the server
/// treats every one of them as arbitrary-thread and locks accordingly.
/// Implementations must not assume a serial queue or the main actor.
public protocol CaptureEncoding: AnyObject, Sendable {
    /// An encoded access unit: `(avccData, isKeyframe)`. **AVCC**
    /// (length-prefixed NALs), not Annex-B — an FFmpeg-based backend converts
    /// on its side, since that is what the RTP payload carries.
    var onAccessUnit: ((Data, Bool) -> Void)? { get set }

    /// An encoded system-audio access unit (a raw Opus packet). The server
    /// packetizes these as RTP PT 99. Backends without system-audio capture
    /// simply never fire this.
    var onAudioAccessUnit: ((Data) -> Void)? { get set }

    /// Codec parameter sets, once per encoder configuration. Fires **before**
    /// ``onEncoderResolution`` — the server caches the codec here and its
    /// resolution handler reads that codec back to pick the bits-per-pixel
    /// figure for the adaptive-bitrate anchor, so resolution-first would
    /// anchor an H.264 session at HEVC's budget.
    var onParameterSets: ((CodecParameterSets) -> Void)? { get set }

    /// Encoded width/height, surfaced once per parameter-sets emit so the
    /// server can anchor its adaptive-bitrate baseline.
    var onEncoderResolution: ((Int, Int) -> Void)? { get set }

    /// A downsampled preview image for the sharer's own UI, as **encoded
    /// bytes** (JPEG from the macOS helper) rather than a decoded image type.
    /// Keeping it opaque is what lets this protocol stay Foundation-only; the
    /// host decodes at the point of display.
    var onPreviewImage: ((Data) -> Void)? { get set }

    /// The backend died without being asked to stop. The string describes how
    /// — the server classifies it via
    /// ``TailscaleScreenShareServer/classifyHelperExit(reason:)`` into a
    /// retryable crash, a permanent failure, or the *expected*
    /// shared-window-closed case.
    var onUnexpectedExit: ((String) -> Void)? { get set }

    /// The user stopped capture through a platform affordance outside the app
    /// (macOS Control Center's Stop button; a portal's revoke). Distinct from
    /// ``onUnexpectedExit`` so the server tears the share down quietly instead
    /// of respawning.
    var onUserStopped: (() -> Void)? { get set }

    /// Fires on *every* message from the backend, including a periodic
    /// heartbeat. The server's watchdog uses it as a liveness tick: a backend
    /// that is alive but no longer producing (a wedged capture stream) stops
    /// firing this, which process-death detection alone can't catch. A backend
    /// with no independent heartbeat should fire it per delivered frame.
    var onActivity: (() -> Void)? { get set }

    /// Start capturing. `selectionData` is the JSON-encoded
    /// ``PickerSelection`` describing what the user picked; the backend
    /// resolves those IDs itself (the macOS helper does so in the child
    /// process, where touching `SCShareableContent` is legal). `forceH264`
    /// is the codec-fallback latch a viewer's CODEC_NO sets; `qualityEnv` is
    /// ``QualitySettings/helperEnvironment()`` — a string map because the
    /// macOS backend passes it as child-process environment, and any backend
    /// may ignore keys it doesn't implement.
    func start(selectionData: Data, forceH264: Bool, qualityEnv: [String: String]) throws

    /// Stop capturing and release the platform's capture resources. Must be
    /// safe to call when never started.
    func stop() async

    /// Force an IDR on the next frame — answers a viewer PLI.
    func requestKeyframe()

    /// Retarget the encoder's bitrate (bits per second): the congestion
    /// controller's primary lever.
    func setBitrate(_ bps: Int)

    /// Gate system-audio *emission*. Separate from whether audio is captured
    /// at all (that rides the selection) so mute/unmute is instant. The server
    /// re-sends the latch after every backend (re)start.
    func setAudioEnabled(_ on: Bool)

    /// Retune the capture frame rate: the congestion controller's second
    /// lever, once bitrate has bottomed out (the 60→30→15 ladder).
    func setFrameInterval(_ fps: Int)
}

// MARK: - Remote-control injection

/// Injects a granted viewer's input on the sharer's machine: `CGEvent` on
/// macOS, `SendInput` on Windows, the RemoteDesktop portal on Linux.
///
/// Supplying an injector to ``TailscaleScreenShareServer`` is what makes the
/// sharer advertise ``ScreenShareCaps/remoteControl``, so a host that can't
/// inject simply passes `nil` and viewers correctly hide their Request
/// Control affordance instead of sending requests into a void. That's a
/// behaviour the macOS-only server could hard-code and a portable one can't.
///
/// The server gates *which* events reach an injector
/// (``RemoteControlPolicy/shouldInject(grantedConnectionID:eventConnectionID:)``
/// plus a rate ceiling); the injector owns the platform half — permission,
/// coordinate mapping, and the revoke seal.
public protocol InputInjecting: AnyObject, Sendable {
    /// Whether this host currently permits injection (macOS Accessibility
    /// TCC; a portal session). A grant is refused rather than installed dead
    /// when this is false.
    func isTrusted() -> Bool

    /// Ask the platform to prompt for injection permission. Returns whether a
    /// prompt could be raised — not whether it was granted, which is
    /// asynchronous and user-driven.
    @discardableResult
    func promptForAccess() -> Bool

    /// Update the shared-content selection the injector maps normalized
    /// `[0,1]` coordinates against, without changing the active/inactive
    /// gate. Called at share start and whenever the source changes mid-share.
    func setSelection(_ selection: PickerSelection?)

    /// Open the gate for a new grantee, against `selection`.
    func activate(selection: PickerSelection?)

    /// Seal the gate. Must drop any event that races the revoke, and release
    /// any button held mid-drag so a revoke can't leave a stuck button.
    func deactivate()

    /// Inject one event. Called only for events the server's gate admitted.
    func apply(_ event: InputEvent)
}

// MARK: - Errors

/// Failures raised by the sharer data plane itself, as opposed to the
/// transport or a backend.
public enum ScreenShareServerError: Error {
    /// A share was started with content to capture, but the host wired no
    /// ``CaptureEncoding`` factory. Headless operation is legitimate — it's
    /// what `filterData: nil` selects — but asking for capture without a
    /// backend is a wiring bug, not a runtime condition.
    case noCaptureBackend
}
