import Foundation

/// Platform-neutral modifier-key state carried by ``InputEvent``. Encodes as
/// its raw bitmask in JSON. Deliberately NOT `CGEventFlags`: the wire speaks
/// a fixed five-bit vocabulary every platform can produce and consume, and
/// each endpoint translates to/from its native flags (mac:
/// `RemoteControlInputView` on capture, `RemoteControlInjector.eventFlags`
/// on injection). Because injection *constructs* native flags from these
/// bits — rather than trusting a raw native bitmask off the wire — a hostile
/// viewer can never set flags outside this set.
public struct KeyModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    /// Option on macOS, Alt elsewhere.
    public static let alt = KeyModifiers(rawValue: 1 << 2)
    /// Command on macOS, Windows/Super key elsewhere.
    public static let meta = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)

    /// Every bit the protocol defines. Injectors translate exactly these and
    /// ignore unknown bits, so the wire value needs no separate masking step.
    public static let allKnown: KeyModifiers = [.shift, .control, .alt, .meta, .capsLock]

    /// Caps Lock's HID keyboard-page usage. Named because it is the one key
    /// here that is a TOGGLE rather than a held modifier — see
    /// ``trackHIDKeyEvent(usage:down:)``.
    public static let capsLockHIDUsage: UInt16 = 0x39

    /// The held modifier a USB HID keyboard-page usage names, or nil if the
    /// usage is an ordinary key.
    ///
    /// The eight modifier usages are 0xE0–0xE7, left and right of each pair.
    /// The wire vocabulary has no left/right distinction on purpose: it names
    /// the modifier's ROLE, and the sharer reconstructs whichever native key
    /// its own platform wants.
    ///
    /// Shared because "these usages are the modifiers" had been written twice
    /// in two different shapes — a range check in the GTK viewer's
    /// `ViewerInputMapping.isModifierUsage`, an exhaustive switch in the WinUI
    /// view's modifier tracker — and two spellings of one table is one edit
    /// away from disagreeing about a key.
    public static func heldModifier(forHIDUsage usage: UInt16) -> KeyModifiers? {
        switch usage {
        case 0xE1, 0xE5: return .shift
        case 0xE0, 0xE4: return .control
        case 0xE2, 0xE6: return .alt
        case 0xE3, 0xE7: return .meta
        default: return nil
        }
    }

    /// Fold a key event into a tracked modifier set, for a host whose pointer
    /// and key events carry no modifier snapshot of their own and must
    /// maintain one.
    ///
    /// - Returns: true when the usage WAS a modifier, so the caller can drop
    ///   the event rather than forwarding it — held modifier state rides every
    ///   event's `modifiers` field, which is what keeps a mid-stream join
    ///   stateless.
    ///
    /// Caps Lock is the case worth reading twice: it is a toggle, so its
    /// down-event means the state FLIPPED and there is no up-event to clear
    /// it. Treating it as a held key latches a phantom Caps Lock forever,
    /// which silently upper-cases everything typed on somebody else's machine.
    public mutating func trackHIDKeyEvent(usage: UInt16, down: Bool) -> Bool {
        if usage == Self.capsLockHIDUsage {
            if down { formSymmetricDifference(.capsLock) }
            return true
        }
        guard let flag = Self.heldModifier(forHIDUsage: usage) else { return false }
        if down {
            insert(flag)
        } else {
            remove(flag)
        }
        return true
    }
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
public enum InputEvent: Codable, Sendable, Equatable {
    case mouseMove(x: Double, y: Double)
    case mouseDown(x: Double, y: Double, button: MouseButton, modifiers: KeyModifiers)
    case mouseUp(x: Double, y: Double, button: MouseButton, modifiers: KeyModifiers)
    /// Scroll deltas in line units (each injector converts to its native
    /// scroll units). `x`/`y` locate the cursor at scroll time.
    case scroll(x: Double, y: Double, deltaX: Double, deltaY: Double, modifiers: KeyModifiers)
    /// `key` is a USB HID keyboard-page usage ID (see type doc).
    case keyDown(key: UInt16, modifiers: KeyModifiers)
    case keyUp(key: UInt16, modifiers: KeyModifiers)

    public enum MouseButton: String, Codable, Sendable {
        case left
        case right
        case middle
    }

    /// True for the high-frequency pointer-move case the coalescer and the
    /// viewer-side throttle may drop under load. Button, scroll and key
    /// events are never dropped.
    public var isMouseMove: Bool {
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
public struct ControlGrant: Equatable, Sendable {
    public let connectionID: UUID
    public let viewerIP: String
    public let stableID: String?
    public var hostname: String?
    public let grantedAt: Date

    public init(connectionID: UUID, viewerIP: String, stableID: String?, hostname: String?, grantedAt: Date) {
        self.connectionID = connectionID
        self.viewerIP = viewerIP
        self.stableID = stableID
        self.hostname = hostname
        self.grantedAt = grantedAt
    }
}

/// Sendable snapshot of the active grant handed to the sharer UI. `nil` when
/// nobody holds control.
public struct ControlGrantInfo: Sendable, Equatable {
    public let connectionID: UUID
    public let viewerIP: String
    public let hostname: String?

    public init(connectionID: UUID, viewerIP: String, hostname: String?) {
        self.connectionID = connectionID
        self.viewerIP = viewerIP
        self.hostname = hostname
    }

    public var displayName: String { hostname ?? viewerIP }
}

/// Viewer-side remote-control mode, surfaced to the viewer UI.
public enum ViewerControlState: Sendable, Equatable {
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
public struct ControlRequestInfo: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let viewerIP: String
    public var hostname: String?
    public let arrivedAt: Date

    public init(id: UUID, viewerIP: String, hostname: String?, arrivedAt: Date) {
        self.id = id
        self.viewerIP = viewerIP
        self.hostname = hostname
        self.arrivedAt = arrivedAt
    }

    public var displayName: String { hostname ?? viewerIP }
}
