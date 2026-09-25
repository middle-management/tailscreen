import Foundation
import TailscreenL10n
import TailscreenViewerGtk
import TailscreenViewerTsnet

import struct TailscreenProtocol.OpenLinkPayload

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

    // MARK: Open link on sharer

    /// Toolbar action: reveal the inline composer. Clears any stale error or
    /// confirmation from a previous send.
    func openLinkComposer() {
        ui.openLinkError = nil
        ui.openLinkSent = false
        ui.openLinkComposerOpen = true
    }

    /// Composer's Cancel: close with nothing sent.
    func cancelLinkComposer() {
        ui.openLinkComposerOpen = false
        ui.openLinkText = ""
        ui.openLinkError = nil
    }

    /// Composer's Send: validate locally (the sharer re-validates and drops
    /// anything else — this only gives a fast, in-place error instead of a
    /// link that silently never arrives).
    func sendLink() {
        let trimmed = ui.openLinkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OpenLinkPayload.isAcceptable(trimmed) else {
            ui.openLinkError = L(
                "That isn't a link the sharer can open. Use a full http:// or https:// address with no spaces."
            )
            return
        }
        let channel = backChannel
        Task { await channel?.sendOpenLink(trimmed) }
        ui.openLinkComposerOpen = false
        ui.openLinkText = ""
        ui.openLinkError = nil
        ui.openLinkSent = true
    }
}
