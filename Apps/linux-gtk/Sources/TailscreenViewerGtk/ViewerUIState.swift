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

    public init() {}

    /// Publish a status change on the main thread (safe to call from anywhere).
    public func post(status newStatus: String) {
        DispatchQueue.main.async { self.status = newStatus }
    }

    /// Mark video as flowing on the main thread (safe to call from anywhere).
    public func markVideoFlowing() {
        DispatchQueue.main.async { self.hasVideo = true }
    }
}
