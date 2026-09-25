import Foundation

/// Which Tailscale path a peer's traffic is currently taking, derived from
/// the LocalAPI status snapshot (`TailscreenPeer.curAddr` / `.relay`).
///
/// A direct endpoint wins over a relay: tsnet reports both fields while a
/// connection is upgrading, and `curAddr` populated is the authoritative
/// "direct path" signal. Empty strings count as absent — LocalAPI reports
/// `""` rather than omitting the key.
///
/// Portable and pinned by `PeerConnectionInfoTests` since all three hubs
/// show this line (GTK/WinUI via `TailscreenHubUI`, which can't import a
/// macOS app target).
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
/// Thresholds are deliberately generous: the measurement is a TCP metadata
/// round-trip (dial + request + service time), not a wire ping, so it reads
/// high vs raw RTT.
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
