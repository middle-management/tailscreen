import Foundation
import TailscreenL10n
import TailscreenViewerGtk

import struct TailscreenAudio.VoiceLatch
import class TailscreenAudio.VoiceUplink

/// The mic button's other half: owns the session's `VoiceUplink` and keeps the
/// UI's idea of the microphone in step with it. Sibling of `ViewerControls`
/// and `AnnotationForwarder`.
///
/// **The uplink outlives nothing.** `detach` runs on every session exit path
/// (clean end, decline, throw) — a stale uplink would leave the mic open on a
/// machine whose session ended.
@MainActor
final class VoiceControls {
    private var uplink: VoiceUplink?
    /// The two published flags and every transition allowed to move them.
    /// Shared with the WinUI viewer and both share engines, so a released
    /// device can never be toggled back on the air.
    private var latch = VoiceLatch()
    private let uiState: ViewerUIState

    init(ui uiState: ViewerUIState) {
        self.uiState = uiState
    }

    func attach(_ uplink: VoiceUplink) {
        self.uplink = uplink
        // Write what the latch says rather than assume it agrees with the
        // transport's own muted-at-start.
        uplink.isMuted = latch.attach()
        publish()
        uplink.onStopped = { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self else { return }
                // Latch first, so a toggle can't move the flags back after.
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

    /// Flip the microphone. No-op with nothing attached — belt and braces,
    /// since the button's visibility and the uplink's lifetime publish
    /// through different paths and could disagree for a frame.
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
