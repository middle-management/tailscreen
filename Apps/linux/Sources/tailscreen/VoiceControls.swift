import Foundation
import TailscreenL10n
import TailscreenViewerGtk

import struct TailscreenAudio.VoiceLatch
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
    /// The two published flags and every transition allowed to move them.
    /// Shared with the WinUI viewer and both share engines — see `VoiceLatch`,
    /// which exists because five copies of this had to agree that a released
    /// device can never be toggled back on the air.
    private var latch = VoiceLatch()
    private let uiState: ViewerUIState

    init(ui uiState: ViewerUIState) {
        self.uiState = uiState
    }

    func attach(_ uplink: VoiceUplink) {
        self.uplink = uplink
        // The transport starts it muted; write what the latch says rather than
        // assuming the two agree.
        uplink.isMuted = latch.attach()
        publish()
        uplink.onStopped = { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self else { return }
                // The latch first, so the flags cannot be moved back afterwards
                // by a toggle; `noteMicFailure` publishes the same pair plus
                // the sentence this side owns.
                self.latch.detach()
                self.uiState.noteMicFailure(L("Microphone unavailable"))
            }
        }
    }

    func detach() {
        uplink?.stop()
        uplink = nil
        latch.detach()
        publish()
    }

    /// Flip the microphone. A no-op with nothing attached, which the UI
    /// prevents by not drawing the button at all — belt and braces, because the
    /// button's visibility and the uplink's lifetime are published through
    /// different paths and could in principle disagree for a frame.
    func toggle() {
        guard case .setMuted(let muted) = latch.toggle() else { return }
        uplink?.isMuted = muted
        publish()
    }

    private func publish() {
        uiState.setMicAvailable(latch.isAvailable)
        uiState.micOn = latch.isOn
    }
}
