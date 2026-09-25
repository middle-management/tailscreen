import Foundation

/// Pure decisions for the remote-control grant gate and event flood control,
/// extracted so the security-critical gate and rate-limit/coalesce logic are
/// unit testable without tsnet or CGEvent.
public enum RemoteControlPolicy {
    /// The authoritative server-side gate: an inbound `InputEvent` may be
    /// injected only when it arrived on the exact TCP connection that holds
    /// the live grant. A NAT rebind (fresh connection, new UUID) can never
    /// inherit a grant. `nil` grant always denies.
    public static func shouldInject(grant: ControlGrant?, connectionID: UUID) -> Bool {
        guard let grant else { return false }
        return grant.connectionID == connectionID
    }

    /// Coalesce a buffered batch of events: collapse each run of consecutive
    /// `mouseMove`s to just its last, passing button/scroll/key events
    /// through untouched. Lets a 120Hz viewer's move flood reduce to one warp
    /// per drain tick without dropping a click or key.
    public static func coalesceMouseMoves(_ events: [InputEvent]) -> [InputEvent] {
        var out: [InputEvent] = []
        out.reserveCapacity(events.count)
        for (i, event) in events.enumerated() {
            if event.isMouseMove, i + 1 < events.count, events[i + 1].isMouseMove {
                // A newer move immediately follows — this one is superseded.
                continue
            }
            out.append(event)
        }
        return out
    }
}

/// Pure sliding-window rate limiter. A hard ceiling on how many events the
/// server forwards to the injector per window — defense against a malicious
/// granted viewer flooding the input path. Not thread-safe; the caller holds
/// it behind a lock.
public struct EventRateLimiter: Sendable {
    public let maxEventsPerWindow: Int
    public let windowNs: UInt64
    private var stampsNs: [UInt64] = []

    /// Default: 600 events/second. Comfortably above a 120 Hz move stream plus
    /// clicks and keystrokes, low enough to blunt a deliberate flood.
    public init(maxEventsPerWindow: Int = 600, windowNs: UInt64 = 1_000_000_000) {
        self.maxEventsPerWindow = maxEventsPerWindow
        self.windowNs = windowNs
    }

    /// Record `nowNs` and report whether the event is within budget. Prunes
    /// stamps older than the window first. Over-budget events return `false`
    /// and are *not* recorded, so a sustained flood stays capped rather than
    /// pinning the window permanently full.
    public mutating func allow(nowNs: UInt64) -> Bool {
        stampsNs.removeAll { nowNs &- $0 > windowNs }
        guard stampsNs.count < maxEventsPerWindow else { return false }
        stampsNs.append(nowNs)
        return true
    }
}
