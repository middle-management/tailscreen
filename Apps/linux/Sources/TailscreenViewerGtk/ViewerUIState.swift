import Foundation
import SwiftCrossUI
import TailscreenL10n

// Targeted imports: all of TailscreenProtocol would collide with SwiftCrossUI's
// own `Published` / `ObservableObject` (both ship reactive shims on Linux, where
// Combine is absent). Only the tool enum and the color type are needed here.
import struct TailscreenProtocol.Annotation
import enum TailscreenProtocol.AnnotationTool

/// Observable UI state for the viewer chrome (placards, and later the stats
/// overlay). Updated from the transport/sink; the swift-cross-ui view tree
/// observes it and re-renders. Marked to update on the main thread — swift-cross-ui
/// reactivity, like the GLArea, is main-thread.
public final class ViewerUIState: ObservableObject, @unchecked Sendable {
    /// True once the first decoded frame has been shown — hides the connecting
    /// placard and reveals the video.
    @Published public var hasVideo = false

    /// Short human-readable connection status shown on the placard before video
    /// flows ("Connecting…", "Waiting for the sharer to accept…", etc.).
    @Published public var status = L("Connecting…")

    /// True once the sharer's HELLO_ACK advertised `ScreenShareCaps.remoteControl`
    /// (bit3) — the viewer only offers Request Control then, matching the mac
    /// viewer (a non-injection sharer omits the bit and we hide the affordance).
    @Published public var remoteControlAvailable = false

    /// True once the sharer advertised `ScreenShareCaps.annotations` (bit4) —
    /// gates the annotation toolbar (the drawing surface itself is a follow-up).
    @Published public var annotationsAvailable = false

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

    public enum SessionPhase: Equatable, Sendable {
        case connecting
        case awaitingApproval
        case viewing
        case ended(EndReason)
        case failed(String)
    }

    /// Why an ended session ended, already split by admission context (the
    /// transport's `deniedOrKicked` + `wasAdmitted` becomes `declined` or
    /// `disconnectedBySharer` at the mapping site). Mirrors the shared
    /// chrome's `HubSessionEndReason` case for case; two enums because this
    /// module deliberately imports neither the chrome nor the viewer tier.
    public enum EndReason: Equatable, Sendable {
        case sharerStopped
        case timedOut
        case connectionLost
        case declined
        case disconnectedBySharer
    }

    /// True from a session's ended/failed placard — the states that render
    /// over (instead of) the frozen frame even though `hasVideo` is still set.
    public var sessionIsOver: Bool {
        switch sessionPhase {
        case .ended, .failed: return true
        default: return false
        }
    }

    /// Live video stats for the HUD overlay (viewer-side: fps counted at the
    /// sink, resolution from the decoded frame). Network stats (bitrate/loss)
    /// need portable `ViewerSession` counters — a follow-up.
    @Published public var fps = 0
    @Published public var videoWidth = 0
    @Published public var videoHeight = 0
    /// Whether the stats HUD is shown (toggled from the control bar).
    @Published public var showStats = false

    /// Whether this machine opened a capture device for this session — the
    /// capability that decides whether the mic control exists at all. False on
    /// a box with no microphone, or one whose device failed to open, and the
    /// button is then absent rather than present-and-inert.
    @Published public var micAvailable = false
    /// Whether the microphone is live. Starts off: joining a share must never
    /// put somebody on the air, which is also what the macOS viewer does.
    @Published public var micOn = false
    /// Set once the device has gone away mid-session, so the control can say so
    /// instead of silently ceasing to work.
    @Published public var micFailure: String?

    /// Annotation toolbar state (shown only when the sharer advertised
    /// `ScreenShareCaps.annotations`): the armed drawing tool, or nil when
    /// drawing is off (so drags zoom/pan or drive remote control).
    @Published public var activeTool: AnnotationTool?

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

    /// True once the user asked to end the current session — the placard's
    /// Cancel, or the in-session Stop. Polled by the transport's `shouldClose`
    /// each loop pass (both sides run on the main thread); reset by
    /// `beginSession`, which is enqueued before the session task starts
    /// polling, so a stale request can never end the next session at birth.
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
            self.remoteControlAvailable = false
            self.annotationsAvailable = false
            self.controlState = .idle
            self.sessionPhase = .connecting
            self.closeRequested = false
            self.micAvailable = false
            self.micOn = false
            self.micFailure = nil
            self.fps = 0
            self.videoWidth = 0
            self.videoHeight = 0
            self.activeTool = nil
        }
    }

    /// Publish the latest fps + resolution on the main thread.
    public func post(fps newFps: Int, width: Int, height: Int) {
        DispatchQueue.main.async {
            self.fps = newFps
            self.videoWidth = width
            self.videoHeight = height
        }
    }

    /// Publish a status change on the main thread (safe to call from anywhere).
    public func post(status newStatus: String) {
        DispatchQueue.main.async { self.status = newStatus }
    }

    /// Mark video as flowing on the main thread (safe to call from anywhere).
    public func markVideoFlowing() {
        DispatchQueue.main.async { self.hasVideo = true }
    }

    /// Record the sharer's advertised capabilities (from admission) on the main
    /// thread. `remoteControl` / `annotations` are the two sharer-only bits the
    /// viewer gates its chrome on.
    public func setCaps(remoteControl: Bool, annotations: Bool) {
        DispatchQueue.main.async {
            self.remoteControlAvailable = remoteControl
            self.annotationsAvailable = annotations
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

    /// The capture device went away mid-session — unplugged, or taken.
    ///
    /// Both flags move together: leaving `micOn` true would show a live
    /// microphone that is recording nothing, which is the one wrong answer a
    /// mute indicator can give.
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
