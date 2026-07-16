import Foundation

/// Pure decisions for the remote-control grant gate and event flood control.
/// Extracted from the async server/injector machinery — the CLAUDE.md
/// extract-the-decision pattern — so the security-critical gate and the
/// rate-limit/coalesce logic are unit testable without tsnet or CGEvent.
public enum RemoteControlPolicy {
    /// The authoritative server-side gate: an inbound `InputEvent` may be
    /// injected only when it arrived on the exact TCP connection that holds
    /// the live grant. Matching purely on `connectionID` means a NAT rebind
    /// (fresh connection, new UUID) can never inherit a grant, and a
    /// non-grantee viewer can't inject even if it crafts events. `nil` grant
    /// (nobody holds control) always denies.
    public static func shouldInject(grant: ControlGrant?, connectionID: UUID) -> Bool {
        guard let grant else { return false }
        return grant.connectionID == connectionID
    }

    /// Coalesce a buffered batch of events: collapse each run of consecutive
    /// `mouseMove`s to just its last (the intermediate positions are stale the
    /// instant a newer one exists), while passing button / scroll / key events
    /// through untouched and in order. Lets a 120 Hz viewer's move flood
    /// reduce to one warp per drain tick without ever dropping a click or key.
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
public struct EventRateLimiter {
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
    /// stamps older than the window first, so the count reflects only the
    /// trailing window. Over-budget events return `false` and are *not*
    /// recorded, so a sustained flood is capped at the ceiling rather than
    /// pinning the window permanently full.
    public mutating func allow(nowNs: UInt64) -> Bool {
        stampsNs.removeAll { nowNs &- $0 > windowNs }
        guard stampsNs.count < maxEventsPerWindow else { return false }
        stampsNs.append(nowNs)
        return true
    }
}
