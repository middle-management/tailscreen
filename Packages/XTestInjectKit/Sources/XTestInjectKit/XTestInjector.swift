import CXTestInject
import Foundation
import TailscreenProtocol

/// Swift face of X11's XTEST extension: the coordinate/keysym translation, the
/// grant gate, and the serial ordering.
///
/// The Linux sibling of `SendInputInjector`; differs in scrolling (X11 has no
/// wheel, only buttons), keys (a *keysym* is portable, a *keycode* is not, so
/// the last hop needs a live display), and the mandatory flush.
///
/// Kept free of the `InputInjecting` conformance so this package does not
/// depend on TailscreenSharer; the conformance is an empty extension in
/// `TailscreenSharerLinux`.
public final class XTestInjector: @unchecked Sendable {
    /// A rectangle on screen — what normalized coordinates are mapped into.
    /// Supplied by the host, not resolved here: today always the X11 root
    /// window; the parameter exists so a future per-window portal share needs
    /// no change here.
    public typealias Region = ScreenRegion

    /// Test seam: what would be injected, without touching the real desktop.
    /// Runs on the serial queue.
    public enum InjectedAction: Equatable, Sendable {
        case motion(x: Int, y: Int)
        case button(number: Int, down: Bool)
        /// `keysym` is the TRANSLATED X11 keysym, not the wire's HID usage.
        case key(keysym: UInt32, down: Bool)
        /// Emitted once per drained batch, so a test can assert that a
        /// press/release pair was actually delivered rather than left queued.
        case flush
    }

    /// When set, actions are recorded here and NOTHING is injected.
    public var onInjectForTesting: ((InjectedAction) -> Void)?

    /// Block until the serial queue has drained everything enqueued so far, so
    /// a test can assert on `onInjectForTesting` without sleeping.
    public func drainSyncForTesting() {
        queue.sync {}
    }

    private let queue = DispatchQueue(label: "dev.tailscreen.xtest-injector")

    /// The gate and the queue share one lock so a revoke is atomic with
    /// enqueueing: once `active` goes false, neither a queued event nor one
    /// that raced it can still be injected.
    private struct GateState {
        var active = false
        var pending: [InputEvent] = []
    }
    private let gate = NSLock()
    private var state = GateState()
    private var region: Region?

    /// Guarded by `connectionLock`, not the gate: opening a display is slow
    /// enough that holding the gate across it would stall `apply`, and the two
    /// protect different things.
    private let connectionLock = NSLock()
    private var handle: UnsafeMutableRawPointer?

    /// The X display this injects into — nil for `$DISPLAY`.
    /// Public: the region normalized coordinates map into is the *capture's*
    /// rectangle, not the root's, and only the host knows how it rounds. See
    /// `TailscreenSharerLinux`'s `InputInjecting` conformance.
    public let displayName: String?

    /// Queue-confined. `deactivate()` must synthesize the matching release, or
    /// a revoke mid-drag leaves a button stuck — worse than other platforms
    /// since a held button grabs the X11 pointer, freezing the desktop.
    private var heldButtons: Set<Int> = []

    /// - Parameter displayName: `nil` for `$DISPLAY`, which is what the app
    ///   passes. Named explicitly by the headless sharer and the tests.
    public init(displayName: String? = nil) {
        self.displayName = displayName
    }

    deinit {
        ts_xtest_close(handle)
    }

    // MARK: Permission

    /// Whether this host can inject at all: whether the display opens AND
    /// carries the XTEST extension (optional; some kiosk/remote X servers omit
    /// it, in which case injection would silently vanish). Under Wayland this
    /// reflects XWayland only — reaches X11 clients, not native Wayland ones.
    public func isTrusted() -> Bool {
        ensureConnection() != nil
    }

    /// Nothing to prompt for on X11. Returns `isTrusted()` so callers written
    /// against the macOS shape behave sensibly.
    @discardableResult
    public func promptForAccess() -> Bool { isTrusted() }

    /// The root window's size, as the default region when the host has nothing
    /// more specific. Nil when the display won't open.
    public func rootRegion() -> Region? {
        guard let handle = ensureConnection() else { return nil }
        var width: Int32 = 0
        var height: Int32 = 0
        ts_xtest_root_size(handle, &width, &height)
        guard width > 0, height > 0 else { return nil }
        return Region(x: 0, y: 0, width: Int(width), height: Int(height))
    }

    /// Where the pointer is right now, in root pixels. Nil when the display
    /// won't open. `XTestFakeMotionEvent` is fire-and-forget, so this is the
    /// only way to confirm injection actually happened; used by
    /// `xtest-probe --live-check`.
    public func pointerPosition() -> (x: Int, y: Int)? {
        guard let handle = ensureConnection() else { return nil }
        var x: Int32 = -1
        var y: Int32 = -1
        ts_xtest_pointer_position(handle, &x, &y)
        guard x >= 0, y >= 0 else { return nil }
        return (Int(x), Int(y))
    }

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
            // here leaves `active` false, and the batch is dropped rather than
            // injected after the revoke.
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
        // Once per batch: X11 queues requests client-side, so without this
        // nothing reaches the server, and a press/release land together.
        emit(.flush)
    }

    private func inject(_ event: InputEvent, region: Region) {
        switch event {
        case .mouseMove(let nx, let ny):
            emitMotion(nx, ny, region)

        case .mouseDown(let nx, let ny, let button, _):
            emitMotion(nx, ny, region)
            let number = X11PointerMapping.buttonNumber(button)
            heldButtons.insert(number)
            emit(.button(number: number, down: true))

        case .mouseUp(let nx, let ny, let button, _):
            emitMotion(nx, ny, region)
            let number = X11PointerMapping.buttonNumber(button)
            heldButtons.remove(number)
            emit(.button(number: number, down: false))

        case .scroll(let nx, let ny, let deltaX, let deltaY, _):
            // Positioned first: X11 delivers a scroll to whatever is under the
            // pointer, so scrolling without moving there scrolls the wrong
            // window.
            emitMotion(nx, ny, region)
            emitScroll(delta: deltaY, axis: .vertical)
            emitScroll(delta: deltaX, axis: .horizontal)

        case .keyDown(let hid, let modifiers):
            injectKey(hid: hid, modifiers: modifiers, down: true)

        case .keyUp(let hid, let modifiers):
            injectKey(hid: hid, modifiers: modifiers, down: false)
        }
    }

    /// One scroll axis as the button presses that perform it: X11 has no wheel
    /// value, so a scroll is button 4/5 (vertical) or 6/7 (horizontal),
    /// press-and-release per notch. `X11PointerMapping.scroll` owns the
    /// delta → count arithmetic (incl. clamping an absurd delta).
    ///
    /// Held buttons are NOT tracked here: each notch is a complete
    /// press+release, so a revoke has nothing to strand.
    private func emitScroll(delta: Double, axis: X11PointerMapping.Axis) {
        guard let scroll = X11PointerMapping.scroll(delta: delta, axis: axis) else { return }
        for _ in 0..<scroll.count {
            emit(.button(number: scroll.button.rawValue, down: true))
            emit(.button(number: scroll.button.rawValue, down: false))
        }
    }

    /// Modifiers are injected as real key events around the key itself: X11,
    /// like Win32, has no per-event modifier field, so Ctrl+C means press
    /// Ctrl, press C, release C, release Ctrl. Pressed/released per key rather
    /// than tracked across events, since there's no "modifier down" message to
    /// pair with — costs a redundant press/release per held-modifier key, but
    /// a dropped connection can never strand a modifier held on the sharer.
    ///
    /// Caps Lock is excluded — a toggle; synthesizing a press would flip the
    /// sharer's actual state and leave it flipped.
    private func injectKey(hid: UInt16, modifiers: KeyModifiers, down: Bool) {
        // Unmappable HID usage: dropped rather than guessed (see `deliberatelyUnmapped`).
        guard let keysym = X11KeyCodeMapping.keysym(forHIDUsage: hid) else { return }
        let held = X11KeyCodeMapping.modifierKeysyms(modifiers)

        if down {
            for modifier in held { emit(.key(keysym: modifier, down: true)) }
        }
        emit(.key(keysym: keysym, down: down))
        if !down {
            // Reverse order, so a Ctrl+Shift+X release unwinds the way it was
            // built rather than releasing Ctrl while Shift is still down.
            for modifier in held.reversed() { emit(.key(keysym: modifier, down: false)) }
        }
    }

    /// Queue-confined: release anything still held. No position is replayed —
    /// X11 releases the button wherever the pointer currently is.
    private func releaseHeldButtons() {
        let held = heldButtons.sorted()
        heldButtons.removeAll()
        guard !held.isEmpty else { return }
        for number in held { emit(.button(number: number, down: false)) }
        emit(.flush)
    }

    private func emitMotion(_ nx: Double, _ ny: Double, _ region: Region) {
        let point = region.point(normalizedX: nx, normalizedY: ny)
        emit(.motion(x: point.x, y: point.y))
    }

    private func emit(_ action: InjectedAction) {
        if let hook = onInjectForTesting {
            hook(action)
            return
        }
        guard let handle = ensureConnection() else { return }
        switch action {
        case .motion(let x, let y):
            ts_xtest_motion(handle, Int32(clamping: x), Int32(clamping: y))
        case .button(let number, let down):
            ts_xtest_button(handle, Int32(number), down ? 1 : 0)
        case .key(let keysym, let down):
            // Return value ignored: an unproducible keysym (e.g. US layout vs
            // Latin-1) is routine, and logging each would be noisy.
            _ = ts_xtest_key(handle, keysym, down ? 1 : 0)
        case .flush:
            ts_xtest_flush(handle)
        }
    }

    /// Open the display on first use and keep it. Lazy since the injector is
    /// constructed at share start even when control may never be granted; nil
    /// is not cached beyond one call, since the display can appear later.
    private func ensureConnection() -> UnsafeMutableRawPointer? {
        connectionLock.withLock {
            if let handle { return handle }
            let opened = displayName.withCString(ts_xtest_open)
            handle = opened
            return opened
        }
    }
}

extension Optional where Wrapped == String {
    /// `withCString` for an optional string, so a nil display name reaches C
    /// as NULL (which Xlib reads as `$DISPLAY`) rather than as an empty string
    /// (which it reads as a malformed display and refuses).
    fileprivate func withCString<Result>(
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let self else { return body(nil) }
        return self.withCString { body($0) }
    }
}
