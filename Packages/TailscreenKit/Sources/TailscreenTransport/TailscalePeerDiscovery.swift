import Foundation
import TailscaleKit
import TailscreenProtocol

/// One Tailscreen installation on the tailnet.
///
/// Identified by hostname prefix (see `TailscreenInstance.isTailscreenServerHostname`)
/// rather than by an active TCP probe — the IPN netmap already tells us
/// which nodes are Tailscreen installations and whether each is currently
/// online, so probing 7447 across every peer is unnecessary latency.
/// `isOnline` reflects tsnet's view of whether the remote node is currently
/// reachable; the rest of the fields are netmap-derived metadata.
public struct TailscreenPeer: Identifiable, Sendable, Equatable {
    public let id: String
    public let hostname: String
    public let dnsName: String
    public let tailscaleIP: String
    public let isOnline: Bool
    /// Tailscale ACL tags ("tag:server") from the netmap — the tag axis of
    /// `PeerListFilter`. Empty for untagged nodes.
    public let tags: [String]
    public var metadata: TailscreenMetadata?
    public var lastSeen: String?
    /// Live WireGuard path snapshot from the LocalAPI status seed: a
    /// non-empty `curAddr` means a direct endpoint is in use; otherwise a
    /// non-empty `relay` names the DERP region carrying traffic. Only the
    /// `backendStatus` seed supplies these (netmap nodes carry no path
    /// info), so `publishMerged` carries them across watcher updates.
    /// `nil` = unknown. Best-effort: relayed paths usually upgrade to
    /// direct once traffic flows.
    public var relay: String?
    public var curAddr: String?
    /// Every Tailscale address of the node (v4 + v6), for the detail
    /// pane; `tailscaleIP` remains the preferred (v4-first) dial target.
    public var tailscaleIPs: [String]
    /// Tailscale StableNodeID — the key `ViewerAccessPolicyStore` uses,
    /// so the UI can show a remembered allow/block. Only the LocalAPI
    /// seed reports it (the netmap watcher carries the *numeric* NodeID,
    /// a different namespace), so like the path fields it's seed-only
    /// and carried across watcher merges. Nil = not yet known.
    public var stableID: String?

    public init(
        id: String, hostname: String, dnsName: String, tailscaleIP: String,
        isOnline: Bool, tags: [String] = [], metadata: TailscreenMetadata? = nil,
        lastSeen: String? = nil, relay: String? = nil, curAddr: String? = nil,
        tailscaleIPs: [String] = [], stableID: String? = nil
    ) {
        self.id = id
        self.hostname = hostname
        self.dnsName = dnsName
        self.tailscaleIP = tailscaleIP
        self.isOnline = isOnline
        self.tags = tags
        self.metadata = metadata
        self.lastSeen = lastSeen
        self.relay = relay
        self.curAddr = curAddr
        self.tailscaleIPs = tailscaleIPs
        self.stableID = stableID
    }
}

/// Lists Tailscreen installations on the local tailnet by filtering the
/// IPN peer set by hostname prefix. No TCP/UDP probes — `peer.isOnline`
/// is sufficient for the menu's active/inactive state because every
/// Tailscreen process registers its tsnet node when it launches and
/// (via `ephemeral: false`) goes offline when it quits.
@MainActor
public class TailscalePeerDiscovery: ObservableObject {
    @Published public var availablePeers: [TailscreenPeer] = []
    @Published public var isDiscovering = false

    private let logger: TSLogger
    private var ipnWatcher: TailscaleIPNWatcher?
    private var monitoringStartInFlight = false

    /// Per-source peer maps, keyed by stable node ID and merged (watcher
    /// wins per node) before publishing. The two sources race: the seed
    /// (`backendStatus`) and the IPN watcher deliver overlapping data at
    /// different times, and an early netmap can be incomplete — right
    /// after login it may carry only the recently-active peers. Letting
    /// either source wholesale-replace the list made the menu churn
    /// (seeded offline rows vanished when a partial netmap landed, then
    /// reappeared on the next seed). A node deleted from the tailnet
    /// leaves `watcherPeers` on the next netmap and `seedPeers` on the
    /// next refresh pass, so it still prunes — just not via a partial
    /// netmap alone.
    private var seedPeers: [String: TailscreenPeer] = [:]
    private var watcherPeers: [String: TailscreenPeer] = [:]

    public init() {
        self.logger = TSLogger()
    }

    /// Seed the peer list from a one-shot `backendStatus()` so the UI has
    /// rows to render before the IPN bus emits its first netmap. Real-time
    /// updates take over once `startRealTimeMonitoring` is called.
    public func startDiscovery(node: TailscaleNode) async throws {
        isDiscovering = true
        defer { isDiscovering = false }

        logger.log("Seeding peer list from backendStatus…")

        let client = LocalAPIClient(localNode: node, logger: logger)

        // Wrap in a watchdog because tsnet's LocalAPI can hang silently
        // when the node exists but its backend hasn't reached Running
        // (e.g. silent session restore still in progress). Without a
        // timeout the discovery spinner never resolves and the menu
        // stays on "Looking for screens…".
        let status = try await Self.withWatchdog(seconds: 5) {
            try await client.backendStatus()
        }
        let allPeers = status.Peer ?? [:]

        var peers: [String: TailscreenPeer] = [:]
        for (_, peerStatus) in allPeers {
            guard TailscreenInstance.isTailscreenServerHostname(peerStatus.HostName) else { continue }
            let key = Self.mergeKey(
                dnsName: peerStatus.DNSName, fallbackID: String(peerStatus.ID))
            peers[key] = TailscreenPeer(
                id: key,
                hostname: Self.displayHostname(
                    dnsName: peerStatus.DNSName, fallback: peerStatus.HostName),
                dnsName: peerStatus.DNSName,
                tailscaleIP: Self.preferIPv4(peerStatus.TailscaleIPs ?? []),
                isOnline: peerStatus.Online,
                tags: peerStatus.Tags ?? [],
                metadata: nil,
                lastSeen: nil,
                relay: peerStatus.Relay,
                curAddr: peerStatus.CurAddr,
                tailscaleIPs: peerStatus.TailscaleIPs ?? [],
                stableID: String(peerStatus.ID)
            )
        }

        seedPeers = peers
        publishMerged()
        logger.log("Seeded \(seedPeers.count) Tailscreen peer(s) from backendStatus")
    }

    /// Start real-time monitoring of peer status using IPN bus.
    /// Idempotent: no-ops when monitoring is already live or a start is
    /// still in flight, so callers can safely re-kick it on every refresh
    /// (the initial fire-and-forget attempt can fail or park when tsnet's
    /// LocalAPI isn't ready yet).
    public func startRealTimeMonitoring(node: TailscaleNode) async throws {
        guard ipnWatcher == nil, !monitoringStartInFlight else { return }
        monitoringStartInFlight = true
        defer { monitoringStartInFlight = false }

        let watcher = TailscaleIPNWatcher()
        // Watchdog: `watchIPNBus` can park indefinitely when tsnet's
        // LocalAPI isn't ready (typical right after launch — exactly when
        // the first discovery runs). Without the timeout a parked start
        // holds `monitoringStartInFlight` forever, and since the discovery
        // object is reused across refreshes, real-time monitoring would
        // stay wedged for the whole session. Timing out clears the flag
        // (via defer) so the next refresh genuinely retries.
        try await Self.withWatchdog(seconds: 5) {
            try await watcher.startWatching(node: node)
        }
        ipnWatcher = watcher

        // Observe peer status changes
        Task { @MainActor [weak self] in
            for await _ in watcher.$peers.values {
                guard let self else { return }
                await self.updatePeerListFromIPNWatcher()
            }
        }

        logger.log("Real-time monitoring started")
    }

    /// Refresh the watcher-side peer map from the watcher's current
    /// snapshot and republish the merged view. Discovers new rows
    /// (offline → online transitions) and updates existing ones; pruning
    /// a node that left the tailnet completes once it's also gone from
    /// the seed side (see `seedPeers`/`watcherPeers`).
    private func updatePeerListFromIPNWatcher() async {
        guard let watcher = ipnWatcher else { return }
        let snapshot = watcher.peers
        var next: [String: TailscreenPeer] = [:]
        for ps in snapshot.values {
            guard TailscreenInstance.isTailscreenServerHostname(ps.hostname) else { continue }
            let key = Self.mergeKey(dnsName: ps.dnsName, fallbackID: ps.nodeID)
            next[key] = TailscreenPeer(
                id: key,
                hostname: Self.displayHostname(dnsName: ps.dnsName, fallback: ps.hostname),
                dnsName: ps.dnsName,
                tailscaleIP: Self.preferIPv4(ps.tailscaleIPs),
                isOnline: ps.online,
                tags: ps.tags,
                metadata: nil,
                lastSeen: ps.lastSeen,
                tailscaleIPs: ps.tailscaleIPs
            )
        }
        watcherPeers = next
        publishMerged()
    }

    /// Publish the union of both sources, watcher winning per node ID
    /// (its data is fresher — live `online` transitions come from it) —
    /// except the WireGuard path fields, which only the seed carries: a
    /// netmap tick must not blank a known relay/direct snapshot.
    private func publishMerged() {
        let merged = seedPeers.merging(watcherPeers) { fromSeed, fromWatcher in
            var peer = fromWatcher
            peer.relay = fromSeed.relay
            peer.curAddr = fromSeed.curAddr
            peer.stableID = fromSeed.stableID
            return peer
        }
        publishIfChanged(Self.sortPeers(Array(merged.values)))
    }

    /// Assign `availablePeers` only when the list actually differs. The IPN
    /// bus ticks on plenty of netmap changes that don't affect our rows
    /// (endpoint updates, unrelated peers); republishing an identical array
    /// still fires `objectWillChange` downstream and re-renders the whole
    /// menubar popover, which reads as flicker while it's open.
    private func publishIfChanged(_ next: [TailscreenPeer]) {
        guard next != availablePeers else { return }
        availablePeers = next
    }

    /// Merge key (and SwiftUI row identity) for a peer. The two sources
    /// report *different* node identifiers — LocalAPI's `PeerStatus.ID`
    /// is the string StableNodeID ("nXXXX…") while a netmap node's `ID`
    /// is the numeric NodeID — so keying each source by its own ID made
    /// the merged union list every node twice. The MagicDNS name is
    /// unique per node and present in both sources; normalize case and
    /// the FQDN trailing dot so both spellings collide.
    public nonisolated static func mergeKey(dnsName: String, fallbackID: String) -> String {
        let normalized = dnsName.lowercased()
        let trimmed =
            normalized.hasSuffix(".") ? String(normalized.dropLast()) : normalized
        return trimmed.isEmpty ? fallbackID : trimmed
    }

    /// Canonical display hostname: the first DNS label. The seed path's
    /// `HostName` (raw hostinfo name, mixed case — "tailscreen-Fredrik's
    /// MacBook Pro (2)") and the watcher's `ComputedName` (DNS-safe
    /// lowercase — "tailscreen-fredriks-macbook-pro-2") differ for the
    /// same node, so a row's text flipped whenever the fresher source
    /// changed — visible churn in an open menu. The DNS label is derived
    /// from the same data on both paths, so identical state renders
    /// byte-identically wherever it came from.
    public nonisolated static func displayHostname(dnsName: String, fallback: String) -> String {
        let label = dnsName.split(separator: ".").first.map(String.init) ?? ""
        return label.isEmpty ? fallback : label
    }

    /// Stop real-time monitoring
    public func stopRealTimeMonitoring() {
        ipnWatcher?.stopWatching()
        ipnWatcher = nil
        logger.log("Real-time monitoring stopped")
    }

    /// Online peers first, then alphabetical within each group. Stable
    /// ordering keeps the menu rows from jumping around when one peer's
    /// state ticks between updates.
    private static func sortPeers(_ peers: [TailscreenPeer]) -> [TailscreenPeer] {
        peers.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline && !b.isOnline }
            return a.hostname.localizedCaseInsensitiveCompare(b.hostname) == .orderedAscending
        }
    }

    /// Pick a dial-safe address from a peer's address list. tsnet's
    /// `tailscale_dial("host:port", …)` does Go-style `net.SplitHostPort`
    /// which requires IPv6 hosts to be bracketed; we pass raw `"host:port"`
    /// everywhere, so any IPv6 entry like `"fd7a:…"` ends up unparseable.
    /// Prefer the first IPv4 (no `:`); fall back to whatever's first only
    /// if the list is IPv6-only.
    public nonisolated static func preferIPv4(_ ips: [String]) -> String {
        ips.first(where: { !$0.contains(":") }) ?? ips.first ?? ""
    }

    /// Runs `operation` in an unstructured `Task.detached` so a blocking C
    /// call (e.g. `tailscale_dial`, the LocalAPI HTTP-over-Unix-socket
    /// roundtrip, the `OutgoingConnection` init's actor handshake) does not
    /// hold a Swift actor-hop continuation open when the calling task is
    /// cancelled or times out.
    ///
    /// Three independent paths race to resume the continuation exactly once:
    ///   1. The unstructured task delivers the operation's result (success or error).
    ///   2. A DispatchQueue watchdog fires after `seconds`, resuming with `TimeoutError`.
    ///   3. `withTaskCancellationHandler`'s `onCancel` fires immediately when the
    ///      calling task is cancelled, resuming with `CancellationError`.
    ///
    /// `ResumeBox` is a resume-once guard that silently drops whichever of the
    /// three arrives second and third.
    public static func withWatchdog<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = ResumeBox<T>()
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                    box.setCont(cont)
                    if Task.isCancelled {
                        box.resume(throwing: CancellationError())
                        return
                    }
                    Task.detached {
                        do {
                            let value = try await operation()
                            box.resume(returning: value)
                        } catch {
                            box.resume(throwing: error)
                        }
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                        box.resume(throwing: TimeoutError())
                    }
                }
            },
            onCancel: { box.resume(throwing: CancellationError()) }
        )
    }
}

// TimeoutError lives in Timeout.swift (platform-portable, part of
// TailscreenProtocol).

// MARK: - Continuation helpers

/// Thread-safe, resume-once wrapper for a `CheckedContinuation<T, Error>`.
///
/// Guards against double-resume when `withWatchdog`'s three racing
/// resumers (operation task, watchdog, cancellation handler) all try to
/// settle the same continuation.
public final class ResumeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?

    /// Called once, synchronously inside `withCheckedThrowingContinuation`.
    public func setCont(_ cont: CheckedContinuation<T, Error>) {
        lock.withLock { self.cont = cont }
    }

    public func resume(returning value: sending T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    public func resume(throwing error: Error) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}

// MARK: - Logger Implementation

private struct TSLogger: LogSink {
    public var logFileHandle: Int32?

    public func log(_ message: String) {
        print("[Discovery] \(message)")
    }
}
