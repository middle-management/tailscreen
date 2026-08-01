import Foundation
import SwiftCrossUI

// Targeted import: all of TailscreenProtocol would collide with SwiftCrossUI's
// own `Published` / `ObservableObject` (both ship reactive shims on Linux, where
// Combine is absent). Only the tool enum is needed here.
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
    @Published public var status = "Connecting…"

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
    /// viewing, or declined / ended / failed).
    @Published public var sessionPhase: SessionPhase = .connecting

    public enum SessionPhase: Equatable, Sendable {
        case connecting
        case awaitingApproval
        case viewing
        case declined
        case ended
        case failed(String)
    }

    /// Live video stats for the HUD overlay (viewer-side: fps counted at the
    /// sink, resolution from the decoded frame). Network stats (bitrate/loss)
    /// need portable `ViewerSession` counters — a follow-up.
    @Published public var fps = 0
    @Published public var videoWidth = 0
    @Published public var videoHeight = 0
    /// Whether the stats HUD is shown (toggled from the control bar).
    @Published public var showStats = false

    /// Annotation toolbar state (shown only when the sharer advertised
    /// `ScreenShareCaps.annotations`): the armed drawing tool, or nil when
    /// drawing is off (so drags zoom/pan or drive remote control). The stroke
    /// COLOR isn't here — like the mac, it's assigned from the local identity
    /// (`AnnotationStore.color`), not chosen.
    @Published public var activeTool: AnnotationTool?

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

    /// Enter a fresh session: in-session, connecting, no video, control reset.
    public func beginSession() {
        DispatchQueue.main.async {
            self.inSession = true
            self.hasVideo = false
            self.sessionPhase = .connecting
            self.controlState = .idle
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

    /// Move the remote-control state machine on the main thread (safe from the
    /// back-channel's task).
    public func setControlState(_ newState: ControlState) {
        DispatchQueue.main.async { self.controlState = newState }
    }
}
