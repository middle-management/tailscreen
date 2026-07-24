import Foundation
import SwiftCrossUI

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

    public init() {}

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
