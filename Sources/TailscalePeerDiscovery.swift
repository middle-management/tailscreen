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
    private let metadataPort: UInt16 = 7448
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

        // Fetch metadata from all peers (in parallel, over Tailscale)
        var updatedPeers: [CuplePeer] = []

        await withTaskGroup(of: (String, CupleMetadata?).self) { group in
            for peer in peers {
                group.addTask { [metadataPort] in
                    self.logger.log("🔍 Fetching metadata from \(peer.hostname) (\(peer.tailscaleIP))...")
                    do {
                        let metadata = try await CupleMetadataService.fetchMetadata(
                            node: node,
                            from: peer.tailscaleIP,
                            port: metadataPort
                        )
                        self.logger.log("✓ \(peer.hostname): isSharing=\(metadata.isSharing)")
                        return (peer.id, metadata)
                    } catch {
                        self.logger.log("✗ \(peer.hostname): \(error.localizedDescription)")
                        return (peer.id, nil)
                    }
                }
            }

            var metadataMap: [String: CupleMetadata?] = [:]
            for await (peerId, metadata) in group {
                metadataMap[peerId] = metadata
            }

            // Update peers with metadata
            for var peer in peers {
                if let metadata = metadataMap[peer.id] {
                    peer.metadata = metadata
                    peer.isRunningCuple = (metadata != nil)
                }
                updatedPeers.append(peer)
            }
        }

        // Only show peers that have metadata AND are actively sharing
        let sharingPeers = updatedPeers.filter {
            $0.metadata?.isSharing ?? false
        }

        logger.log("🎯 Found \(sharingPeers.count) peers actively sharing")

        availablePeers = sharingPeers
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

}

struct TimeoutError: Error {}

// MARK: - Logger Implementation

private struct TSLogger: LogSink {
    var logFileHandle: Int32? = nil

    func log(_ message: String) {
        print("[Discovery] \(message)")
    }
}
