import Foundation
import TailscreenProtocol
import X11HotkeyKit

/// The mute hotkey — the half of "mute from outside the window" that does not
/// need a window at all.
///
/// The in-window mic buttons only exist while the app is in front of you, and
/// during a share it is behind whatever you are showing. This holds the
/// catalog's `toggleMicrophone` chord system-wide and flips the microphone
/// ``MuteHotkeyRouting`` names.
///
/// **Polled from the main actor.** X11 has no "post to the app's loop"
/// primitive that does not mean threading Xlib, so the grab connection is
/// drained on a tick instead — see `ts_x11hotkey.h`. 50 ms is imperceptible on
/// a keypress and cheap: an idle tick is one `XPending` on a socket with
/// nothing on it.
///
/// **It is held only while there is something to mute.** A global grab is
/// exclusive — whoever takes a chord takes it from every other app on the
/// machine — so holding ⌃⌥M while idle would be taking it for a handler with
/// nothing to do. Same reason macOS registers its panic-revoke key only while
/// a control grant is live.
@MainActor
final class MuteHotkeyController {
    /// Human-readable reason the hotkey is not available, or nil when it is.
    ///
    /// Surfaced rather than swallowed: a mute hotkey that was never registered
    /// looks exactly like one that works, right up to the moment somebody
    /// presses it believing they have gone quiet.
    private(set) var unavailability: GlobalHotkeyUnavailability?

    /// Invoked (on the main actor) whenever `unavailability` changes, so the
    /// host can mirror it into whatever its views observe. A callback rather
    /// than making this an `ObservableObject`: this file imports
    /// TailscreenProtocol wholesale, and adding SwiftCrossUI beside that
    /// resurrects the `Published` collision the app's targeted imports exist
    /// to dodge.
    var onUnavailabilityChange: (@MainActor (GlobalHotkeyUnavailability?) -> Void)?

    /// The chord's platform spelling ("Ctrl+Alt+M"), for UI that names it.
    var chordDisplay: String { chord.display(.words) }

    /// The chord to advertise on microphone controls, or nil while the hotkey
    /// is not actually registered — a tooltip naming a chord that does
    /// nothing would teach someone their mute key works right up to the
    /// moment it matters.
    var chordHint: String? {
        unavailability == nil ? chordDisplay : nil
    }

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
    private var hotkey: X11Hotkey?
    private var polling = false
    /// Reported once. The reason does not change while the process runs, and a
    /// line per tick would be a log nobody reads.
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

    /// One pass: re-target, grab or release accordingly, then drain.
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
            note("\(chord.display(.words)) now mutes \(target.label)\n")
        }
    }

    private func acquire() {
        guard hotkey == nil else { return }
        // The environment decision comes first and is re-taken on each
        // acquisition rather than cached: a session type can only really
        // change across a login, but caching a "no" would also cache a
        // transient failure to open the display.
        if let reason = X11HotkeySupport.decideFromEnvironment() {
            report(reason)
            return
        }
        guard let candidate = X11Hotkey() else {
            report(.noDisplay)
            return
        }
        if let reason = candidate.grab(chord) {
            report(reason)
            return
        }
        if !candidate.honoursDetectableAutoRepeat {
            // Not fatal — losing the shortcut entirely is the worse trade for
            // a case that only arises while somebody leans on a key — but it
            // means a held chord may flutter the mute, so say it once.
            note(
                "warning: this X server has no detectable auto-repeat; "
                    + "holding \(chord.display(.words)) may flip the microphone repeatedly\n")
        }
        hotkey = candidate
        setUnavailability(nil)
        loggedUnavailability = false
        note("\(chord.display(.words)) holds the microphone toggle\n")
    }

    private func relinquish() {
        announcedTarget = nil
        guard let hotkey else { return }
        hotkey.release()
        self.hotkey = nil
    }

    private func report(_ reason: GlobalHotkeyUnavailability) {
        setUnavailability(reason)
        guard !loggedUnavailability else { return }
        loggedUnavailability = true
        note(
            "warning: \(chord.display(.words)) is unavailable — \(reason.reason); "
                + "use the microphone button in the window\n")
    }

    /// Record a transition and tell the host about it — only on change, so a
    /// failure re-reported every 50 ms tick is one mirror write, not many.
    private func setUnavailability(_ reason: GlobalHotkeyUnavailability?) {
        guard reason != unavailability else { return }
        unavailability = reason
        onUnavailabilityChange?(reason)
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
