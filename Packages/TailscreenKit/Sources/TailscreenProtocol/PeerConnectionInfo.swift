import Foundation

/// Which Tailscale path a peer's traffic is currently taking, derived from
/// the LocalAPI status snapshot (`TailscreenPeer.curAddr` / `.relay`).
///
/// A direct endpoint wins over a relay: tsnet reports both fields while a
/// connection is upgrading, and `curAddr` being populated is the
/// authoritative "we have a direct path" signal. Empty strings count as
/// absent — the LocalAPI reports `""` rather than omitting the key when a
/// path isn't established yet.
///
/// Extracted from the peer-detail pane so the classification is pinned by
/// `PeerConnectionInfoTests` rather than living in a view's private
/// computed property, and portable because all three hubs show this line —
/// the GTK and WinUI ones through `TailscreenHubUI`, which cannot import a
/// macOS app target.
public enum PeerRoute: Equatable, Sendable {
    case direct
    /// DERP-relayed, carrying the region code tsnet reported ("fra").
    case relay(region: String)
    /// No path information yet — the status seed hasn't run, or the peer
    /// has never been contacted.
    case unknown

    public static func from(curAddr: String?, relay: String?) -> PeerRoute {
        if let curAddr, !curAddr.isEmpty { return .direct }
        if let relay, !relay.isEmpty { return .relay(region: relay) }
        return .unknown
    }
}

/// Coarse latency tier behind the peer-detail pane's quality dot.
///
/// Thresholds are deliberately generous: the measurement is a TCP
/// metadata round-trip over the live Tailscale path (dial + request +
/// service time), not a wire ping, so it reads high compared to a raw
/// RTT. `good` is "same-city direct", `fair` covers typical
/// cross-country or freshly-relayed paths, `poor` is where a share will
/// visibly suffer.
public enum ConnectionQualityTier: Equatable, Sendable {
    case good
    case fair
    case poor

    /// Exclusive upper bound of `.good`, in milliseconds.
    public static let goodBelowMs = 60
    /// Exclusive upper bound of `.fair`, in milliseconds.
    public static let fairBelowMs = 150

    public static func forLatency(ms: Int) -> ConnectionQualityTier {
        if ms < goodBelowMs { return .good }
        if ms < fairBelowMs { return .fair }
        return .poor
    }
}
