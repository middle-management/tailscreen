import Foundation

/// A link a viewer sent with `.openLink`, waiting for the sharer to Open or
/// Dismiss it. Nothing opens without that click (TS-LNK-010).
public struct LinkOfferInfo: Sendable, Identifiable, Hashable {
    public let id: UUID
    /// The control connection it arrived on; offers die with it.
    public let connectionID: UUID
    public let viewerIP: String
    public var hostname: String?
    /// Already passed ``OpenLinkPayload/isAcceptable(_:)``.
    public let url: String
    public let arrivedAt: Date

    public init(
        id: UUID = UUID(), connectionID: UUID, viewerIP: String, hostname: String?,
        url: String, arrivedAt: Date
    ) {
        self.id = id
        self.connectionID = connectionID
        self.viewerIP = viewerIP
        self.hostname = hostname
        self.url = url
        self.arrivedAt = arrivedAt
    }

    public var displayName: String {
        hostname.map { TailscreenInstance.displayName(fromHostname: $0) } ?? viewerIP
    }

    /// The authority (host and optional port), shown on its own in the
    /// prompt so the destination can't hide in a long path.
    public var displayHost: String {
        let afterScheme = url.range(of: "://").map { url[$0.upperBound...] } ?? Substring(url)
        return String(afterScheme.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
    }
}

/// The sharer's pending link offers. One per viewer connection (a newer
/// offer replaces that viewer's older one) and at most ``capacity`` overall,
/// oldest evicted, so a chatty or hostile viewer can't stack prompts.
public struct LinkOfferQueue: Sendable {
    public static let capacity = 4

    public private(set) var offers: [LinkOfferInfo] = []

    public init() {}

    public mutating func add(_ offer: LinkOfferInfo) {
        offers.removeAll { $0.connectionID == offer.connectionID }
        offers.append(offer)
        if offers.count > Self.capacity {
            offers.removeFirst(offers.count - Self.capacity)
        }
    }

    @discardableResult
    public mutating func take(id: UUID) -> LinkOfferInfo? {
        guard let index = offers.firstIndex(where: { $0.id == id }) else { return nil }
        return offers.remove(at: index)
    }

    /// Returns whether anything was removed.
    @discardableResult
    public mutating func removeAll(connectionID: UUID) -> Bool {
        let before = offers.count
        offers.removeAll { $0.connectionID == connectionID }
        return offers.count != before
    }

    public mutating func clear() {
        offers.removeAll()
    }
}
