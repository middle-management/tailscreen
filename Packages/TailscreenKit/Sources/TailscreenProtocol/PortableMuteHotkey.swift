import Foundation

/// A system-wide chord this process currently holds. The surface a
/// controller actually uses; `X11Hotkey`/`WindowsHotkey` already had it.
public protocol GlobalHotkeyHolding: AnyObject {
    /// How many times the chord was pressed since the last call. Polled, not
    /// pushed — cheap on both platforms (X11 has no post-to-loop primitive
    /// without threading Xlib; `WM_HOTKEY` is a thread message the shim's
    /// pump collects). A count, not a bool, so a fast double-press is two
    /// toggles.
    func drain() -> Int

    /// Give the chord back to the rest of the desktop. Explicit, not left to
    /// `deinit`: a global grab is exclusive, so the key stays unavailable
    /// until the reference dies otherwise.
    func release()
}

/// Takes a chord system-wide on this platform, or says why it could not.
/// The one thing that genuinely differs between the two hosts' mute
/// hotkeys, so the only thing left in each app after ``PortableMuteHotkey``.
public protocol GlobalHotkeyBinding {
    func hold(
        _ chord: ShortcutChord
    ) -> Result<any GlobalHotkeyHolding, GlobalHotkeyUnavailability>
}

/// The mute hotkey — the half of "mute from outside the window" that does
/// not need a window at all. Holds the catalog's `toggleMicrophone` chord
/// system-wide and flips the microphone ``MuteHotkeyRouting`` names.
///
/// Both swift-cross-ui apps wrote this near-identically around their own
/// platform shim; only one method's worth (``GlobalHotkeyBinding``) and the
/// diagnostic sink differ. Shared rules a second copy would let drift:
///
/// - **Held only while there is something to mute** — a global grab is
///   exclusive, so idle-holding would take the chord from every other app.
/// - **Hold/release acted on only when it CHANGES** — on Windows re-taking
///   the chord destroys/recreates the shim's pump thread.
/// - **A failure is reported once**, not once per 50ms tick.
/// - **A retarget is announced**, since starting a share while watching
///   silently changes which mic the chord flips.
/// - **`chordHint` is nil while not actually held**, so UI never advertises
///   a mute key that does nothing.
///
/// `@MainActor`; owns no thread — ``start()`` polls, ``tick()`` is one pass.
@MainActor
public final class PortableMuteHotkey {
    /// Human-readable reason the hotkey is not available, or nil when it is.
    public private(set) var unavailability: GlobalHotkeyUnavailability?

    /// Invoked whenever ``unavailability`` changes. A callback rather than
    /// `ObservableObject`: adding SwiftCrossUI here would resurrect the
    /// `Published` collision the hosts' targeted imports dodge.
    public var onUnavailabilityChange: (@MainActor (GlobalHotkeyUnavailability?) -> Void)?

    /// The chord's platform spelling ("Ctrl+Alt+M"), for UI that names it.
    public var chordDisplay: String { chord.display(.words) }

    /// The chord to advertise on microphone controls, or nil while the hotkey
    /// is not actually registered. Read off the HELD hotkey, not
    /// `unavailability == nil` (also nil before the first acquisition
    /// attempt, which would advertise a chord nobody was holding).
    public var chordHint: String? { hotkey == nil ? nil : chordDisplay }

    /// Which microphone the chord currently flips, for the UI to say so.
    public private(set) var target: MuteHotkeyTarget?

    private let chord: ShortcutChord
    private let binding: any GlobalHotkeyBinding
    private let sharerMicAvailable: @MainActor () -> Bool
    private let viewerMicAvailable: @MainActor () -> Bool
    private let toggleSharerMic: @MainActor () -> Void
    private let toggleViewerMic: @MainActor () -> Void
    /// Where a diagnostic goes (stderr on GTK, stdout on WinUI), unlocalized
    /// console lines. The sharer-facing wording is `MuteHotkeyNote`.
    private let note: @Sendable (String) -> Void

    /// The last target announced, so a retarget is said once rather than per
    /// tick.
    private var announcedTarget: MuteHotkeyTarget?
    private var hotkey: (any GlobalHotkeyHolding)?
    private var polling = false
    private var loggedUnavailability = false

    /// - Returns: nil when the catalog has no global `toggleMicrophone` entry,
    ///   which is a build with the shortcut removed rather than an error.
    public init?(
        binding: any GlobalHotkeyBinding,
        sharerMicAvailable: @escaping @MainActor () -> Bool,
        viewerMicAvailable: @escaping @MainActor () -> Bool,
        toggleSharerMic: @escaping @MainActor () -> Void,
        toggleViewerMic: @escaping @MainActor () -> Void,
        note: @escaping @Sendable (String) -> Void
    ) {
        guard let entry = ShortcutCatalog.entry(for: .toggleMicrophone), entry.isGlobal else {
            return nil
        }
        self.chord = entry.chord
        self.binding = binding
        self.sharerMicAvailable = sharerMicAvailable
        self.viewerMicAvailable = viewerMicAvailable
        self.toggleSharerMic = toggleSharerMic
        self.toggleViewerMic = toggleViewerMic
        self.note = note
    }

    /// Begin watching. Idempotent. 50ms is imperceptible on a keypress and
    /// cheap on both platforms (one `XPending`/counter read when idle).
    public func start() {
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
    /// Internal, not private, so `PortableMuteHotkeyTests` can drive it
    /// deterministically instead of sleeping through the poll.
    func tick() {
        let sharer = sharerMicAvailable()
        let viewer = viewerMicAvailable()
        target = MuteHotkeyRouting.target(
            sharerMicAvailable: sharer, viewerMicAvailable: viewer)

        let shouldHold = MuteHotkeyRouting.shouldRegister(
            sharerMicAvailable: sharer, viewerMicAvailable: viewer)
        if shouldHold {
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
            note("\(chordDisplay) now mutes \(target.label)")
        }
    }

    /// Take the chord, if it is not already held. The guard matters on
    /// Windows: re-registering tears down and rebuilds the pump thread.
    private func acquire() {
        guard hotkey == nil else { return }
        switch binding.hold(chord) {
        case .success(let held):
            hotkey = held
            setUnavailability(nil)
            loggedUnavailability = false
            note("\(chordDisplay) holds the microphone toggle")
        case .failure(let reason):
            setUnavailability(reason)
            guard !loggedUnavailability else { return }
            loggedUnavailability = true
            note(
                "warning: \(chordDisplay) is unavailable — \(reason.reason); "
                    + "use the microphone button in the window")
        }
    }

    private func relinquish() {
        announcedTarget = nil
        guard let hotkey else { return }
        hotkey.release()
        self.hotkey = nil
    }

    /// Record a transition and tell the host, only on change.
    private func setUnavailability(_ reason: GlobalHotkeyUnavailability?) {
        guard reason != unavailability else { return }
        unavailability = reason
        onUnavailabilityChange?(reason)
    }
}
