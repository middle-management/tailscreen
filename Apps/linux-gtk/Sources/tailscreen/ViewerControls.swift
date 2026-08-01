import Foundation
import TailscreenViewerGtk
import TailscreenViewerTsnet

/// Bridges the swift-cross-ui toolbar (main-thread button actions) to the
/// `ViewerBackChannel` actor. The back-channel arrives asynchronously (once the
/// transport dials the sharer), so this holder stashes it and forwards
/// request/release intents; before it attaches, the button no-ops (the caps
/// gate keeps it hidden until admission anyway).
@MainActor
final class ViewerControls {
    private var backChannel: ViewerBackChannel?
    private let ui: ViewerUIState

    init(ui: ViewerUIState) {
        self.ui = ui
    }

    /// Called from the transport's `onBackChannelReady` (any thread) — hops to
    /// the main actor to publish the reference the button actions read.
    nonisolated func attach(_ channel: ViewerBackChannel) {
        Task { @MainActor in self.backChannel = channel }
    }

    /// Toolbar action: request control when idle, release it when
    /// requested/active. The grant/revoke replies drive `controlState` back
    /// (see the back-channel handlers in `main`), so this only owns the
    /// optimistic local transition + the outbound message.
    func toggleControl() {
        let channel = backChannel
        switch ui.controlState {
        case .idle, .revoked:
            ui.controlState = .requested
            Task { await channel?.requestControl() }
        case .requested, .active:
            ui.controlState = .idle
            Task { await channel?.releaseControl() }
        }
    }
}
