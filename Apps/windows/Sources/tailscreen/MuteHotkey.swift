import Foundation
import TailscreenProtocol
import WinHotkeyKit

/// The mute hotkey — the half of "mute from outside the window" that does not
/// need a window at all.
///
/// The Windows sibling of `Apps/linux/Sources/tailscreen/MuteHotkey.swift`, and
/// deliberately the same shape: it holds the catalog's `toggleMicrophone` chord
/// system-wide while there is a microphone to mute, drains activations from a
/// main-actor tick, and flips whichever microphone ``MuteHotkeyRouting`` names.
///
/// Two differences, both the platform's. There is no repeat latch —
/// `MOD_NOREPEAT` rides every registration `WindowsHotkeyMapping` emits, so a
/// held chord is already one activation. And re-taking the chord means
/// destroying and recreating the shim's pump thread, which is why the
/// hold/release decision is only acted on when it *changes* rather than
/// re-asserted every tick.
@MainActor
final class MuteHotkeyController {
    /// Why the hotkey is not available, or nil when it is.
    ///
    /// Surfaced rather than swallowed: a mute hotkey that was never registered
    /// looks exactly like one that works, right up to the moment somebody
    /// presses it believing they have gone quiet.
    private(set) var unavailability: GlobalHotkeyUnavailability?

    /// Which microphone the chord currently flips, for the UI to say so.
    private(set) var target: MuteHotkeyTarget?

    private let chord: ShortcutChord
    private let sharerMicAvailable: @MainActor () -> Bool
    private let viewerMicAvailable: @MainActor () -> Bool
    private let toggleSharerMic: @MainActor () -> Void
    private let toggleViewerMic: @MainActor () -> Void

    /// The last target announced, so a retarget is said once rather than per
    /// tick. It IS said: starting a share while already watching silently
    /// changes which microphone the chord flips, and the honest thing is to
    /// name the new one rather than let the user find out by pressing it.
    private var announcedTarget: MuteHotkeyTarget?
    private var hotkey: WindowsHotkey?
    private var polling = false
    /// Reported once — the reason does not change while the process runs, and
    /// a line per tick would be a log nobody reads.
    private var loggedUnavailability = false

    init?(
        sharerMicAvailable: @escaping @MainActor () -> Bool,
        viewerMicAvailable: @escaping @MainActor () -> Bool,
        toggleSharerMic: @escaping @MainActor () -> Void,
        toggleViewerMic: @escaping @MainActor () -> Void
    ) {
        guard let entry = ShortcutCatalog.entry(for: .toggleMicrophone), entry.isGlobal else {
            return nil
        }
        self.chord = entry.chord
        self.sharerMicAvailable = sharerMicAvailable
        self.viewerMicAvailable = viewerMicAvailable
        self.toggleSharerMic = toggleSharerMic
        self.toggleViewerMic = toggleViewerMic
    }

    /// Begin watching. Idempotent.
    func start() {
        guard !polling else { return }
        polling = true
        Task { @MainActor in
            while true {
                tick()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func tick() {
        let sharer = sharerMicAvailable()
        let viewer = viewerMicAvailable()
        target = MuteHotkeyRouting.target(
            sharerMicAvailable: sharer, viewerMicAvailable: viewer)

        if MuteHotkeyRouting.shouldRegister(
            sharerMicAvailable: sharer, viewerMicAvailable: viewer) {
            acquire()
        } else {
            relinquish()
        }

        announce(target)
        guard let hotkey, let target else { return }
        for _ in 0..<hotkey.drain() {
            switch target {
            case .sharer: toggleSharerMic()
            case .viewer: toggleViewerMic()
            }
        }
    }

    /// Say which microphone the chord points at, when that changes.
    private func announce(_ target: MuteHotkeyTarget?) {
        guard hotkey != nil, target != announcedTarget else { return }
        announcedTarget = target
        if let target {
            note("\(chord.display(.words)) now mutes \(target.label)")
        }
    }

    private func acquire() {
        guard hotkey == nil else { return }
        switch WindowsHotkey.hold(chord) {
        case .success(let held):
            hotkey = held
            unavailability = nil
            loggedUnavailability = false
            note("\(chord.display(.words)) holds the microphone toggle")
        case .failure(let reason):
            unavailability = reason
            guard !loggedUnavailability else { return }
            loggedUnavailability = true
            note(
                "warning: \(chord.display(.words)) is unavailable — \(reason.reason); "
                    + "use the microphone button in the window")
        }
    }

    private func relinquish() {
        announcedTarget = nil
        guard let hotkey else { return }
        hotkey.release()
        self.hotkey = nil
    }

    private func note(_ message: String) {
        print(message)
    }
}
