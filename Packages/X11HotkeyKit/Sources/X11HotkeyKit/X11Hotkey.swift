import CX11Hotkey
import Foundation
import TailscreenProtocol

/// The pre-flight decision, taken from the environment before any X call.
///
/// Pure and injected rather than reading `ProcessInfo` inline, because the one
/// case that matters — a Wayland session, where the X path succeeds and then
/// under-delivers — cannot be reproduced on a CI machine running Xvfb. A
/// function over three strings can be.
public enum X11HotkeySupport {
    /// `nil` when an X11 grab is worth attempting.
    ///
    /// Wayland is checked FIRST and wins even when `DISPLAY` is set, because
    /// XWayland sets `DISPLAY` — treating its presence as proof of an X11
    /// session is exactly how this ends up silently half-working.
    public static func decide(
        waylandDisplay: String?, sessionType: String?, x11Display: String?
    ) -> GlobalHotkeyUnavailability? {
        if let wayland = waylandDisplay, !wayland.isEmpty { return .waylandSession }
        if let session = sessionType, session.lowercased() == "wayland" { return .waylandSession }
        if let display = x11Display, !display.isEmpty { return nil }
        return .noDisplay
    }

    /// The same decision against the real environment.
    public static func decideFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GlobalHotkeyUnavailability? {
        decide(
            waylandDisplay: environment["WAYLAND_DISPLAY"],
            sessionType: environment["XDG_SESSION_TYPE"],
            x11Display: environment["DISPLAY"])
    }
}

/// A system-wide hotkey held with `XGrabKey`.
///
/// Polled, not pushed: `drain()` is called from the host's existing main-thread
/// tick and returns how many times the chord was pressed since the last call.
/// That is the entire threading story — see the header comment on
/// `ts_x11hotkey.h` for why it is not a thread with a callback.
///
/// Auto-repeat is collapsed by ``GlobalHotkeyRepeatFilter`` on the way out, so
/// a chord held down is one activation. Without that, a *toggle* bound to a
/// held key ends up wherever the repeat rate leaves it.
public final class X11Hotkey {
    private var handle: UnsafeMutableRawPointer?
    private var filter = GlobalHotkeyRepeatFilter()
    private var grabbed: ShortcutChord?

    /// Test seam: when set, `drain()` reads from this instead of the X server.
    /// The latch-and-count logic on top of the raw event stream is a decision;
    /// the Xlib call under it is covered by `x11-hotkey-probe --live-check`.
    var pollForTesting: (() -> [GlobalHotkeyRepeatFilter.Event])?

    /// Opens a dedicated grab connection, or fails.
    ///
    /// A second `Display *` rather than borrowing GTK's, for the reason the
    /// GTK docs give themselves: a toolkit's connection is the toolkit's, and
    /// pulling events off it with `XNextEvent` steals them from the widget
    /// layer. This one is opened solely for the grab, so anything arriving on
    /// it is ours by construction.
    public init?(displayName: String? = nil) {
        if let displayName {
            handle = displayName.withCString { ts_hotkey_open($0) }
        } else {
            handle = ts_hotkey_open(nil)
        }
        guard handle != nil else { return nil }
    }

    /// Test-only initializer: no display, `pollForTesting` supplies events.
    init(testingWith poll: @escaping () -> [GlobalHotkeyRepeatFilter.Event]) {
        handle = nil
        pollForTesting = poll
    }

    deinit {
        if let handle { ts_hotkey_close(handle) }
    }

    /// Whether the server honoured `XkbSetDetectableAutoRepeat`.
    ///
    /// False means a held chord arrives as release/press pairs the latch
    /// cannot distinguish from deliberate ones, so the toggle would flutter
    /// while a key is held. Reported rather than swallowed; the grab is still
    /// taken, because losing the shortcut entirely is the worse trade for a
    /// case that only arises while somebody leans on a key.
    public var honoursDetectableAutoRepeat: Bool {
        guard let handle else { return true }
        return ts_hotkey_detectable_autorepeat(handle) != 0
    }

    /// Take the chord system-wide. Returns nil on success.
    ///
    /// The grab is installed under every lock-key variant
    /// (``X11HotkeyMapping/grabMasks(base:)``): `XGrabKey` matches modifier
    /// state exactly, so grabbing the bare mask alone yields a hotkey that
    /// stops working the moment Num Lock is on.
    @discardableResult
    public func grab(_ chord: ShortcutChord) -> GlobalHotkeyUnavailability? {
        guard let handle else { return .noDisplay }
        guard let request = X11HotkeyMapping.grab(for: chord) else { return .unmappableChord }
        let masks = X11HotkeyMapping.grabMasks(base: request.modifierMask)
        let ok = masks.withUnsafeBufferPointer { buffer in
            ts_hotkey_grab(handle, request.keysym, buffer.baseAddress, Int32(buffer.count)) != 0
        }
        guard ok else {
            grabbed = nil
            return .alreadyOwned
        }
        grabbed = chord
        // A fresh grab starts with no key held as far as we are concerned: the
        // release that would have cleared the latch went to whoever held the
        // grab before us.
        filter.reset()
        return nil
    }

    /// Whether a grab is currently held.
    public var isGrabbed: Bool { grabbed != nil }

    /// Give the chord back to the rest of the desktop.
    public func release() {
        if let handle { ts_hotkey_ungrab(handle) }
        grabbed = nil
        filter.reset()
    }

    /// How many times the chord was pressed since the last call.
    ///
    /// Two presses inside one tick return 2 and the host toggles twice, which
    /// for a mute means it lands back where it started — correct, and the
    /// reason this counts rather than returning a Bool.
    public func drain() -> Int {
        var activations = 0
        for event in rawEvents() where filter.shouldFire(event) {
            activations += 1
        }
        return activations
    }

    private func rawEvents() -> [GlobalHotkeyRepeatFilter.Event] {
        if let pollForTesting { return pollForTesting() }
        guard let handle else { return [] }
        var events: [GlobalHotkeyRepeatFilter.Event] = []
        // Drain in batches until the server has nothing left, so a burst that
        // exceeds one buffer is not left sitting until the next tick.
        var buffer = [Int32](repeating: 0, count: 32)
        while true {
            let written = buffer.withUnsafeMutableBufferPointer { pointer in
                ts_hotkey_poll(handle, pointer.baseAddress, Int32(pointer.count))
            }
            guard written > 0 else { break }
            for index in 0..<Int(written) {
                events.append(buffer[index] == 1 ? .press : .release)
            }
            if Int(written) < buffer.count { break }
        }
        return events
    }
}

/// `drain()` and `release()` were already exactly the shape the portable
/// controller wants — the conformance only names that. Declared here rather
/// than in the app so neither swift-cross-ui host needs a `@retroactive`
/// conformance of an imported type to an imported protocol.
extension X11Hotkey: GlobalHotkeyHolding {}
