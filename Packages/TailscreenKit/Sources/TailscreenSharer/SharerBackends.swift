import Foundation
import TailscreenProtocol

// The two host-supplied backends the sharer data plane runs on: something
// that captures and encodes the screen, and (optionally) something that can
// inject a remote viewer's input.
//
// `TailscaleScreenShareServer` owns everything *between* them — admission,
// fan-out, NACK/FEC/retransmit, congestion/fairness, the idle sweep, the
// grant gate — none of it platform-specific. These protocols are the whole
// platform surface, shaped like ``CaptureHelperWire``'s `OutType`/`InType`
// (the macOS capture helper's existing pipe wire).

// MARK: - Capture + encode

/// A source of encoded video (and optionally system audio) for one share
/// session: the sharer's equivalent of the viewer's ``VideoDecoding``.
///
/// The contract is the congestion controller's three levers (set-bitrate,
/// force-keyframe, set-frame-interval) plus AVCC access units with in-band
/// parameter sets; how a backend captures/encodes is its own business.
///
/// **Threading.** Callbacks fire on whatever thread the backend produces on
/// — implementations must not assume a serial queue or the main actor.
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
    /// ``onEncoderResolution`` — the server picks the adaptive-bitrate
    /// bits-per-pixel figure from the cached codec, so resolution-first would
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

    /// The backend died without being asked to stop. The string describes
    /// how — classified via
    /// ``TailscaleScreenShareServer/classifyHelperExit(reason:)`` into a
    /// retryable crash, a permanent failure, or the expected
    /// shared-window-closed case.
    var onUnexpectedExit: ((String) -> Void)? { get set }

    /// The user stopped capture through a platform affordance outside the app
    /// (macOS Control Center's Stop button; a portal's revoke). Distinct from
    /// ``onUnexpectedExit`` so the server tears the share down quietly instead
    /// of respawning.
    var onUserStopped: (() -> Void)? { get set }

    /// Fires on every message from the backend, including a periodic
    /// heartbeat. The server's watchdog uses it as a liveness tick — a
    /// wedged-but-alive capture stream stops firing this, which process-death
    /// detection alone can't catch. Fire per delivered frame if no
    /// independent heartbeat exists.
    var onActivity: (() -> Void)? { get set }

    /// Start capturing. `selectionData` is the JSON-encoded
    /// ``PickerSelection``; the backend resolves those IDs itself.
    /// `forceH264` is the codec-fallback latch a viewer's CODEC_NO sets;
    /// `qualityEnv` is ``QualitySettings/helperEnvironment()`` (a string map
    /// — passed as child-process env on macOS; backends may ignore keys).
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
/// Supplying an injector is what makes the sharer advertise
/// ``ScreenShareCaps/remoteControl`` — passing `nil` makes viewers correctly
/// hide their Request Control affordance.
///
/// The server gates *which* events reach an injector
/// (``RemoteControlPolicy/shouldInject(grantedConnectionID:eventConnectionID:)``
/// plus a rate ceiling); the injector owns the platform half.
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
