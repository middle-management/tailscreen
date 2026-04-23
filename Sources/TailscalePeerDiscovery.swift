import Foundation
import TailscaleKit

/// Represents a discovered peer on the Tailscale network
struct CuplePeer: Identifiable, Sendable {
    let id: String
    let hostname: String
    let dnsName: String
    let tailscaleIP: String
    let isOnline: Bool
    var isRunningCuple: Bool
    var metadata: CupleMetadata?
    var lastSeen: Date?
}

/// Discovers Cuple instances running on the Tailscale network
@MainActor
class TailscalePeerDiscovery: ObservableObject {
    @Published var availablePeers: [CuplePeer] = []
    @Published var isDiscovering = false

    private let cuplePort: UInt16 = 7447
    private let logger: TSLogger
    private var ipnWatcher: TailscaleIPNWatcher?

    init() {
        self.logger = TSLogger()
    }

    /// Discovers all peers on the tailnet and checks which ones are running Cuple
    func startDiscovery(node: TailscaleNode) async throws {
        isDiscovering = true
        defer { isDiscovering = false }

        logger.log("🔍 Starting peer discovery...")

        // Create LocalAPI client
        let client = LocalAPIClient(localNode: node, logger: logger)

        // Get tailnet status
        let status = try await client.backendStatus()

        logger.log("📡 Found \(status.Peer?.count ?? 0) peers on tailnet")

        var peers: [CuplePeer] = []

        // Process each peer
        for (peerKey, peerStatus) in status.Peer ?? [:] {
            guard peerStatus.Online else { continue }

            let peer = CuplePeer(
                id: peerKey,
                hostname: peerStatus.HostName,
                dnsName: peerStatus.DNSName,
                tailscaleIP: peerStatus.TailscaleIPs?.first ?? "",
                isOnline: peerStatus.Online,
                isRunningCuple: false,
                metadata: nil,
                lastSeen: nil
            )

            peers.append(peer)
        }

        logger.log("✓ Found \(peers.count) online peers")

        // Check which peers are running Cuple (in parallel).
        // Uses the existing node to dial; must NOT spin up a new TailscaleNode
        // per probe — that takes several seconds per peer and blows the 2s timeout.
        guard let tailscaleHandle = await node.tailscale else {
            logger.log("⚠️ node has no tailscale handle; skipping Cuple probe")
            availablePeers = []
            return
        }

        var updatedPeers: [CuplePeer] = []

        for peer in peers {
            logger.log("→ probing \(peer.hostname) @ \(peer.tailscaleIP):\(cuplePort)")
        }
        await withTaskGroup(of: (String, Bool).self) { group in
            for peer in peers {
                let ip = peer.tailscaleIP
                let id = peer.id
                group.addTask {
                    let isRunning = await Self.probeCuplePort(
                        tailscale: tailscaleHandle,
                        host: ip,
                        port: self.cuplePort,
                        logger: self.logger
                    )
                    return (id, isRunning)
                }
            }

            var cupleStatus: [String: Bool] = [:]
            for await (peerId, isRunning) in group {
                cupleStatus[peerId] = isRunning
            }

            // Update peers with Cuple status
            for var peer in peers {
                peer.isRunningCuple = cupleStatus[peer.id] ?? false
                updatedPeers.append(peer)
            }
        }

        // Only show peers that are running Cuple
        let cuplePeers = updatedPeers.filter { $0.isRunningCuple }

        logger.log("🎯 Found \(cuplePeers.count) peers running Cuple")

        availablePeers = cuplePeers
    }

    /// Opens a raw TCP connection to `host:port` over the provided tsnet handle.
    /// Uses the caller's live node — never spins up a new one per probe.
    ///
    /// The timeout is intentionally generous: on a cold netmap, the very first
    /// dial to a peer can block a few seconds while tsnet sorts out the path,
    /// and a 2s window produced false negatives where the dial eventually
    /// succeeded server-side but after discovery had already given up.
    private static func probeCuplePort(
        tailscale: TailscaleHandle,
        host: String,
        port: UInt16,
        logger: LogSink
    ) async -> Bool {
        do {
            let conn = try await OutgoingConnection(
                tailscale: tailscale,
                to: "\(host):\(port)",
                proto: .tcp,
                logger: logger
            )
            let connected: Void = try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await conn.connect() }
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    throw TimeoutError()
                }
                defer { group.cancelAll() }
                _ = try await group.next()
                return ()
            }
            _ = connected
            await conn.close()
            logger.log("✓ \(host):\(port) is running Cuple")
            return true
        } catch {
            // Log the reason so silent-negatives (wrong netmap, DERP fail,
            // ACL deny, peer not listening, timeout) are distinguishable.
            logger.log("✗ \(host):\(port) probe failed: \(error)")
            return false
        }
    }

    /// Helper to run async operations with a timeout
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }

            guard let result = try await group.next() else {
                throw TimeoutError()
            }

            group.cancelAll()
            return result
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
                availablePeers[i] = CuplePeer(
                    id: updatedPeer.id,
                    hostname: peerStatus.hostname,
                    dnsName: peerStatus.dnsName,
                    tailscaleIP: peerStatus.tailscaleIPs.first ?? updatedPeer.tailscaleIP,
                    isOnline: peerStatus.online,
                    isRunningCuple: updatedPeer.isRunningCuple,
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
    func fetchMetadata(for peer: CuplePeer) async -> CupleMetadata? {
        do {
            let metadata = try await CupleMetadataService.fetchMetadata(
                from: peer.tailscaleIP,
                port: cuplePort
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

// MARK: - Logger Implementation

private struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil

    func log(_ message: String) {
        print("[Discovery] \(message)")
    }
}
