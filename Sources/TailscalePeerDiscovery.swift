import Foundation
import TailscaleKit

/// One Tailscreen installation on the tailnet.
///
/// Identified by hostname prefix (see `TailscreenInstance.isTailscreenServerHostname`)
/// rather than by an active TCP probe — the IPN netmap already tells us
/// which nodes are Tailscreen installations and whether each is currently
/// online, so probing 7447 across every peer is unnecessary latency.
/// `isOnline` reflects tsnet's view of whether the remote node is currently
/// reachable; the rest of the fields are netmap-derived metadata.
struct TailscreenPeer: Identifiable, Sendable, Equatable {
    let id: String
    let hostname: String
    let dnsName: String
    let tailscaleIP: String
    let isOnline: Bool
    var metadata: TailscreenMetadata?
    var lastSeen: String?
}

/// Lists Tailscreen installations on the local tailnet by filtering the
/// IPN peer set by hostname prefix. No TCP/UDP probes — `peer.isOnline`
/// is sufficient for the menu's active/inactive state because every
/// Tailscreen process registers its tsnet node when it launches and
/// (via `ephemeral: false`) goes offline when it quits.
@MainActor
class TailscalePeerDiscovery: ObservableObject {
    @Published var availablePeers: [TailscreenPeer] = []
    @Published var isDiscovering = false

    private let logger: TSLogger
    private var ipnWatcher: TailscaleIPNWatcher?
    private var monitoringStartInFlight = false

    init() {
        self.logger = TSLogger()
    }

    /// Seed the peer list from a one-shot `backendStatus()` so the UI has
    /// rows to render before the IPN bus emits its first netmap. Real-time
    /// updates take over once `startRealTimeMonitoring` is called.
    func startDiscovery(node: TailscaleNode) async throws {
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

        var peers: [TailscreenPeer] = []
        for (_, peerStatus) in allPeers {
            guard TailscreenInstance.isTailscreenServerHostname(peerStatus.HostName) else { continue }
            // Key on `String(peerStatus.ID)` (stable node ID) so seed rows
            // share an Identifiable id with the IPN-watcher rebuild path;
            // the LocalAPI map key is the public node key and would shift
            // the id when the watcher takes over.
            peers.append(
                TailscreenPeer(
                    id: String(peerStatus.ID),
                    hostname: peerStatus.HostName,
                    dnsName: peerStatus.DNSName,
                    tailscaleIP: Self.preferIPv4(peerStatus.TailscaleIPs ?? []),
                    isOnline: peerStatus.Online,
                    metadata: nil,
                    lastSeen: nil
                ))
        }

        publishIfChanged(Self.sortPeers(peers))
        logger.log("Seeded \(availablePeers.count) Tailscreen peer(s) from netmap")
    }

    /// Start real-time monitoring of peer status using IPN bus.
    /// Idempotent: no-ops when monitoring is already live or a start is
    /// still in flight, so callers can safely re-kick it on every refresh
    /// (the initial fire-and-forget attempt can fail or park when tsnet's
    /// LocalAPI isn't ready yet).
    func startRealTimeMonitoring(node: TailscaleNode) async throws {
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

    /// Rebuild `availablePeers` from the watcher's current peer map. This
    /// is the source of truth once monitoring is live — it discovers new
    /// rows (offline → online transitions) and prunes peers that have left
    /// the netmap entirely, not just refreshes existing rows.
    private func updatePeerListFromIPNWatcher() async {
        guard let watcher = ipnWatcher else { return }
        let snapshot = watcher.peers
        let next: [TailscreenPeer] = snapshot.values
            .filter { TailscreenInstance.isTailscreenServerHostname($0.hostname) }
            .map { ps in
                TailscreenPeer(
                    id: ps.nodeID,
                    hostname: ps.hostname,
                    dnsName: ps.dnsName,
                    tailscaleIP: Self.preferIPv4(ps.tailscaleIPs),
                    isOnline: ps.online,
                    metadata: nil,
                    lastSeen: ps.lastSeen
                )
            }
        publishIfChanged(Self.sortPeers(next))
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

    /// Stop real-time monitoring
    func stopRealTimeMonitoring() {
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
    nonisolated static func preferIPv4(_ ips: [String]) -> String {
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
    static func withWatchdog<T: Sendable>(
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

struct TimeoutError: Error {}

// MARK: - Continuation helpers

/// Thread-safe, resume-once wrapper for a `CheckedContinuation<T, Error>`.
///
/// Guards against double-resume when `withWatchdog`'s three racing
/// resumers (operation task, watchdog, cancellation handler) all try to
/// settle the same continuation.
final class ResumeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?

    /// Called once, synchronously inside `withCheckedThrowingContinuation`.
    func setCont(_ cont: CheckedContinuation<T, Error>) {
        lock.withLock { self.cont = cont }
    }

    func resume(returning value: sending T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}

// MARK: - Logger Implementation

private struct TSLogger: LogSink {
    var logFileHandle: Int32?

    func log(_ message: String) {
        print("[Discovery] \(message)")
    }
}
