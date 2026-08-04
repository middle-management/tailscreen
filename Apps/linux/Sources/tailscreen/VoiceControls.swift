import Foundation
import TailscreenL10n
import TailscreenViewerGtk

import class TailscreenAudio.VoiceUplink

/// The mic button's other half: owns the session's `VoiceUplink` and keeps the
/// UI's idea of the microphone in step with it.
///
/// Sibling of `ViewerControls` (remote control) and `AnnotationForwarder`, and
/// the same shape for the same reason: the transport hands a session-scoped
/// object to the main actor, and something has to hold it for exactly as long
/// as the session lasts without the SwiftUI-ish view layer reaching into the
/// transport.
///
/// **The uplink outlives nothing.** `detach` is called on every session exit
/// path — clean end, decline, throw — because a stale uplink would leave the
/// microphone open on a machine whose session ended, which is the one bug in
/// this area a person notices from across the room (the OS mic indicator stays
/// lit).
@MainActor
final class VoiceControls {
    private var uplink: VoiceUplink?
    private let uiState: ViewerUIState

    init(ui uiState: ViewerUIState) {
        self.uiState = uiState
    }

    func attach(_ uplink: VoiceUplink) {
        self.uplink = uplink
        // The transport starts it muted; mirror that rather than assuming it.
        uplink.isMuted = true
        uplink.onStopped = { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.uiState.noteMicFailure(L("Microphone unavailable"))
                _ = error
            }
        }
    }

    func detach() {
        uplink?.stop()
        uplink = nil
        uiState.setMicAvailable(false)
    }

    /// Flip the microphone. A no-op with no uplink, which the UI prevents by
    /// not drawing the button at all — belt and braces, because the button's
    /// visibility and the uplink's lifetime are published through different
    /// paths and could in principle disagree for a frame.
    func toggle() {
        guard let uplink else { return }
        let nowOn = uplink.isMuted
        uplink.isMuted = !nowOn
        uiState.micOn = nowOn
    }
}
