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
    /// Deliberately NOT the wire-claimed hostname, which a peer picks itself
    /// and could vary to stack unbounded rows past every cap in this file.
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

/// The sharer's side of "somebody wants me to share": who has asked,
/// coalesced and bounded.
///
/// Portable because all three hosts need it; macOS had grown it inside an
/// AppKit-bound service, leaving Linux/Windows with no incoming-request path
/// at all. Two ways to be quietly wrong, both only visible under an
/// adversary: coalescing on the peer-chosen hostname instead of source IP,
/// or growing unbounded (each row pins an open connection).
///
/// Value type with an injected clock, so both are testable with no node, no
/// network and no window.
public struct ShareRequestInbox: Sendable {
    /// Cap on distinct requesters parked at once — a bound, not a budget.
    /// Past it, new *distinct* requesters are dropped while retries from
    /// peers already listed still coalesce, so a flood can't push out
    /// someone the sharer was about to answer.
    public static let maxPending = 16

    public private(set) var requests: [PendingShareRequest] = []

    public init() {}

    /// Record an incoming request, coalescing a retry from the same peer.
    ///
    /// - Returns: whether the inbox changed, so a host can skip
    ///   republishing when a flood is being dropped.
    ///
    /// A retry keeps the original `id` (the row doesn't flicker in the
    /// sharer's window) but takes the new connection ID, since the old
    /// connection is likely why the peer retried.
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

    /// Drop requests older than `ttlNs`. The requester gives up after a
    /// bounded time, so an outlived row is a button that silently does
    /// nothing — expiring it is more honest than leaving it.
    ///
    /// - Returns: whether anything was dropped.
    @discardableResult
    public mutating func pruneExpired(nowNs: UInt64, ttlNs: UInt64) -> Bool {
        let before = requests.count
        requests.removeAll { nowNs >= $0.receivedAtNs && nowNs - $0.receivedAtNs > ttlNs }
        return requests.count != before
    }

    /// Strip the trailing `:port` (and IPv6 brackets) from a transport
    /// address — retries dial a fresh ephemeral port, so it must not
    /// participate in the key. Splits on the LAST colon (same rule as the
    /// screen-share server), correct for IPv6 like `[fd7a::1]:9999`.
    public static func sourceKey(from addr: String) -> String {
        guard let lastColon = addr.lastIndex(of: ":") else { return addr }
        var ip = String(addr[..<lastColon])
        if ip.hasPrefix("["), ip.hasSuffix("]") {
            ip = String(ip.dropFirst().dropLast())
        }
        return ip
    }
}
