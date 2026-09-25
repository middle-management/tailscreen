import CSendInput
import Foundation
import TailscreenProtocol

/// Swift face of Win32 `SendInput`: the coordinate/keycode translation, the
/// grant gate, and the serial ordering.
///
/// Kept free of the `InputInjecting` conformance so this package does not
/// depend on TailscreenSharer; the conformance is an empty extension in
/// TailscreenSharerWGC, the same shape macOS uses in `ScreenShareBackends.swift`.
public final class SendInputInjector: @unchecked Sendable {
    /// A rectangle on screen — what normalized coordinates are mapped into.
    /// Supplied by the host, since "what am I sharing" is the host's
    /// question (a `WGC.CaptureItem` doesn't expose its own monitor/window).
    public typealias Region = WindowsPointerMapping.ScreenRect

    /// Test seam: what would be injected, without touching the real desktop.
    ///
    /// Everything below is verifiable except the `SendInput` call itself, and
    /// a real one would fling the cursor across whatever machine is running
    /// the tests. Fires on the serial queue.
    public enum InjectedAction: Equatable, Sendable {
        case move(x: Int32, y: Int32)
        case button(index: Int32, down: Bool, x: Int32, y: Int32)
        case scroll(wheelY: Int32, wheelX: Int32)
        /// `virtualKey` is the TRANSLATED Win32 VK code, and `extended` its
        /// other half — the pair is what identifies a key on Windows.
        case key(virtualKey: UInt16, extended: Bool, down: Bool)
    }

    /// When set, actions are recorded here and NOTHING is injected.
    public var onInjectForTesting: ((InjectedAction) -> Void)?

    /// Block until the serial queue has drained everything enqueued so far, so
    /// a test can assert on `onInjectForTesting` without sleeping.
    public func drainSyncForTesting() {
        queue.sync {}
    }

    private let queue = DispatchQueue(label: "dev.tailscreen.sendinput-injector")

    /// The gate and the queue share one lock so a revoke is atomic with
    /// enqueueing: once `active` goes false, neither a queued event nor one
    /// that raced the revoke can still be injected. Same TOCTOU fix the macOS
    /// injector carries.
    private struct GateState {
        var active = false
        var pending: [InputEvent] = []
    }
    private let gate = NSLock()
    private var state = GateState()
    private var region: Region?

    // Queue-confined pressed-button state. Windows needs no drag-specific
    // event type (a move during a press IS a drag), so unlike macOS this
    // exists for one reason: `deactivate()` must synthesize the matching
    // button-up, or a revoke mid-drag leaves a button stuck down on the
    // sharer's desktop with nobody able to release it.
    private var heldButtons: Set<Int32> = []
    private var lastAbsolute: (x: Int32, y: Int32) = (0, 0)

    /// Where the virtual desktop's bounds come from. Injectable so the
    /// geometry is an input rather than an ambient `GetSystemMetrics` fact,
    /// which can't be checked on any test machine.
    ///
    /// Called per event rather than cached: monitors are hot-plugged and
    /// rearranged mid-share, and a stale desktop rect silently sends the
    /// pointer to the wrong screen.
    public var virtualDesktopProvider: @Sendable () -> Region = {
        SendInputInjector.virtualDesktop()
    }

    public init() {}

    // MARK: Permission

    /// Windows has no Accessibility-style consent to request. Injection is
    /// governed by UIPI, which silently discards input aimed at a window at a
    /// HIGHER integrity level — there's no prompt to acquire, and an
    /// unelevated process simply can't drive an elevated one. Returns true
    /// even when not elevated, since refusing the grant outright would break
    /// remote control on every normal desktop.
    public func isTrusted() -> Bool { true }

    /// Whether this process can also drive elevated windows. Not part of the
    /// permission decision — worth surfacing since "works everywhere except
    /// Task Manager" is otherwise a mystery.
    public var canDriveElevatedWindows: Bool { ts_input_is_elevated() != 0 }

    /// Nothing to prompt for. Returns `isTrusted()` so callers written against
    /// the macOS shape behave sensibly.
    @discardableResult
    public func promptForAccess() -> Bool { isTrusted() }

    // MARK: Gate

    /// Update the region normalized coordinates map into, without touching the
    /// grant gate — a mid-share source change.
    public func setRegion(_ region: Region?) {
        gate.withLock { self.region = region }
    }

    /// Open the gate for a new grantee. Any stale queue is dropped: events
    /// from a previous grant must never be replayed under a new one.
    public func activate(region: Region?) {
        gate.withLock {
            self.region = region
            state.pending.removeAll()
            state.active = true
        }
    }

    /// Seal the gate, drop everything queued, and release any held button.
    public func deactivate() {
        gate.withLock {
            state.active = false
            state.pending.removeAll()
            region = nil
        }
        queue.async { [weak self] in self?.releaseHeldButtons() }
    }

    /// Enqueue one event. Dropped when the gate is closed; otherwise applied
    /// on the serial queue in arrival order.
    public func apply(_ event: InputEvent) {
        let accepted = gate.withLock { () -> Bool in
            guard state.active else { return false }
            state.pending.append(event)
            return true
        }
        guard accepted else { return }
        queue.async { [weak self] in self?.drain() }
    }

    // MARK: Injection

    private func drain() {
        let (batch, region) = gate.withLock { () -> ([InputEvent], Region?) in
            // Re-checked under the lock: a `deactivate()` between `apply` and
            // here leaves `active` false, and the batch is dropped rather
            // than injected after the revoke.
            guard state.active else {
                state.pending.removeAll()
                return ([], nil)
            }
            let snapshot = state.pending
            state.pending.removeAll()
            return (snapshot, self.region)
        }
        guard !batch.isEmpty, let region else { return }
        for event in RemoteControlPolicy.coalesceMouseMoves(batch) {
            inject(event, region: region)
        }
    }

    private func inject(_ event: InputEvent, region: Region) {
        switch event {
        case .mouseMove(let nx, let ny):
            let point = absolute(nx, ny, region)
            lastAbsolute = point
            emit(.move(x: point.x, y: point.y))

        case .mouseDown(let nx, let ny, let button, _):
            let point = absolute(nx, ny, region)
            lastAbsolute = point
            let index = Self.buttonIndex(button)
            heldButtons.insert(index)
            emit(.button(index: index, down: true, x: point.x, y: point.y))

        case .mouseUp(let nx, let ny, let button, _):
            let point = absolute(nx, ny, region)
            lastAbsolute = point
            let index = Self.buttonIndex(button)
            heldButtons.remove(index)
            emit(.button(index: index, down: false, x: point.x, y: point.y))

        case .scroll(let nx, let ny, let deltaX, let deltaY, _):
            let point = absolute(nx, ny, region)
            lastAbsolute = point
            emit(
                .scroll(
                    wheelY: WindowsPointerMapping.wheelDelta(deltaY),
                    wheelX: WindowsPointerMapping.wheelDelta(deltaX)))

        case .keyDown(let hid, let modifiers):
            injectKey(hid: hid, modifiers: modifiers, down: true)

        case .keyUp(let hid, let modifiers):
            injectKey(hid: hid, modifiers: modifiers, down: false)
        }
    }

    /// Modifiers are injected as REAL KEY EVENTS around the key itself —
    /// unlike macOS, where a `CGEvent` carries modifier flags as a field.
    /// `SendInput` reports the actual keyboard state, so Ctrl+C means press
    /// Ctrl, press C, release C, release Ctrl.
    ///
    /// Pressed before and released after each key rather than tracked across
    /// events, since the wire sends modifier state as a snapshot on every
    /// event (keeping mid-stream joins stateless) with no "modifier down"
    /// message to pair with. Costs a redundant press/release per key in a
    /// held-modifier sequence, but a dropped connection can never strand a
    /// modifier held down.
    ///
    /// Caps Lock is excluded: it's a toggle, so synthesizing a press would
    /// flip the sharer's actual Caps state.
    private func injectKey(hid: UInt16, modifiers: KeyModifiers, down: Bool) {
        // An unmappable HID usage is dropped rather than guessed — the same
        // rule the macOS injector follows, and why `deliberatelyUnmapped`
        // exists in the table.
        guard let key = WindowsKeyCodeMapping.windowsKey(forHIDUsage: hid) else { return }
        let held = Self.modifierKeys(modifiers)

        if down {
            for modifier in held { emit(.key(virtualKey: modifier, extended: false, down: true)) }
        }
        emit(.key(virtualKey: key.virtualKey, extended: key.isExtended, down: down))
        if !down {
            // Reverse order, so a Ctrl+Shift+X release unwinds the way it was
            // built rather than releasing Ctrl while Shift is still down.
            for modifier in held.reversed() {
                emit(.key(virtualKey: modifier, extended: false, down: false))
            }
        }
    }

    /// Queue-confined: release anything still held, at the last known point.
    private func releaseHeldButtons() {
        let held = heldButtons.sorted()
        heldButtons.removeAll()
        for index in held {
            emit(.button(index: index, down: false, x: lastAbsolute.x, y: lastAbsolute.y))
        }
    }

    private func emit(_ action: InjectedAction) {
        if let hook = onInjectForTesting {
            hook(action)
            return
        }
        switch action {
        case .move(let x, let y):
            _ = ts_input_mouse_move(x, y)
        case .button(let index, let down, let x, let y):
            _ = ts_input_mouse_button(x, y, index, down ? 1 : 0)
        case .scroll(let wheelY, let wheelX):
            _ = ts_input_scroll(lastAbsolute.x, lastAbsolute.y, wheelY, wheelX)
        case .key(let virtualKey, let extended, let down):
            _ = ts_input_key(virtualKey, extended ? 1 : 0, down ? 1 : 0)
        }
    }

    private func absolute(_ nx: Double, _ ny: Double, _ region: Region) -> (x: Int32, y: Int32) {
        WindowsPointerMapping.absolutePoint(
            normalizedX: nx, normalizedY: ny,
            in: region, virtualDesktop: virtualDesktopProvider())
    }

    /// Opt this process into per-monitor DPI awareness. Call once, at
    /// startup, before any window exists. Returns whether it ended up aware.
    ///
    /// Every coordinate here is meaningless without it: an unaware process is
    /// told a 150%-scaled 3840x2160 display is 2560x1440, while
    /// Windows.Graphics.Capture reports the physical size, so
    /// `WindowsCaptureRegion` can't match them and the share silently loses
    /// remote control and annotations.
    @discardableResult
    public static func enablePerMonitorDPIAwareness() -> Bool {
        ts_input_enable_per_monitor_dpi() != 0
    }

    /// The real desktop, straight from `GetSystemMetrics`. The default behind
    /// `virtualDesktopProvider`; tests substitute their own.
    public static func virtualDesktop() -> Region {
        var x: Int32 = 0
        var y: Int32 = 0
        var width: Int32 = 0
        var height: Int32 = 0
        ts_input_virtual_desktop(&x, &y, &width, &height)
        return Region(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
    }

    /// Every monitor's bounds, in virtual-desktop coordinates.
    /// `WindowsCaptureRegion` matches a capture item's size against these.
    /// The buffer grows until it fits: the shim returns how many monitors
    /// EXIST, not how many were written, so a truncated list is detectable.
    public static func monitors() -> [Region] {
        var capacity = 8
        for _ in 0..<4 {
            var buffer = [Int32](repeating: 0, count: capacity * 4)
            let total = Int(
                buffer.withUnsafeMutableBufferPointer { pointer in
                    ts_input_monitors(pointer.baseAddress, Int32(capacity))
                })
            if total <= capacity {
                // A plain loop, not `(0..<total).map` with the Int() conversions
                // inline: Swift 6.3's type-checker times out on that closure
                // ("unable to type-check this expression in reasonable time")
                // while 6.1 accepted it — and 6.3 is what the arm64 build uses.
                var regions = [Region]()
                regions.reserveCapacity(total)
                for index in 0..<total {
                    let base = index * 4
                    let x = Int(buffer[base])
                    let y = Int(buffer[base + 1])
                    let width = Int(buffer[base + 2])
                    let height = Int(buffer[base + 3])
                    regions.append(Region(x: x, y: y, width: width, height: height))
                }
                return regions
            }
            capacity = total
        }
        return []
    }

    /// A window's bounds in screen pixels, for a window share's region.
    public static func windowRegion(hwnd: UnsafeMutableRawPointer) -> Region? {
        var x: Int32 = 0
        var y: Int32 = 0
        var width: Int32 = 0
        var height: Int32 = 0
        guard ts_input_window_rect(hwnd, &x, &y, &width, &height) != 0 else { return nil }
        return Region(x: Int(x), y: Int(y), width: Int(width), height: Int(height))
    }

    static func buttonIndex(_ button: InputEvent.MouseButton) -> Int32 {
        switch button {
        case .left: return 0
        case .right: return 1
        case .middle: return 2
        }
    }

    /// The Win32 VK codes for a modifier snapshot, in a stable order.
    ///
    /// Caps Lock is absent on purpose — see `injectKey`.
    static func modifierKeys(_ modifiers: KeyModifiers) -> [UInt16] {
        var keys: [UInt16] = []
        if modifiers.contains(.control) { keys.append(0x11) }  // VK_CONTROL
        if modifiers.contains(.shift) { keys.append(0x10) }  // VK_SHIFT
        if modifiers.contains(.alt) { keys.append(0x12) }  // VK_MENU
        if modifiers.contains(.meta) { keys.append(0x5B) }  // VK_LWIN
        return keys
    }
}
