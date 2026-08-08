import Foundation

/// A system-wide chord this process currently holds.
///
/// The half of a platform hotkey shim that a controller actually uses: how many
/// times the chord fired, and give it back. `X11Hotkey` and `WindowsHotkey`
/// already had exactly this surface — the protocol only names it.
public protocol GlobalHotkeyHolding: AnyObject {
    /// How many times the chord was pressed since the last call.
    ///
    /// Polled rather than pushed, because that is what both platforms make
    /// cheap: X11 has no "post to the app's loop" primitive that does not mean
    /// threading Xlib, and `WM_HOTKEY` is a thread message the shim's own pump
    /// collects. A count rather than a bool so a fast double-press is two
    /// toggles rather than one.
    func drain() -> Int

    /// Give the chord back to the rest of the desktop.
    ///
    /// Explicit rather than left to `deinit`: a global grab is exclusive, so a
    /// hotkey this app no longer wants is a key no other app can have until the
    /// reference dies.
    func release()
}

/// Takes a chord system-wide on this platform, or says why it could not.
///
/// The ONE thing that genuinely differs between the two hosts' mute hotkeys,
/// and therefore the only thing left in each app after ``PortableMuteHotkey``.
/// The X11 binding checks the session type before touching Xlib (XWayland sets
/// `DISPLAY`, so "do we have a display?" passes on Wayland and the grab then
/// silently under-delivers) and warns about a server with no detectable
/// auto-repeat; the Windows binding has neither problem and simply calls
/// `RegisterHotKey`. Neither of those belongs in a shared controller, and
/// everything around them was identical.
public protocol GlobalHotkeyBinding {
    func hold(
        _ chord: ShortcutChord
    ) -> Result<any GlobalHotkeyHolding, GlobalHotkeyUnavailability>
}

/// The mute hotkey — the half of "mute from outside the window" that does not
/// need a window at all.
///
/// The in-window mic buttons only exist while the app is in front of you, and
/// during a share the app is behind whatever you are showing. This holds the
/// catalog's `toggleMicrophone` chord system-wide and flips the microphone
/// ``MuteHotkeyRouting`` names.
///
/// Both swift-cross-ui apps wrote this controller, near identically, around
/// their own platform shim; what differed was one method's worth of platform
/// (see ``GlobalHotkeyBinding``) and where a diagnostic line goes. What is
/// shared, and what a second copy would let drift, is every rule below:
///
/// - **It is held only while there is something to mute.** A global grab is
///   exclusive — whoever takes a chord takes it from every other app on the
///   machine — so holding ⌃⌥M while idle would be taking it for a handler with
///   nothing to do. Same reason macOS registers its panic-revoke key only while
///   a control grant is live.
/// - **The hold/release decision is acted on only when it CHANGES.** On Windows
///   re-taking the chord means destroying and recreating the shim's pump
///   thread; re-asserting it every tick would do that 20 times a second.
/// - **A failure is reported once, and surfaced rather than swallowed.** A mute
///   hotkey that was never registered looks exactly like one that works, right
///   up to the moment somebody presses it believing they have gone quiet — but
///   a line per 50 ms tick is a log nobody reads.
/// - **A retarget is announced.** Starting a share while already watching
///   silently changes which microphone the chord flips, and the honest thing is
///   to name the new one rather than let the user find out by pressing it.
/// - **`chordHint` is nil while the hotkey is not actually held**, so UI that
///   advertises the chord cannot teach somebody a mute key that does nothing.
///
/// `@MainActor` because both hosts read their mic availability and flip their
/// mic from there. It owns no thread: ``start()`` polls, and ``tick()`` is one
/// pass, which is what the suite drives.
@MainActor
public final class PortableMuteHotkey {
    /// Human-readable reason the hotkey is not available, or nil when it is.
    public private(set) var unavailability: GlobalHotkeyUnavailability?

    /// Invoked whenever ``unavailability`` changes, so the host can mirror it
    /// into whatever its views observe. A callback rather than an
    /// `ObservableObject` conformance: the swift-cross-ui hosts import this
    /// module wholesale and adding SwiftCrossUI beside it resurrects the
    /// `Published` collision their targeted imports exist to dodge.
    public var onUnavailabilityChange: (@MainActor (GlobalHotkeyUnavailability?) -> Void)?

    /// The chord's platform spelling ("Ctrl+Alt+M"), for UI that names it.
    public var chordDisplay: String { chord.display(.words) }

    /// The chord to advertise on microphone controls, or nil while the hotkey
    /// is not actually registered.
    ///
    /// Read off the HELD hotkey, not off `unavailability == nil`, which is what
    /// both apps' copies did: that answer is also nil before the first
    /// acquisition has been attempted, so it advertised a chord nobody was
    /// holding. Harmless in practice — the hosts only draw the hint beside a
    /// live mic control, and the same tick that makes one available takes the
    /// chord — but the contract this comment states is the one worth having,
    /// because the whole point is never to teach somebody a mute key that does
    /// nothing.
    public var chordHint: String? { hotkey == nil ? nil : chordDisplay }

    /// Which microphone the chord currently flips, for the UI to say so.
    public private(set) var target: MuteHotkeyTarget?

    private let chord: ShortcutChord
    private let binding: any GlobalHotkeyBinding
    private let sharerMicAvailable: @MainActor () -> Bool
    private let viewerMicAvailable: @MainActor () -> Bool
    private let toggleSharerMic: @MainActor () -> Void
    private let toggleViewerMic: @MainActor () -> Void
    /// Where a diagnostic goes. The host's, because the two disagree — stderr
    /// on GTK, stdout on WinUI — and neither is localized: these are console
    /// lines, not UI. The sharer-facing wording is `MuteHotkeyNote`.
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

    /// Begin watching. Idempotent.
    ///
    /// 50 ms is imperceptible on a keypress and cheap: an idle tick is one
    /// `XPending` on a socket with nothing on it, or one atomic read of the
    /// Windows shim's counter.
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
    ///
    /// Internal, not private, so `PortableMuteHotkeyTests` can drive the whole
    /// state machine deterministically instead of sleeping through the poll.
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

    /// Take the chord, if it is not already held.
    ///
    /// The guard is the load-bearing part on Windows: re-registering means
    /// tearing down and rebuilding the shim's pump thread.
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

    /// Record a transition and tell the host about it — only on change, so a
    /// failure re-reported every 50 ms tick is one mirror write, not many.
    private func setUnavailability(_ reason: GlobalHotkeyUnavailability?) {
        guard reason != unavailability else { return }
        unavailability = reason
        onUnavailabilityChange?(reason)
    }
}
