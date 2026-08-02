import CXTestInject
import Foundation
import TailscreenProtocol

/// Swift face of X11's XTEST extension: the coordinate/keysym translation, the
/// grant gate, and the serial ordering.
///
/// The Linux sibling of `SendInputInjector`, deliberately down to the method
/// names and the order of the sections below — the two solve the same problem
/// and every hard-won decision in that file applies here. What differs is
/// documented where it happens; the three that matter are scrolling (X11 has
/// no wheel, only buttons), keys (a *keysym* is portable, a *keycode* is not,
/// so the last hop needs a live display), and the fact that X11 requires an
/// explicit flush or nothing is injected at all.
///
/// Kept free of the `InputInjecting` conformance so this package does not
/// depend on TailscreenSharer; the conformance is an empty extension in
/// `TailscreenSharerLinux`, the same shape macOS and Windows use.
public final class XTestInjector: @unchecked Sendable {
    /// A rectangle on screen — what normalized coordinates are mapped into.
    ///
    /// Supplied by the host rather than resolved here, for the same reason as
    /// on Windows: "what am I sharing" is the host's question. On Linux today
    /// it is always the whole root window, because the X11 backend captures
    /// the root; the parameter exists so the ScreenCast portal's per-window
    /// share (Phase 3.3) needs no change here.
    public typealias Region = ScreenRegion

    /// Test seam: what would be injected, without touching the real desktop.
    ///
    /// Everything below is verifiable except the `XTestFake*` calls, and real
    /// ones would fling the cursor across whatever machine runs the tests —
    /// including a developer's own, since unlike the Windows tests these DO
    /// run on the CI platform. Fires on the serial queue.
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
    /// that raced the revoke can still be injected. Same TOCTOU fix the macOS
    /// and Windows injectors carry.
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
    ///
    /// Public because the host needs it: the region normalized coordinates map
    /// into is the *capture's* rectangle, not the root's, and only the host
    /// knows how its capture backend rounds. See
    /// `TailscreenSharerLinux`'s `InputInjecting` conformance.
    public let displayName: String?

    // Queue-confined pressed-button state. Exists for one reason:
    // `deactivate()` must synthesize the matching release, or a revoke
    // mid-drag leaves a button stuck down on the sharer's desktop with nobody
    // able to let go of it. X11 makes this worse than the other platforms — a
    // held button grabs the pointer, so a stuck one doesn't just misbehave, it
    // makes the whole desktop unusable until something releases it.
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

    /// Whether this host can inject at all.
    ///
    /// Unlike macOS there is no consent to request and unlike Windows there is
    /// no integrity level — on X11 any client that can open the display can
    /// synthesize input, which is a well-known property of the protocol rather
    /// than something this app decides. So the one thing that actually varies
    /// is whether the display opens AND carries the XTEST extension, and both
    /// are answered by trying.
    ///
    /// The XTEST half is the reason this isn't hardcoded `true`: the extension
    /// is optional, some remote and kiosk X servers ship without it, and
    /// without this check the sharer would happily grant control to a viewer
    /// whose every click silently vanishes.
    ///
    /// Under Wayland this returns whatever XWayland reports, which is honest
    /// but limited: injection reaches X11 clients and not native Wayland ones.
    /// The RemoteDesktop portal is the real answer there and is Phase 3.3.
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
    /// won't open.
    ///
    /// The only way to observe that injection actually happened. Injection is
    /// fire-and-forget: `XTestFakeMotionEvent` reports nothing, so without
    /// reading the pointer back there is no way to distinguish "it worked"
    /// from "XTEST is present and the server ignored us" — and a silent
    /// failure is precisely what `isTrusted()` exists to prevent. Used by
    /// `xtest-probe --live-check`, which is the CI gate.
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
        // Once per batch, not per event. X11 queues requests client-side, so
        // without this NOTHING reaches the server — the single most likely way
        // for this whole file to appear broken while every unit test passes.
        // Per batch rather than per event also means a press and its release
        // land together instead of a frame apart.
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

    /// One scroll axis as the button presses that perform it.
    ///
    /// The structural difference from both other platforms: X11's core
    /// protocol has no wheel value at all, so a scroll IS a button
    /// press-and-release — button 4/5 vertically, 6/7 horizontally, once per
    /// notch. `X11PointerMapping.scroll` owns the delta → count arithmetic
    /// (including the clamp that stops a peer's absurd delta becoming a
    /// million synthetic clicks) and is tested without an X server.
    ///
    /// Held buttons are deliberately NOT tracked for these: each notch is a
    /// complete press+release, so there is nothing a revoke could strand.
    private func emitScroll(delta: Double, axis: X11PointerMapping.Axis) {
        guard let scroll = X11PointerMapping.scroll(delta: delta, axis: axis) else { return }
        for _ in 0..<scroll.count {
            emit(.button(number: scroll.button.rawValue, down: true))
            emit(.button(number: scroll.button.rawValue, down: false))
        }
    }

    /// Modifiers are injected as REAL KEY EVENTS around the key itself.
    ///
    /// Same as Windows and for the same reason: X11, like Win32 and unlike
    /// `CGEvent`, has no per-event modifier field — the server reports the
    /// modifier state the keyboard is actually in, so the only way to deliver
    /// Ctrl+C is to press Ctrl, press C, release C, release Ctrl.
    ///
    /// Pressed before and released after each key rather than tracked across
    /// events, because the protocol sends modifier state as a snapshot on
    /// every event instead of as separate key events — which keeps mid-stream
    /// joins stateless, and means there is no "modifier down" message to pair
    /// with. The cost is a redundant press/release per key in a held-modifier
    /// sequence; the benefit is that a dropped connection can never strand a
    /// modifier held down on the sharer's machine.
    ///
    /// Caps Lock is excluded — it is a toggle, so synthesizing a press would
    /// flip the sharer's actual Caps state and leave it flipped.
    private func injectKey(hid: UInt16, modifiers: KeyModifiers, down: Bool) {
        // An unmappable HID usage is dropped rather than guessed — the same
        // rule the other two injectors follow, and why `deliberatelyUnmapped`
        // exists in the table.
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

    /// Queue-confined: release anything still held.
    ///
    /// No position is replayed, unlike Windows: X11 releases the button
    /// wherever the pointer currently is, which is the honest thing to do —
    /// the pointer may have moved for reasons that have nothing to do with the
    /// revoked viewer.
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
            // The return value is deliberately ignored HERE rather than
            // unchecked: a keysym this keymap cannot produce is a routine,
            // expected outcome (a US layout has no key for most of Latin-1),
            // and the shim already declines to inject. Surfacing it would mean
            // a log line per keystroke on a layout mismatch.
            _ = ts_xtest_key(handle, keysym, down ? 1 : 0)
        case .flush:
            ts_xtest_flush(handle)
        }
    }

    /// Open the display on first use and keep it.
    ///
    /// Lazy rather than opened in `init` because the injector is constructed
    /// at share start on hosts that may never grant control, and an X
    /// connection held for a whole share for nothing is a file descriptor and
    /// a server-side client slot. Nil is cached as "not available" only for
    /// this call — a retry is cheap and the display can genuinely appear later
    /// (an X server started after the app).
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
