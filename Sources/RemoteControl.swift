import Foundation

/// Platform-neutral modifier-key state carried by ``InputEvent``. Encodes as
/// its raw bitmask in JSON. Deliberately NOT `CGEventFlags`: the wire speaks
/// a fixed five-bit vocabulary every platform can produce and consume, and
/// each endpoint translates to/from its native flags (mac:
/// `RemoteControlInputView` on capture, `RemoteControlInjector.eventFlags`
/// on injection). Because injection *constructs* native flags from these
/// bits — rather than trusting a raw native bitmask off the wire — a hostile
/// viewer can never set flags outside this set.
struct KeyModifiers: OptionSet, Codable, Sendable, Hashable {
    let rawValue: UInt16

    static let shift = KeyModifiers(rawValue: 1 << 0)
    static let control = KeyModifiers(rawValue: 1 << 1)
    /// Option on macOS, Alt elsewhere.
    static let alt = KeyModifiers(rawValue: 1 << 2)
    /// Command on macOS, Windows/Super key elsewhere.
    static let meta = KeyModifiers(rawValue: 1 << 3)
    static let capsLock = KeyModifiers(rawValue: 1 << 4)

    /// Every bit the protocol defines. Injectors translate exactly these and
    /// ignore unknown bits, so the wire value needs no separate masking step.
    static let allKnown: KeyModifiers = [.shift, .control, .alt, .meta, .capsLock]
}

/// One viewer→sharer input event in the opt-in remote-control path. Rides
/// the reliable, ordered TCP control channel (`ScreenShareMessage.inputEvent`)
/// alongside annotations — never the lossy UDP video path — so a `mouseDown`
/// is never delivered without its matching `mouseUp`.
///
/// Pointer coordinates are normalized to `[0, 1]` in the video frame's space
/// with origin top-left, matching ``Annotation`` (`Annotation.swift`). The
/// sharer maps them onto the captured region's live rect per share kind (see
/// ``RemoteControlMapping``).
///
/// Key events are platform-neutral: `key` is a **USB HID keyboard-page
/// (0x07) usage ID** — the one keycode vocabulary every platform ships
/// translation tables for — and `modifiers` is a ``KeyModifiers`` snapshot
/// of the held modifier state. Keyboard-layout interpretation stays on the
/// sharer's machine (the sharer translates HID usage → its native keycode;
/// see `MacKeyCodeMapping`). Modifier keys themselves are not sent as
/// standalone key events; their state rides every key/button/scroll event,
/// which keeps mid-stream joins and lost-connection recovery stateless.
///
/// `mouseDown`/`mouseUp`/`scroll` carry `modifiers` too, so modified clicks
/// (⌘-click, shift-scroll) work; `mouseMove` doesn't (it's the coalescable
/// high-frequency case, and a drag's modifiers land with its button events).
enum InputEvent: Codable, Sendable, Equatable {
    case mouseMove(x: Double, y: Double)
    case mouseDown(x: Double, y: Double, button: MouseButton, modifiers: KeyModifiers)
    case mouseUp(x: Double, y: Double, button: MouseButton, modifiers: KeyModifiers)
    /// Scroll deltas in line units (each injector converts to its native
    /// scroll units). `x`/`y` locate the cursor at scroll time.
    case scroll(x: Double, y: Double, deltaX: Double, deltaY: Double, modifiers: KeyModifiers)
    /// `key` is a USB HID keyboard-page usage ID (see type doc).
    case keyDown(key: UInt16, modifiers: KeyModifiers)
    case keyUp(key: UInt16, modifiers: KeyModifiers)

    enum MouseButton: String, Codable, Sendable {
        case left
        case right
        case middle
    }

    /// True for the high-frequency pointer-move case the coalescer and the
    /// viewer-side throttle may drop under load. Button, scroll and key
    /// events are never dropped.
    var isMouseMove: Bool {
        if case .mouseMove = self { return true }
        return false
    }
}

/// The live single-viewer control grant held by the sharer. The gate that
/// admits an inbound `InputEvent` matches purely on `connectionID` (the TCP
/// control connection the grantee dialed) — authoritative and unspoofable,
/// and a NAT rebind produces a fresh connection with a new UUID so a grant
/// can never be inherited. `stableID` pins the grant to the consent
/// allow-list identity for UI + bookkeeping; `viewerIP` labels the sharer UI
/// and lets the UDP-disconnect revoke hooks match by source IP.
struct ControlGrant: Equatable, Sendable {
    let connectionID: UUID
    let viewerIP: String
    let stableID: String?
    var hostname: String?
    let grantedAt: Date
}

/// Sendable snapshot of the active grant handed to the sharer UI. `nil` when
/// nobody holds control.
struct ControlGrantInfo: Sendable, Equatable {
    let connectionID: UUID
    let viewerIP: String
    let hostname: String?

    var displayName: String { hostname ?? viewerIP }
}

/// Viewer-side remote-control mode, surfaced to the viewer UI.
enum ViewerControlState: Sendable, Equatable {
    /// Not requesting or holding control.
    case none
    /// Requested control; awaiting the sharer's answer.
    case requested
    /// Granted — the input-capture layer is live and driving the sharer.
    case controlling
}

/// A viewer that asked for control and is awaiting the sharer's Grant / Deny.
/// `id` is the TCP control connection's UUID — the same handle the grant and
/// the input-event gate key on.
struct ControlRequestInfo: Sendable, Identifiable, Hashable {
    let id: UUID
    let viewerIP: String
    var hostname: String?
    let arrivedAt: Date

    var displayName: String { hostname ?? viewerIP }
}
