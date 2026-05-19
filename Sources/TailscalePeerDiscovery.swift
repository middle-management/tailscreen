import Foundation
import TailscaleKit

/// Represents a discovered peer on the Tailscale network
struct TailscreenPeer: Identifiable, Sendable {
    let id: String
    let hostname: String
    let dnsName: String
    let tailscaleIP: String
    let isOnline: Bool
    var isRunningTailscreen: Bool
    var metadata: TailscreenMetadata?
    var lastSeen: Date?
}

/// Discovers Tailscreen instances running on the Tailscale network
@MainActor
class TailscalePeerDiscovery: ObservableObject {
    @Published var availablePeers: [TailscreenPeer] = []
    @Published var isDiscovering = false

    private let tailscreenPort: UInt16 = NetworkConfig.tailscreenPort
    private let logger: TSLogger
    private var ipnWatcher: TailscaleIPNWatcher?

    init() {
        self.logger = TSLogger()
    }

    /// Discovers all peers on the tailnet and checks which ones are running Tailscreen
    func startDiscovery(node: TailscaleNode) async throws {
        isDiscovering = true
        defer { isDiscovering = false }

        logger.log("🔍 Starting peer discovery...")

        // Create LocalAPI client
        let client = LocalAPIClient(localNode: node, logger: logger)

        // Get tailnet status. Wrapped in a watchdog because tsnet's
        // LocalAPI can hang silently when the node exists but its
        // backend hasn't reached Running (e.g. silent session restore
        // still in progress). Without a timeout the discovery spinner
        // never resolves and the menu stays on "Looking for screens…".
        logger.log("📡 Querying backendStatus()…")
        let status = try await Self.withWatchdog(seconds: 5) {
            try await client.backendStatus()
        }
        logger.log("📡 backendStatus() returned")

        logger.log("📡 Found \(status.Peer?.count ?? 0) peers on tailnet")

        var peers: [TailscreenPeer] = []

        // Process each peer
        for (peerKey, peerStatus) in status.Peer ?? [:] {
            guard peerStatus.Online else { continue }

            let peer = TailscreenPeer(
                id: peerKey,
                hostname: peerStatus.HostName,
                dnsName: peerStatus.DNSName,
                tailscaleIP: peerStatus.TailscaleIPs?.first ?? "",
                isOnline: peerStatus.Online,
                isRunningTailscreen: false,
                metadata: nil,
                lastSeen: nil
            )

            peers.append(peer)
        }

        logger.log("✓ Found \(peers.count) online peers")

        // Check which peers are running Tailscreen (in parallel).
        // Uses the existing node to dial; must NOT spin up a new TailscaleNode
        // per probe — that takes several seconds per peer and blows the 2s timeout.
        logger.log("→ awaiting node.tailscale handle…")
        guard let tailscaleHandle = await node.tailscale else {
            logger.log("⚠️ node has no tailscale handle; skipping Tailscreen probe")
            availablePeers = []
            return
        }
        logger.log("→ got tailscale handle; probing \(peers.count) peer(s)")

        var updatedPeers: [TailscreenPeer] = []

        for peer in peers {
            logger.log("→ probing \(peer.hostname) @ \(peer.tailscaleIP):\(tailscreenPort)")
        }
        await withTaskGroup(of: (String, Bool).self) { group in
            for peer in peers {
                let ip = peer.tailscaleIP
                let id = peer.id
                group.addTask {
                    let isRunning = await Self.probeTailscreenPort(
                        tailscale: tailscaleHandle,
                        host: ip,
                        port: self.tailscreenPort,
                        logger: self.logger
                    )
                    return (id, isRunning)
                }
            }

            var tailscreenStatus: [String: Bool] = [:]
            for await (peerId, isRunning) in group {
                tailscreenStatus[peerId] = isRunning
            }

            // Update peers with Tailscreen status
            for var peer in peers {
                peer.isRunningTailscreen = tailscreenStatus[peer.id] ?? false
                updatedPeers.append(peer)
            }
        }

        // Only show peers that are running Tailscreen
        let tailscreenPeers = updatedPeers.filter { $0.isRunningTailscreen }

        logger.log("🎯 Found \(tailscreenPeers.count) peers running Tailscreen")

        availablePeers = tailscreenPeers
    }

    /// Opens a raw TCP connection to `host:port` over the provided tsnet handle.
    /// Uses the caller's live node — never spins up a new one per probe.
    ///
    /// The timeout is intentionally generous: on a cold netmap, the very first
    /// dial to a peer can block a few seconds while tsnet sorts out the path,
    /// and a 2s window produced false negatives where the dial eventually
    /// succeeded server-side but after discovery had already given up.
    private static func probeTailscreenPort(
        tailscale: TailscaleHandle,
        host: String,
        port: UInt16,
        logger: LogSink
    ) async -> Bool {
        do {
            // `OutgoingConnection.init` is also wrapped in a watchdog —
            // not just `.connect()` — because the init itself can park
            // in tsnet code on a degraded netmap, and the connect-level
            // 8 s watchdog only fires after we get past init. Without
            // this, a single bad peer would hang the whole probe group
            // and keep the discovery spinner up indefinitely.
            //
            // The closure runs in `Task.detached`, so capture only
            // Sendable values — `logger` is a `LogSink` existential
            // that may not be Sendable, so construct a fresh
            // `TSLogger` (a Sendable struct) inside the closure.
            let target = "\(host):\(port)"
            let conn = try await withWatchdog(seconds: 5) {
                try await OutgoingConnection(
                    tailscale: tailscale,
                    to: target,
                    proto: .tcp,
                    logger: TSLogger()
                )
            }
            try await connectOrTimeout(conn: conn, seconds: 8)
            await conn.close()
            logger.log("✓ \(host):\(port) is running Tailscreen")
            return true
        } catch {
            // Log the reason so silent-negatives (wrong netmap, DERP fail,
            // ACL deny, peer not listening, timeout) are distinguishable.
            logger.log("✗ \(host):\(port) probe failed: \(error)")
            return false
        }
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
    private static func withWatchdog<T: Sendable>(
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

    /// Thin shim that wraps `conn.connect()` in `withWatchdog`. Kept as a
    /// named entry point so the probe site reads obviously.
    private static func connectOrTimeout(conn: OutgoingConnection, seconds: Double) async throws {
        try await withWatchdog(seconds: seconds) {
            try await conn.connect()
        }
    }

    /// Start real-time monitoring of peer status using IPN bus
    func startRealTimeMonitoring(node: TailscaleNode) async throws {
        // Create and start IPN watcher
        let watcher = TailscaleIPNWatcher()
        ipnWatcher = watcher

        try await watcher.startWatching(node: node)

        // Observe peer status changes
        Task { @MainActor in
            for await _ in watcher.$peers.values {
                // When peers change, update our peer list
                await updatePeerListFromIPNWatcher()
            }
        }

        logger.log("✓ Real-time monitoring started")
    }

    /// Update peer list based on IPN watcher data
    private func updatePeerListFromIPNWatcher() async {
        guard let watcher = ipnWatcher else { return }

        // Update online status for existing peers
        for i in availablePeers.indices {
            if let peerStatus = watcher.peers[availablePeers[i].id] {
                let updatedPeer = availablePeers[i]
                // Create new peer with updated status
                availablePeers[i] = TailscreenPeer(
                    id: updatedPeer.id,
                    hostname: peerStatus.hostname,
                    dnsName: peerStatus.dnsName,
                    tailscaleIP: peerStatus.tailscaleIPs.first ?? updatedPeer.tailscaleIP,
                    isOnline: peerStatus.online,
                    isRunningTailscreen: updatedPeer.isRunningTailscreen,
                    metadata: updatedPeer.metadata,
                    lastSeen: peerStatus.online ? Date() : updatedPeer.lastSeen
                )
            }
        }
    }

    /// Stop real-time monitoring
    func stopRealTimeMonitoring() {
        ipnWatcher?.stopWatching()
        ipnWatcher = nil
        logger.log("✓ Real-time monitoring stopped")
    }

    /// Fetch metadata for a specific peer
    func fetchMetadata(for peer: TailscreenPeer) async -> TailscreenMetadata? {
        do {
            let metadata = try await TailscreenMetadataService.fetchMetadata(
                from: peer.tailscaleIP,
                port: tailscreenPort
            )
            return metadata
        } catch {
            logger.log(
                "Failed to fetch metadata from \(peer.hostname): \(error.localizedDescription)")
            return nil
        }
    }
}

struct TimeoutError: Error {}

// MARK: - Continuation helpers

/// Thread-safe, resume-once wrapper for a `CheckedContinuation<T, Error>`.
///
/// Guards against double-resume when `withWatchdog`'s three racing
/// resumers (operation task, watchdog, cancellation handler) all try to
/// settle the same continuation.
private final class ResumeBox<T>: @unchecked Sendable {
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
