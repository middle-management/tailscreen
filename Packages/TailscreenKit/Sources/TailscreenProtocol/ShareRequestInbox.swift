import Foundation

/// A peer asking this machine to share its screen, as a host needs to render it.
///
/// `connectionID` is the `TailscreenControlListener` connection the request
/// arrived on, and the answer goes back **on that same connection** rather than
/// by dialling the requester — which is what makes the answer provably reach
/// the peer that actually asked, instead of whoever currently answers at a
/// claimed hostname.
public struct PendingShareRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// What the requester called itself. Display only — never a key. See
    /// `sourceKey`.
    public let fromHostname: String
    /// Monotonic receipt time, host-supplied. Newest last.
    public let receivedAtNs: UInt64
    public let connectionID: UUID?
    /// The coalescing key: the requester's source IP with the port stripped.
    ///
    /// Deliberately NOT the wire-claimed hostname. A peer picks its own
    /// hostname, so keying on it lets one machine vary the string to stack
    /// unbounded rows — each pinning a 120-second connection on the far side —
    /// past every cap in this file. The IP is the one identifier the requester
    /// does not choose.
    public let sourceKey: String

    public init(
        id: UUID = UUID(), fromHostname: String, receivedAtNs: UInt64,
        connectionID: UUID? = nil, sourceKey: String
    ) {
        self.id = id
        self.fromHostname = fromHostname
        self.receivedAtNs = receivedAtNs
        self.connectionID = connectionID
        self.sourceKey = sourceKey
    }
}

/// The sharer's side of "somebody wants me to share": who has asked, coalesced
/// and bounded.
///
/// Portable because all three hosts need exactly this and macOS grew it inside
/// an AppKit-bound service (`TailscreenMetadataService`), where `NSScreen` and
/// `Host.current()` kept it from being reused — so the Linux and Windows apps
/// had no incoming-request path at all. The logic is arithmetic over a small
/// array and has two ways to be quietly wrong, both of which are only visible
/// under an adversary:
///
///   * **Coalescing on the wrong key.** A retry after a flaky dial must replace
///     the existing row rather than add one, and the natural-looking key — the
///     hostname in the payload — is chosen by the peer.
///   * **Growing without a bound.** Each row corresponds to a connection the
///     requester holds open awaiting an answer, so an uncapped inbox is a way
///     to make a sharer's window unusable from off-machine.
///
/// A value type with an injected clock, so both are testable with no node, no
/// network and no window.
public struct ShareRequestInbox: Sendable {
    /// Cap on distinct requesters parked at once.
    ///
    /// Sixteen is well past any real use — it is a bound, not a budget. Past
    /// it, new *distinct* requesters are dropped while retries from peers
    /// already in the list still coalesce, so a flood cannot push out somebody
    /// the sharer was about to answer.
    public static let maxPending = 16

    public private(set) var requests: [PendingShareRequest] = []

    public init() {}

    /// Record an incoming request, coalescing a retry from the same peer.
    ///
    /// - Returns: whether the inbox changed, so a host can skip republishing
    ///   (and re-notifying) when a flood is being dropped.
    ///
    /// A retry keeps the original `id` — the row does not flicker out and back
    /// in the sharer's window — but takes the new connection ID, because the
    /// old connection is most likely why the peer retried and an answer sent
    /// down it would reach nobody.
    @discardableResult
    public mutating func record(
        fromHostname: String, sourceAddr: String?, connectionID: UUID?, nowNs: UInt64
    ) -> Bool {
        let key = sourceAddr.map { Self.sourceKey(from: $0) } ?? "host:\(fromHostname)"
        if let index = requests.firstIndex(where: { $0.sourceKey == key }) {
            let existing = requests.remove(at: index)
            // Re-appended rather than updated in place: the list is ordered
            // oldest-first and a peer that just asked again is the newest
            // thing in it.
            requests.append(
                PendingShareRequest(
                    id: existing.id, fromHostname: fromHostname, receivedAtNs: nowNs,
                    connectionID: connectionID ?? existing.connectionID, sourceKey: key))
            return true
        }
        guard requests.count < Self.maxPending else { return false }
        requests.append(
            PendingShareRequest(
                fromHostname: fromHostname, receivedAtNs: nowNs,
                connectionID: connectionID, sourceKey: key))
        return true
    }

    /// Drop one answered request, returning it so the caller can address the
    /// answer to its connection.
    @discardableResult
    public mutating func remove(id: UUID) -> PendingShareRequest? {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return nil }
        return requests.remove(at: index)
    }

    /// Drop everything — the sharer started a share, or signed out.
    public mutating func removeAll() {
        requests.removeAll()
    }

    /// Drop requests older than `ttlNs`.
    ///
    /// The requester waits a bounded time and then gives up, so a row that has
    /// outlived that window is a button which silently does nothing. Expiring
    /// it is more honest than leaving it: a sharer who presses Share for a peer
    /// that stopped listening gets a share nobody joins, and no clue why.
    ///
    /// - Returns: whether anything was dropped.
    @discardableResult
    public mutating func pruneExpired(nowNs: UInt64, ttlNs: UInt64) -> Bool {
        let before = requests.count
        requests.removeAll { nowNs >= $0.receivedAtNs && nowNs - $0.receivedAtNs > ttlNs }
        return requests.count != before
    }

    /// Strip the trailing `:port` (and IPv6 brackets) from a transport address.
    ///
    /// Retries dial a fresh ephemeral source port, so the port is exactly the
    /// part that must not participate in the key. Same split-on-LAST-colon rule
    /// the screen-share server uses, which is what makes it right for IPv6:
    /// `[fd7a::1]:9999` has colons throughout and only the final one separates
    /// the port.
    public static func sourceKey(from addr: String) -> String {
        guard let lastColon = addr.lastIndex(of: ":") else { return addr }
        var ip = String(addr[..<lastColon])
        if ip.hasPrefix("["), ip.hasSuffix("]") {
            ip = String(ip.dropFirst().dropLast())
        }
        return ip
    }
}
