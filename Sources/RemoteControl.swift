import Foundation

/// One viewer→sharer input event in the opt-in remote-control path. Rides
/// the reliable, ordered TCP control channel (`ScreenShareMessage.inputEvent`)
/// alongside annotations — never the lossy UDP video path — so a `mouseDown`
/// is never delivered without its matching `mouseUp`.
///
/// Pointer coordinates are normalized to `[0, 1]` in the video frame's space
/// with origin top-left, matching ``Annotation`` (`Annotation.swift`). The
/// sharer maps them onto the captured region's live global-Quartz rect per
/// share kind (see ``RemoteControlMapping``). Key events carry the hardware
/// virtual keycode (`CGKeyCode`) plus a `CGEventFlags` modifier bitmask, so
/// keyboard-layout interpretation stays on the sharer's machine.
enum InputEvent: Codable, Sendable, Equatable {
    case mouseMove(x: Double, y: Double)
    case mouseDown(x: Double, y: Double, button: MouseButton)
    case mouseUp(x: Double, y: Double, button: MouseButton)
    /// Scroll deltas in line units (the injector converts to `CGEvent`
    /// scroll units). `x`/`y` locate the cursor at scroll time.
    case scroll(x: Double, y: Double, deltaX: Double, deltaY: Double)
    /// `keyCode` is a `CGKeyCode` (hardware virtual key); `modifiers` is a
    /// raw `CGEventFlags` bitmask.
    case keyDown(keyCode: UInt16, modifiers: UInt64)
    case keyUp(keyCode: UInt16, modifiers: UInt64)

    enum MouseButton: String, Codable, Sendable {
        case left
        case right
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
