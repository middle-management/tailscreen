import CX11Hotkey
import Foundation
import TailscreenProtocol

/// The pre-flight decision, taken from the environment before any X call.
/// Pure and injected rather than reading `ProcessInfo` inline, since the case
/// that matters — a Wayland session where the X path silently
/// under-delivers — can't be reproduced on a CI machine running Xvfb.
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

/// A system-wide hotkey held with `XGrabKey`. Polled, not pushed: `drain()`
/// is called from the host's existing main-thread tick and returns how many
/// times the chord was pressed since the last call.
///
/// Auto-repeat is collapsed by `GlobalHotkeyRepeatFilter` on the way out, so
/// a chord held down is one activation.
public final class X11Hotkey {
    private var handle: UnsafeMutableRawPointer?
    private var filter = GlobalHotkeyRepeatFilter()
    private var grabbed: ShortcutChord?

    /// Test seam: when set, `drain()` reads from this instead of the X
    /// server. Latch-and-count is a decision; the Xlib call is covered by
    /// `x11-hotkey-probe --live-check`.
    var pollForTesting: (() -> [GlobalHotkeyRepeatFilter.Event])?

    /// Opens a dedicated grab connection, or fails. Not GTK's connection —
    /// pulling events off a toolkit's own connection with `XNextEvent`
    /// steals them from the widget layer.
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

    /// Whether the server honoured `XkbSetDetectableAutoRepeat`. False means
    /// a held chord arrives as release/press pairs the latch can't
    /// distinguish from deliberate ones. Reported, not swallowed — but the
    /// grab is still taken, since losing the shortcut is the worse trade.
    public var honoursDetectableAutoRepeat: Bool {
        guard let handle else { return true }
        return ts_hotkey_detectable_autorepeat(handle) != 0
    }

    /// Take the chord system-wide. Returns nil on success. Installed under
    /// every lock-key variant — `XGrabKey` matches modifier state exactly, so
    /// the bare mask alone stops working once Num Lock is on.
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
        // A fresh grab starts with no key held — the release that would have
        // cleared the latch went to whoever held the grab before us.
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

    /// How many times the chord was pressed since the last call. Counts,
    /// rather than returning a Bool, so two presses in one tick toggle twice
    /// (correct for a mute — it lands back where it started).
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
        // Drain in batches until the server has nothing left, so a burst
        // exceeding one buffer isn't left sitting until the next tick.
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

/// `drain()`/`release()` already match the portable controller's shape.
/// Declared here, not in the app, so neither host needs a `@retroactive` conformance.
extension X11Hotkey: GlobalHotkeyHolding {}
