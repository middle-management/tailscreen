import Foundation
import SwiftCrossUI
import TailscreenL10n

// Targeted imports: importing all of TailscreenProtocol would collide with
// SwiftCrossUI's own `Published`/`ObservableObject` shims (Combine is absent
// on Linux).
import struct TailscreenProtocol.Annotation
import enum TailscreenProtocol.AnnotationTool
import struct TailscreenProtocol.VideoColorInfo
import enum TailscreenProtocol.ViewerSessionEndReason
import enum TailscreenProtocol.ViewerSessionPhase

/// Observable UI state for the viewer chrome (placards, stats overlay).
/// Updated from the transport/sink; all mutation is dispatched to the main
/// thread, since swift-cross-ui reactivity (like the GLArea) is main-thread.
public final class ViewerUIState: ObservableObject, @unchecked Sendable {
    /// True once the first decoded frame has been shown — hides the connecting
    /// placard and reveals the video.
    @Published public var hasVideo = false

    /// Short human-readable connection status shown on the placard before video
    /// flows ("Connecting…", "Waiting for the sharer to accept…", etc.).
    @Published public var status = L("Connecting…")

    /// A non-modal notice about a still-RUNNING session — rendered as a strip
    /// above the video by `ViewerNoticeBanner`, never in place of it. Nil when
    /// there's nothing to say. Not a `sessionPhase` case: this is a remark
    /// about a session still `viewing`, not a state it's in.
    @Published public var notice: String?

    /// True once the sharer's HELLO_ACK advertised `ScreenShareCaps.remoteControl`
    /// (bit3) — the viewer only offers Request Control then, matching the mac
    /// viewer (a non-injection sharer omits the bit and we hide the affordance).
    @Published public var remoteControlAvailable = false

    /// True once the sharer advertised `ScreenShareCaps.annotations` (bit4) —
    /// gates the annotation toolbar (the drawing surface itself is a follow-up).
    @Published public var annotationsAvailable = false

    /// True once the sharer advertised `ScreenShareCaps.openLink` (bit6) —
    /// gates "Open Link on Sharer…". Never auto-opens anything on its own;
    /// the sharer's own click is the only thing that opens a link.
    @Published public var openLinkAvailable = false

    /// Whether the inline "send a link" composer is open.
    @Published public var openLinkComposerOpen = false
    /// The composer's text field contents.
    @Published public var openLinkText = ""
    /// Set when Send is pressed on something `OpenLinkPayload.isAcceptable`
    /// rejects; shown inline rather than as an alert since it's a validation
    /// error, not a failure.
    @Published public var openLinkError: String?
    /// True right after a link is sent, replacing the composer with a
    /// confirmation line until it's opened again.
    @Published public var openLinkSent = false

    /// Remote-control lifecycle for the toolbar: idle → requested → active, plus
    /// a transient revoked reason. Drives the button label + a small status line.
    @Published public var controlState: ControlState = .idle

    public enum ControlState: Equatable, Sendable {
        case idle
        case requested
        case active
        case revoked(reason: String)
    }

    /// Where the current session is in its lifecycle — drives the connection
    /// placard shown over/instead of video (connecting → awaiting approval →
    /// viewing, or ended / failed with the reason).
    @Published public var sessionPhase: SessionPhase = .connecting

    public typealias SessionPhase = ViewerSessionPhase

    /// Why an ended session ended, split by admission context (transport's
    /// `deniedOrKicked` + `wasAdmitted` → `declined` / `disconnectedBySharer`
    /// at the mapping site). Shared with `HubSessionEndReason`.
    public typealias EndReason = ViewerSessionEndReason

    /// True for the states that render over the frozen frame even though
    /// `hasVideo` is still set.
    public var sessionIsOver: Bool {
        switch sessionPhase {
        case .ended, .failed: return true
        default: return false
        }
    }

    /// Live video stats for the HUD overlay. Network stats (bitrate/loss)
    /// need portable `ViewerSession` counters — a follow-up.
    @Published public var fps = 0
    @Published public var videoWidth = 0
    @Published public var videoHeight = 0
    /// e.g. `"BT.709 · limited"`. Empty until the first stats window closes;
    /// the HUD keys off that to hide the line rather than show "unknown".
    @Published public var videoColorLabel = ""
    /// Whether the stats HUD is shown (toggled from the control bar).
    @Published public var showStats = false

    /// Whether this machine opened a capture device — decides whether the mic
    /// control exists at all (absent, not present-and-inert, when false).
    @Published public var micAvailable = false
    /// Starts off: joining a share must never put somebody on the air.
    @Published public var micOn = false
    /// Set once the device has gone away mid-session.
    @Published public var micFailure: String?

    /// Annotation toolbar state (shown only when the sharer advertised
    /// `ScreenShareCaps.annotations`): the armed drawing tool, or nil when
    /// drawing is off (so drags zoom/pan or drive remote control).
    @Published public var activeTool: AnnotationTool?

    /// True when captured input should reach the sharer: a grant is live AND
    /// no annotation tool is armed. One spelling of the rule shared by
    /// `InputForwarder` and the video view's wheel handler, so they can't
    /// disagree. Drawing wins over controlling: GTK fans each event to every
    /// attached controller, so without this a pen-armed drag would both draw
    /// and drag the sharer's desktop.
    public var forwardsRemoteInput: Bool {
        controlState == .active && activeTool == nil
    }

    /// The color this viewer draws in — a published MIRROR of
    /// `AnnotationStore.color`, which stays the source of truth the capture
    /// path reads. Published so the toolbar swatch re-renders when a color is
    /// picked from its menu; nil until a pick, and the host falls back to the
    /// store's identity-derived default.
    @Published public var inkColor: Annotation.RGBA?

    public init() {}

    /// True from the moment a viewing session starts until it ends and the UI
    /// returns to the picker. Distinguishes "connecting / awaiting approval"
    /// (show the session placard) from "browsing the screen list".
    @Published public var inSession = false

    /// Move the session lifecycle on the main thread (safe from any thread).
    public func post(sessionPhase newPhase: SessionPhase) {
        DispatchQueue.main.async { self.sessionPhase = newPhase }
    }

    /// Set the in-session flag on the main thread.
    public func post(inSession active: Bool) {
        DispatchQueue.main.async { self.inSession = active }
    }

    /// True once the user asked to end the session. Polled by the transport's
    /// `shouldClose`; reset by `beginSession` before the session task starts
    /// polling, so a stale request can't end the next session at birth.
    @Published public private(set) var closeRequested = false

    /// Ask the live session to end (safe from any thread). The transport
    /// notices on its next `shouldClose` poll and unwinds cleanly — this is
    /// the viewer-side counterpart of the sharer's Stop, not a teardown.
    public func requestSessionClose() {
        DispatchQueue.main.async { self.closeRequested = true }
    }

    /// Enter a fresh session: in-session, connecting, no video, control reset.
    public func beginSession() {
        DispatchQueue.main.async {
            self.inSession = true
            self.hasVideo = false
            self.notice = nil
            self.sessionPhase = .connecting
            self.controlState = .idle
            self.closeRequested = false
        }
    }

    /// Tear the session UI back down to the picker: clear video, caps, control,
    /// and stats. Called when a session ends / is declined.
    public func returnToPickerState() {
        DispatchQueue.main.async {
            self.hasVideo = false
            self.inSession = false
            self.notice = nil
            self.remoteControlAvailable = false
            self.annotationsAvailable = false
            self.openLinkAvailable = false
            self.openLinkComposerOpen = false
            self.openLinkText = ""
            self.openLinkError = nil
            self.openLinkSent = false
            self.controlState = .idle
            self.sessionPhase = .connecting
            self.closeRequested = false
            self.micAvailable = false
            self.micOn = false
            self.micFailure = nil
            self.fps = 0
            self.videoWidth = 0
            self.videoHeight = 0
            self.videoColorLabel = ""
            self.activeTool = nil
        }
    }

    /// Publish the latest fps + resolution + colour encoding on the main thread.
    public func post(fps newFps: Int, width: Int, height: Int, color: VideoColorInfo) {
        let label = color.shortLabel
        DispatchQueue.main.async {
            self.fps = newFps
            self.videoWidth = width
            self.videoHeight = height
            self.videoColorLabel = label
        }
    }

    /// Publish a status change on the main thread (safe to call from anywhere).
    public func post(status newStatus: String) {
        DispatchQueue.main.async { self.status = newStatus }
    }

    /// Mark video as flowing and clear any notice — the sink's first-frame
    /// latch re-arms on a stall, so the next decoded frame lands here and
    /// removes the banner by itself.
    public func markVideoFlowing() {
        DispatchQueue.main.async {
            self.hasVideo = true
            self.notice = nil
        }
    }

    /// Record the sharer's advertised capabilities (from admission) on the main
    /// thread. `remoteControl` / `annotations` / `openLink` are the
    /// sharer-only bits the viewer gates its chrome on.
    public func setCaps(remoteControl: Bool, annotations: Bool, openLink: Bool) {
        DispatchQueue.main.async {
            self.remoteControlAvailable = remoteControl
            self.annotationsAvailable = annotations
            self.openLinkAvailable = openLink
        }
    }

    /// Publish the microphone's availability on the main thread. Called once
    /// the transport has built a voice uplink for this session.
    public func setMicAvailable(_ available: Bool) {
        DispatchQueue.main.async {
            self.micAvailable = available
            if !available {
                self.micOn = false
            }
        }
    }

    /// Video decoding has fatally stalled (the escalation ladder's terminal
    /// rung). Says so without taking the picture away — unless no frame has
    /// ever been shown (`hasVideo` false), in which case there's no picture to
    /// keep and the session fails outright, as a connecting spinner that will
    /// never resolve.
    public func noteVideoStalled(_ message: String) {
        DispatchQueue.main.async {
            if self.hasVideo {
                self.notice = message
            } else {
                self.sessionPhase = .failed(message)
            }
        }
    }

    /// The capture device went away mid-session. Both flags move together:
    /// leaving `micOn` true would show a live mic recording nothing.
    public func noteMicFailure(_ message: String) {
        DispatchQueue.main.async {
            self.micOn = false
            self.micAvailable = false
            self.micFailure = message
        }
    }

    /// Move the remote-control state machine on the main thread (safe from the
    /// back-channel's task).
    public func setControlState(_ newState: ControlState) {
        DispatchQueue.main.async { self.controlState = newState }
    }
}
